import Combine
import Darwin
import Foundation

protocol SystemAppearanceToggling: Sendable {
    func toggle() async -> AppearanceToggleResult
}

/// Uses the public scripting dictionary at System Events.app/Contents/Resources/
/// SystemEvents.sdef (appearance preferences.dark mode). No private defaults or
/// automatic permission probes are used. Execution begins only after a click.
final class SystemEventsAppearanceDevice: SystemAppearanceToggling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dongfengrui.NotchIsland.appearance", qos: .userInitiated)

    func toggle() async -> AppearanceToggleResult {
        let cancellation = AppearanceProcessCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Self.execute(cancellation))
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func execute(_ cancellation: AppearanceProcessCancellation) -> AppearanceToggleResult {
        guard !cancellation.isCancelled else { return .failed(.cancelled) }
        let process = Process()
        let output = Pipe()
        let stopped = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Constant application ID and source; no shell, user text, or interpolation.
        process.arguments = ["-e", source]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in stopped.signal() }
        do {
            guard try cancellation.launch(process) else { return .failed(.cancelled) }
        } catch { return .failed(.unavailable) }

        // System authorization may take longer than an ordinary setting write.
        // Never block the main thread or leave the tile busy indefinitely.
        let timedOut = stopped.wait(timeout: .now() + 120) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if stopped.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                // This is only our still-running child, never another process.
                kill(process.processIdentifier, SIGKILL)
                _ = stopped.wait(timeout: .now() + 2)
            }
            return .failed(.timedOut)
        }
        guard !cancellation.isCancelled else { return .failed(.cancelled) }
        guard process.terminationReason == .exit,
              let data = try? output.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return .failed(.unavailable) }
        return .decode(text, exitCode: process.terminationStatus)
    }

    /// All branches return a small, non-sensitive protocol, not a system error
    /// description. Initial read, write and readback are one serialized request.
    private static let source = """
    on bitText(flag)
        if flag then return "1"
        return "0"
    end bitText
    with timeout of 90 seconds
        try
            tell application id "com.apple.systemevents"
                set wasDark to dark mode of appearance preferences
            end tell
        on error number errorNumber
            return "read|?|?|" & (errorNumber as text)
        end try
        set wantedDark to not wasDark
        try
            tell application id "com.apple.systemevents"
                set dark mode of appearance preferences to wantedDark
            end tell
        on error number errorNumber
            return "write|" & my bitText(wasDark) & "|?|" & (errorNumber as text)
        end try
        try
            tell application id "com.apple.systemevents"
                set actualDark to dark mode of appearance preferences
            end tell
        on error number errorNumber
            return "readback|" & my bitText(wasDark) & "|?|" & (errorNumber as text)
        end try
        return "ok|" & my bitText(wasDark) & "|" & my bitText(actualDark) & "|0"
    end timeout
    """
}

private final class AppearanceProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func launch(_ process: Process) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        try process.run()
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let child = process
        lock.unlock()
        if let child, child.isRunning { child.terminate() }
    }
}

@MainActor
final class SystemAppearanceControl: ObservableObject {
    static let shared = SystemAppearanceControl()
    @Published private(set) var enabled: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?
    private let device: any SystemAppearanceToggling

    init(device: any SystemAppearanceToggling = SystemEventsAppearanceDevice()) {
        self.device = device
        // Constructing this object does not execute a script or request consent.
    }

    @discardableResult
    func toggle() async -> AppearanceToggleResult {
        guard !isBusy else { return .failed(.busy) }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        isBusy = true
        errorKey = nil
        defer { isBusy = false }
        let result = await device.toggle()
        enabled = result.enabled
        errorKey = result.failure?.messageKey
        return result
    }
}
