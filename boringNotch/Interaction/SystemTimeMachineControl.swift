import Combine
import Darwin
import Foundation

protocol TimeMachineControlling: Sendable {
    func execute(_ command: TimeMachineCommand) async -> TimeMachineResult
}

/// startbackup and stopbackup are documented in the local tmutil(8) manual.
/// Unlike destination edits and schedule enable/disable, these entries do not
/// require root in that manual. Runtime permission failures remain failures;
/// this runner never elevates privileges or changes configuration/backup files.
final class NativeTimeMachineDevice: TimeMachineControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dongfengrui.NotchIsland.time-machine", qos: .userInitiated)

    func execute(_ command: TimeMachineCommand) async -> TimeMachineResult {
        let cancellation = TimeMachineProcessCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result = TimeMachineTransaction.execute(command, run: { invocation in
                        Self.run(invocation, cancellation: cancellation)
                    }, pause: { Thread.sleep(forTimeInterval: 0.5) })
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func run(_ invocation: TimeMachineInvocation,
                            cancellation: TimeMachineProcessCancellation) -> TimeMachineProcessOutput {
        var failed = TimeMachineProcessOutput(exitCode: -1, output: Data(), error: Data())
        if cancellation.isCancelled { failed.cancelled = true; return failed }
        let process = Process(), output = Pipe(), error = Pipe()
        let stopped = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = invocation.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        process.terminationHandler = { _ in stopped.signal() }
        do {
            guard try cancellation.launch(process) else { failed.cancelled = true; return failed }
        } catch { return failed }
        if stopped.wait(timeout: .now() + 12) == .timedOut {
            if process.isRunning { process.terminate() }
            if stopped.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = stopped.wait(timeout: .now() + 2)
            }
            failed.timedOut = true
            return failed
        }
        if cancellation.isCancelled { failed.cancelled = true; return failed }
        guard process.terminationReason == .exit else { return failed }
        do {
            // FileHandle returns nil at a clean EOF with no bytes. A successful
            // tmutil normally has empty stderr; start/stop can have empty stdout
            // too. Preserve the exit status instead of treating normal EOF as
            // an I/O failure. A thrown read error still fails the transaction.
            let stdout = try output.fileHandleForReading.readToEnd() ?? Data()
            let stderr = try error.fileHandleForReading.readToEnd() ?? Data()
            // Data only lives for this transaction. No destination identifiers,
            // paths, names, progress dictionaries or raw errors are logged.
            return .init(exitCode: process.terminationStatus, output: stdout, error: stderr)
        } catch { return failed }
    }
}

private final class TimeMachineProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func launch(_ child: Process) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        process = child
        try child.run()
        return true
    }

    func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        // Cancelling an app task stops its CLI child only. It must never issue
        // stopbackup as cleanup: an existing system backup belongs to the user.
        if let child, child.isRunning { child.terminate() }
    }
}

@MainActor
final class SystemTimeMachineControl: ObservableObject {
    static let shared = SystemTimeMachineControl()
    @Published private(set) var running: Bool?
    @Published private(set) var configAvailable: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?
    private let device: any TimeMachineControlling

    init(device: any TimeMachineControlling = NativeTimeMachineDevice()) { self.device = device }

    @discardableResult func refresh() async -> TimeMachineResult { await submit(.refresh) }
    @discardableResult func startBackup() async -> TimeMachineResult { await submit(.start) }
    @discardableResult func stopBackup() async -> TimeMachineResult { await submit(.stop) }

    private func submit(_ command: TimeMachineCommand) async -> TimeMachineResult {
        guard !isBusy else { return .failed(.busy) }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        isBusy = true; errorKey = nil
        defer { isBusy = false }
        let result = await device.execute(command)
        running = result.running
        configAvailable = result.configAvailable
        errorKey = result.failure?.messageKey
        return result
    }
}
