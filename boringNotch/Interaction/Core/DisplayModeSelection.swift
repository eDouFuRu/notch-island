import Foundation

struct DisplayModeOption: Identifiable, Equatable, Hashable, Sendable {
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let usableForDesktop: Bool

    var isHiDPI: Bool { pixelWidth > width && pixelHeight > height }
    var resolutionLabel: String { "\(width) × \(height)" }
    /// A zero rate means that CoreGraphics did not provide a fixed refresh rate.
    /// The UI should use its localized "System Default" label in this case.
    var refreshRateLabel: String? {
        guard refreshRate > 0, refreshRate.isFinite else { return nil }
        return "\(refreshRate.formatted(.number.precision(.fractionLength(0...2)))) Hz"
    }
    var isSelectable: Bool {
        usableForDesktop && width > 0 && height > 0 && pixelWidth >= width && pixelHeight >= height &&
        refreshRate.isFinite && refreshRate >= 0
    }
    fileprivate var signature: DisplayModeSignature {
        .init(width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshRate: refreshRate)
    }
}

private struct DisplayModeSignature: Hashable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
}

enum DisplayModeMenu {
    /// Hide non-desktop modes and exact duplicates. Prefer the current mode's
    /// real ID so a duplicate never removes the current checkmark. An ID with
    /// contradictory metadata is unsafe and is omitted entirely.
    static func options(_ modes: [DisplayModeOption], currentModeID: Int32?) -> [DisplayModeOption] {
        let byID = Dictionary(grouping: modes.filter(\.isSelectable), by: \.id)
        let valid = byID.values.compactMap { group -> DisplayModeOption? in
            guard Set(group.map(\.signature)).count == 1 else { return nil }
            return group.first
        }
        return Dictionary(grouping: valid, by: \.signature).values.compactMap { group in
            group.first(where: { $0.id == currentModeID }) ?? group.min(by: { $0.id < $1.id })
        }.sorted {
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.height != $1.height { return $0.height < $1.height }
            if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth > $1.pixelWidth }
            if $0.pixelHeight != $1.pixelHeight { return $0.pixelHeight > $1.pixelHeight }
            if $0.refreshRate != $1.refreshRate { return $0.refreshRate > $1.refreshRate }
            return $0.id < $1.id
        }
    }
}

struct DisplayModeDisplay: Identifiable, Equatable, Sendable {
    /// ColorSync display UUID, not a transient CGDirectDisplayID.
    let id: String
    let ordinal: Int
    let isBuiltIn: Bool
    let isMirrored: Bool
    let currentModeID: Int32?
    let modes: [DisplayModeOption]
}

struct DisplayModeRequest: Equatable, Sendable {
    let displayID: String
    /// Carry the menu snapshot as well as its ID: a reconnected display can
    /// reuse a mode number for different dimensions or a different rate.
    let mode: DisplayModeOption
}

enum DisplayModeCommand: Equatable, Sendable {
    case refresh
    case select(DisplayModeRequest)
}

enum DisplayModeFailure: String, Equatable, Sendable {
    case unavailable, noDisplays, displayMissing, modeMissing, modeChanged
    case currentUnreadable, writeFailed, readbackUnavailable, unconfirmed, cancelled, busy

    var messageKey: String {
        switch self {
        case .unavailable: "Display modes could not be read. Refresh or open Displays settings."
        case .noDisplays: "No active display is available."
        case .displayMissing: "This display is no longer active. Refresh the display list."
        case .modeMissing: "This display mode is no longer available. Refresh and choose again."
        case .modeChanged: "This display mode changed since the menu opened. Refresh and choose again."
        case .currentUnreadable: "The current display mode could not be read. No change was made."
        case .writeFailed: "macOS did not accept this display mode. Open Displays settings to check compatibility."
        case .readbackUnavailable: "The display mode was requested, but its resulting state could not be read."
        case .unconfirmed: "macOS did not confirm the requested display mode."
        case .cancelled: "The display request was cancelled. Refresh to check its current mode."
        case .busy: "A display request is already in progress."
        }
    }
}

enum DisplayModeDecision: Equatable {
    case alreadySelected, select, fail(DisplayModeFailure)

    static func evaluate(_ request: DisplayModeRequest, displays: [DisplayModeDisplay]) -> Self {
        guard !request.displayID.isEmpty,
              let display = displays.first(where: { $0.id == request.displayID }) else { return .fail(.displayMissing) }
        guard let current = display.currentModeID else { return .fail(.currentUnreadable) }
        guard request.mode.isSelectable,
              let actual = display.modes.first(where: { $0.id == request.mode.id }) else { return .fail(.modeMissing) }
        guard actual == request.mode else { return .fail(.modeChanged) }
        return current == request.mode.id ? .alreadySelected : .select
    }
}

struct DisplayModeResult: Equatable, Sendable {
    /// nil means there was no trustworthy readback; the UI must discard stale data.
    let displays: [DisplayModeDisplay]?
    let failure: DisplayModeFailure?
}

enum DisplayModeTransaction {
    static let readbackAttempts = 8
    static let readbackInterval: TimeInterval = 0.15

    static func execute(_ command: DisplayModeCommand,
                        read: () -> [DisplayModeDisplay]?,
                        write: (DisplayModeRequest) -> DisplayModeFailure?,
                        wait: () -> Void = {},
                        isCancelled: () -> Bool = { false }) -> DisplayModeResult {
        guard !isCancelled() else { return .init(displays: nil, failure: .cancelled) }
        guard let initial = read() else { return .init(displays: nil, failure: .unavailable) }
        guard case let .select(request) = command else {
            return .init(displays: initial, failure: initial.isEmpty ? .noDisplays : nil)
        }
        switch DisplayModeDecision.evaluate(request, displays: initial) {
        case .alreadySelected: return .init(displays: initial, failure: nil)
        case .fail(let failure): return .init(displays: initial, failure: failure)
        case .select: break
        }
        guard !isCancelled() else { return .init(displays: initial, failure: .cancelled) }
        if let failure = write(request) { return .init(displays: read(), failure: failure) }
        var latest: [DisplayModeDisplay]?
        for attempt in 0..<readbackAttempts {
            if attempt > 0 { wait() }
            guard !isCancelled() else { return .init(displays: nil, failure: .cancelled) }
            latest = read()
            guard let displays = latest,
                  let display = displays.first(where: { $0.id == request.displayID }),
                  display.currentModeID != nil else {
                return .init(displays: latest, failure: .readbackUnavailable)
            }
            if display.currentModeID == request.mode.id,
               display.modes.first(where: { $0.id == request.mode.id }) == request.mode {
                return .init(displays: displays, failure: nil)
            }
        }
        return .init(displays: latest, failure: .unconfirmed)
    }
}
