import Foundation

enum AccessibilityDisplayFeature: String, CaseIterable, Hashable, Sendable {
    case reduceTransparency, increaseContrast
}

struct AccessibilityDisplaySnapshot: Equatable, Sendable {
    var supportedFeatures: Set<AccessibilityDisplayFeature>
    /// Missing values mean unreadable, never disabled.
    var states: [AccessibilityDisplayFeature: Bool]
    static let unavailable = Self(supportedFeatures: [], states: [:])
}

enum AccessibilityDisplayFailure: String, Equatable, Sendable {
    case unsupported, unavailable, changedBeforeWrite, contrastRequiresTransparency
    case writeUnavailable, readbackUnavailable, unconfirmed, cancelled, busy

    var messageKey: String {
        switch self {
        case .unsupported: "Direct control of this display accessibility option is not supported on this Mac."
        case .unavailable: "Display accessibility settings could not be read. Refresh before trying again."
        case .changedBeforeWrite: "This display accessibility setting changed. Check its current state and try again."
        case .contrastRequiresTransparency: "Turn off Increase Contrast before turning off Reduce Transparency."
        case .writeUnavailable: "The display accessibility change could not be requested."
        case .readbackUnavailable: "The display accessibility change was requested, but its current state could not be confirmed."
        case .unconfirmed: "macOS did not confirm the requested display accessibility change."
        case .cancelled: "The display accessibility request was cancelled. Refresh to check its current state."
        case .busy: "A display accessibility request is already in progress."
        }
    }
}

enum AccessibilityDisplayCommand: Equatable, Sendable {
    case refresh
    case toggle(feature: AccessibilityDisplayFeature, expectedEnabled: Bool)
}

struct AccessibilityDisplayResult: Equatable, Sendable {
    let snapshot: AccessibilityDisplaySnapshot
    let failure: AccessibilityDisplayFailure?
}

/// Native setters return void. An accepted write is only a request; public
/// AppKit state and the native getter must agree before reporting success.
/// Increase Contrast owns the system's Reduce Transparency dependency. Never
/// replace that policy with a second write or an automatic rollback.
enum AccessibilityDisplayTransaction {
    static func execute(
        _ command: AccessibilityDisplayCommand,
        read: () async -> AccessibilityDisplaySnapshot,
        write: (AccessibilityDisplayFeature, Bool) async -> Bool,
        pause: () async -> Void,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) async -> AccessibilityDisplayResult {
        guard !isCancelled() else { return .init(snapshot: .unavailable, failure: .cancelled) }
        let initial = await read()
        guard case let .toggle(feature, expected) = command else {
            let failure: AccessibilityDisplayFailure? = initial.supportedFeatures.isEmpty ? .unsupported
                : (initial.states.isEmpty ? .unavailable : nil)
            return .init(snapshot: initial, failure: failure)
        }
        guard initial.supportedFeatures.contains(feature) else {
            return .init(snapshot: initial, failure: .unsupported)
        }
        guard let current = initial.states[feature],
              let contrast = initial.states[.increaseContrast],
              initial.states[.reduceTransparency] != nil else {
            return .init(snapshot: initial, failure: .unavailable)
        }
        guard current == expected else { return .init(snapshot: initial, failure: .changedBeforeWrite) }
        if feature == .reduceTransparency && current && contrast {
            return .init(snapshot: initial, failure: .contrastRequiresTransparency)
        }
        guard !isCancelled() else { return .init(snapshot: initial, failure: .cancelled) }
        let target = !current
        guard await write(feature, target) else { return .init(snapshot: initial, failure: .writeUnavailable) }
        var latest = initial
        // 2 seconds of bounded readback. There is exactly one setter call.
        for attempt in 0..<21 {
            if attempt > 0 { await pause() }
            guard !isCancelled() else { return .init(snapshot: .unavailable, failure: .cancelled) }
            latest = await read()
            guard latest.supportedFeatures.contains(feature) else {
                return .init(snapshot: latest, failure: .readbackUnavailable)
            }
            // AppKit's effective state may receive the change notification after
            // the native getter. Brief disagreement is pending, not success.
            guard latest.states[feature] != nil, latest.states[.reduceTransparency] != nil,
                  latest.states[.increaseContrast] != nil else { continue }
            let dependencyConfirmed = feature != .increaseContrast || !target
                || latest.states[.reduceTransparency] == true
            if latest.states[feature] == target && dependencyConfirmed {
                return .init(snapshot: latest, failure: nil)
            }
        }
        let readable = latest.states[.reduceTransparency] != nil && latest.states[.increaseContrast] != nil
        return .init(snapshot: latest, failure: readable ? .unconfirmed : .readbackUnavailable)
    }
}
