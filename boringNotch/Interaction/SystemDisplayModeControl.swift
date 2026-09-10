import ColorSync
import Combine
import CoreGraphics
import Foundation

protocol DisplayModeControlling: Sendable {
    func execute(_ command: DisplayModeCommand) async -> DisplayModeResult
}

/// Public display metadata and mode API only. No screenshots, window lists,
/// display capture, private preferences, permanent configuration or privileges.
final class CoreGraphicsDisplayModeDevice: DisplayModeControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dongfengrui.NotchIsland.display-mode", qos: .userInitiated)

    func execute(_ command: DisplayModeCommand) async -> DisplayModeResult {
        let cancellation = DisplayModeCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result = DisplayModeTransaction.execute(command,
                        read: { Self.snapshot()?.map(\.record) },
                        write: { Self.write($0, cancellation: cancellation) },
                        wait: { Thread.sleep(forTimeInterval: DisplayModeTransaction.readbackInterval) },
                        isCancelled: { cancellation.isCancelled })
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private struct DisplaySnapshot {
        let displayID: CGDirectDisplayID
        let record: DisplayModeDisplay
        let nativeModes: [CGDisplayMode]
    }

    private static func snapshot() -> [DisplaySnapshot]? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count <= 64 else { return nil }
        if count == 0 { return [] }
        // A little room for a display connected between the two public calls.
        var active = [CGDirectDisplayID](repeating: 0, count: 64)
        guard CGGetActiveDisplayList(64, &active, &count) == .success, count <= 64 else { return nil }
        var seen: Set<String> = []
        var results: [DisplaySnapshot] = []
        for (index, displayID) in active.prefix(Int(count)).enumerated() {
            guard let uuid = displayUUID(displayID), seen.insert(uuid).inserted,
                  let native = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode],
                  native.count <= 4096 else { return nil }
            let current = CGDisplayCopyDisplayMode(displayID)
            let currentID = current?.ioDisplayModeID
            // Some display drivers omit the active mode from their mode array.
            // Include only its actual metadata, and still require desktop usability.
            var allModes = native
            if let current { allModes.append(current) }
            let options = DisplayModeMenu.options(allModes.map(option), currentModeID: currentID)
            results.append(.init(displayID: displayID,
                record: .init(id: uuid, ordinal: index + 1, isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                              isMirrored: CGDisplayIsInMirrorSet(displayID) != 0,
                              currentModeID: currentID, modes: options), nativeModes: allModes))
        }
        return results
    }

    private static func displayUUID(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func option(_ mode: CGDisplayMode) -> DisplayModeOption {
        .init(id: mode.ioDisplayModeID, width: mode.width, height: mode.height,
              pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate,
              usableForDesktop: mode.isUsableForDesktopGUI())
    }

    private static func write(_ request: DisplayModeRequest, cancellation: DisplayModeCancellation) -> DisplayModeFailure? {
        // Never resolve a stale UUID by array index or use an old numeric display
        // ID. Recreate both the active display and its mode immediately before set.
        guard let fresh = snapshot() else { return .unavailable }
        switch DisplayModeDecision.evaluate(request, displays: fresh.map(\.record)) {
        case .fail(let failure): return failure
        case .alreadySelected: return nil
        case .select: break
        }
        guard let display = fresh.first(where: { $0.record.id == request.displayID }),
              let native = display.nativeModes.first(where: { option($0) == request.mode }),
              displayUUID(display.displayID) == request.displayID else { return .modeMissing }
        guard !cancellation.isCancelled else { return .cancelled }
        // CGDirectDisplay.h specifies application-lifetime changes, automatically
        // reverted by macOS at termination. Do not use permanent configuration APIs.
        return CGDisplaySetDisplayMode(display.displayID, native, nil) == .success ? nil : .writeFailed
    }
}

private final class DisplayModeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

@MainActor final class SystemDisplayModeControl: ObservableObject {
    static let shared = SystemDisplayModeControl()
    @Published private(set) var displays: [DisplayModeDisplay] = []
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?
    private let device: any DisplayModeControlling

    init(device: any DisplayModeControlling = CoreGraphicsDisplayModeDevice()) { self.device = device }

    @discardableResult func refresh() async -> Bool { await submit(.refresh) }

    /// Only explicit menu selections enter this method. Copy the selected option
    /// now; the device checks that exact snapshot against fresh public metadata.
    @discardableResult func select(displayID: String, modeID: Int32) async -> Bool {
        guard !isBusy else { return false }
        guard let display = displays.first(where: { $0.id == displayID }) else {
            errorKey = DisplayModeFailure.displayMissing.messageKey
            return false
        }
        guard let mode = display.modes.first(where: { $0.id == modeID }) else {
            errorKey = DisplayModeFailure.modeMissing.messageKey
            return false
        }
        return await select(displayID: displayID, mode: mode)
    }

    /// Prefer this overload from menu rows: it preserves the exact metadata
    /// drawn in that row even if a background refresh replaces the live list.
    @discardableResult func select(displayID: String, mode: DisplayModeOption) async -> Bool {
        await submit(.select(.init(displayID: displayID, mode: mode)))
    }

    private func submit(_ command: DisplayModeCommand) async -> Bool {
        guard !isBusy, !Task.isCancelled else { return false }
        isBusy = true; errorKey = nil
        defer { isBusy = false }
        let result = await device.execute(command)
        displays = result.displays ?? []
        errorKey = result.failure?.messageKey
        return result.failure == nil
    }
}
