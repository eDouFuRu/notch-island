import Combine
import Darwin
import Foundation

protocol VPNConnectionControlling: Sendable {
    func execute(_ command: VPNConnectionCommand) async -> VPNConnectionResult
}

/// scutil(8) documents --nc; its help documents list/start/stop for configured
/// VPN services. The public SCNetworkConnection header only promises PPP, while
/// scutil's system-owned implementation also resolves IPSec and VPN providers.
/// No private API is linked here. No show/status/statistics/configuration command,
/// credentials, shell, elevated privileges, or VPN-type enable/disable is used.
final class ScutilVPNDevice: VPNConnectionControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dongfengrui.NotchIsland.vpn", qos: .userInitiated)

    func execute(_ command: VPNConnectionCommand) async -> VPNConnectionResult {
        let cancellation = VPNChildCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result = VPNConnectionTransaction.execute(command, run: {
                        Self.run($0, cancellation: cancellation)
                    }, isCancelled: { cancellation.isCancelled })
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func run(_ invocation: VPNConnectionInvocation,
                            cancellation: VPNChildCancellation) -> VPNConnectionProcessOutput {
        var result = VPNConnectionProcessOutput(exitCode: -1, output: Data())
        guard !cancellation.isCancelled else { result.cancelled = true; return result }
        guard let arguments = invocation.arguments else { return result }
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        // Start/stop output is not needed. In particular never retain a provider's
        // incidental error text, credentials or diagnostic details.
        let isRead = invocation == .list
        child.standardOutput = isRead ? pipe : FileHandle.nullDevice
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        let fd = pipe.fileHandleForReading.fileDescriptor
        let oldFlags = fcntl(fd, F_GETFL)
        guard oldFlags >= 0, fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK) == 0 else { return result }
        defer {
            cancellation.finished(child)
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        do {
            guard try cancellation.launch(child) else { result.cancelled = true; return result }
        } catch { return result }
        // The parent must release its writer or EOF cannot be observed.
        try? pipe.fileHandleForWriting.close()
        var bytes = Data()
        var readFailed = false
        func drain() {
            guard isRead, !readFailed, !result.exceededLimit else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            // Bound each drain so a malfunctioning child cannot starve timeout.
            for _ in 0..<40 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard bytes.count + count <= VPNConnectionListParser.maximumBytes else {
                        result.exceededLimit = true; return
                    }
                    bytes.append(contentsOf: buffer.prefix(count))
                } else if count == 0 { return }
                else if errno == EAGAIN || errno == EWOULDBLOCK { return }
                else if errno != EINTR { readFailed = true; return }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while child.isRunning {
            drain()
            if cancellation.isCancelled { result.cancelled = true; break }
            if result.exceededLimit || readFailed { break }
            if ProcessInfo.processInfo.systemUptime >= deadline { result.timedOut = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if child.isRunning {
            child.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.3
            while child.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if child.isRunning {
                // Terminate only this task's fixed scutil child, never a VPN agent.
                kill(child.processIdentifier, SIGKILL)
                let killDeadline = ProcessInfo.processInfo.systemUptime + 1
                while child.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
        drain()
        if cancellation.isCancelled { result.cancelled = true }
        guard !child.isRunning, !readFailed, !result.exceededLimit,
              !result.timedOut, !result.cancelled, child.terminationReason == .exit else { return result }
        return .init(exitCode: child.terminationStatus, output: bytes)
    }
}

private final class VPNChildCancellation: @unchecked Sendable {
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

    func finished(_ child: Process) {
        lock.lock(); defer { lock.unlock() }
        if process === child { process = nil }
    }

    func cancel() {
        lock.lock(); cancelled = true; let child = process; lock.unlock()
        // A cancelled refresh never disconnects a VPN, including one started here.
        if let child, child.isRunning { child.terminate() }
    }
}

@MainActor
final class SystemVPNControl: ObservableObject {
    static let shared = SystemVPNControl()
    @Published private(set) var services: [VPNConnectionMenuItem] = []
    @Published private(set) var unsupportedServiceCount = 0
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?
    @Published private(set) var lastStatusCode: Int32?
    private let device: any VPNConnectionControlling
    private let confirmationDelay: UInt64
    private let confirmationAttempts: Int

    init(device: any VPNConnectionControlling = ScutilVPNDevice(),
         confirmationDelay: UInt64 = 500_000_000, confirmationAttempts: Int = 30) {
        self.device = device
        self.confirmationDelay = confirmationDelay
        self.confirmationAttempts = max(0, min(30, confirmationAttempts))
    }

    @discardableResult func refresh() async -> Bool {
        guard !isBusy, !Task.isCancelled else { return false }
        isBusy = true
        defer { isBusy = false }
        let result = await device.execute(.refresh)
        publish(result)
        return result.failure == nil
    }

    /// Use from the tile's SwiftUI .task. It stops when that view/task disappears
    /// and never reconnects, disconnects or changes configuration automatically.
    func monitorWhileVisible() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        }
    }

    @discardableResult func setConnected(id: String, connected: Bool) async -> Bool {
        guard !isBusy, !Task.isCancelled else { return false }
        guard let service = services.first(where: { $0.id == id }) else {
            errorKey = VPNConnectionFailure.serviceMissing.messageKey; return false
        }
        let request = VPNConnectionRequest(serviceID: id, connected: connected, expectedStatus: service.status)
        isBusy = true; errorKey = nil; lastStatusCode = nil
        defer { isBusy = false }
        var result = await device.execute(.set(request))
        publish(result)
        guard !Task.isCancelled else { errorKey = VPNConnectionFailure.cancelled.messageKey; return false }
        if result.failure == nil, status(id) == request.target { return true }
        guard result.requestAccepted, result.failure == .confirmationPending else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        for _ in 0..<confirmationAttempts {
            do { try await Task.sleep(nanoseconds: confirmationDelay) }
            catch { errorKey = VPNConnectionFailure.cancelled.messageKey; return false }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            result = await device.execute(.refresh)
            publish(result)
            guard !Task.isCancelled else { errorKey = VPNConnectionFailure.cancelled.messageKey; return false }
            if status(id) == request.target { return true }
            guard result.failure == nil else { return false }
            guard let actual = status(id) else { errorKey = VPNConnectionFailure.serviceMissing.messageKey; return false }
            guard actual != .unknown else { errorKey = VPNConnectionFailure.statusUnknown.messageKey; return false }
        }
        errorKey = VPNConnectionFailure.confirmationPending.messageKey
        return false
    }

    private func status(_ id: String) -> VPNConnectionState? {
        services.first(where: { $0.id == id })?.status
    }

    private func publish(_ result: VPNConnectionResult) {
        services = result.reading?.services ?? []
        unsupportedServiceCount = result.reading?.unsupportedServiceCount ?? 0
        errorKey = result.failure?.messageKey
        lastStatusCode = result.statusCode
    }
}
