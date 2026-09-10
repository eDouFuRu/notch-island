import Combine
import CoreBluetooth
import Darwin
import Foundation

protocol BluetoothPowerControlling: Sendable {
    func execute(_ command: BluetoothPowerCommand) async -> BluetoothPowerResult
}

/// Experimental compatibility layer. Signatures are independently declared from
/// blueutil's documented SPI usage (blueutil.m, lines 45–49, 167–187):
/// https://github.com/toy/blueutil/blob/master/blueutil.m
/// The public SDK exposes only a readonly controller powerState. Never substitute
/// writes to preference files or enumerate nearby/paired devices for this SPI.
final class NativeBluetoothPowerDevice: BluetoothPowerControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dongfengrui.NotchIsland.bluetooth-power", qos: .userInitiated)
    private let executableURL: URL?

    init(executableURL: URL? = Bundle.main.executableURL) { self.executableURL = executableURL }

    func execute(_ command: BluetoothPowerCommand) async -> BluetoothPowerResult {
        let cancellation = BluetoothPowerChildCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(returning: run(command, cancellation: cancellation))
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func run(_ command: BluetoothPowerCommand, cancellation: BluetoothPowerChildCancellation) -> BluetoothPowerResult {
        guard !cancellation.isCancelled else { return .failed(.cancelled) }
        guard let executableURL else { return .failed(.unsupported) }
        let process = Process(), output = Pipe()
        let stopped = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = BluetoothPowerHelperProtocol.arguments(for: command)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in stopped.signal() }
        do {
            guard try cancellation.launch(process) else { return .failed(.cancelled) }
        } catch { return .failed(.unavailable) }
        // On this Mac even the getter can block indefinitely. A task timeout
        // inside the app would leave that native call alive. Isolate all SPI in
        // this child and terminate only it on timeout, preserving app responsiveness.
        if stopped.wait(timeout: .now() + 8) == .timedOut {
            if process.isRunning { process.terminate() }
            if stopped.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = stopped.wait(timeout: .now() + 1)
            }
            return .failed(cancellation.isCancelled ? .cancelled : .timedOut)
        }
        guard !cancellation.isCancelled else { return .failed(.cancelled) }
        guard process.terminationReason == .exit else { return .failed(.unavailable) }
        do {
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            return BluetoothPowerHelperProtocol.decode(data, exitCode: process.terminationStatus)
        } catch { return .failed(.unavailable) }
    }
}

/// Called by the app's entry wrapper before SwiftUI App.main(). This mode does
/// not create NSApplication, application views, stores or menu bar components.
enum BluetoothPowerHelper {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        let input = Array(arguments.dropFirst())
        guard input.first == BluetoothPowerHelperProtocol.flag else { return nil }
        guard let command = BluetoothPowerHelperProtocol.command(from: input) else { return 64 }
        let result: BluetoothPowerResult
        if let symbols = BluetoothPowerSymbols() {
            result = BluetoothPowerTransaction.execute(command, read: {
                guard symbols.available() != 0 else { return .unsupported }
                return .decode(preferencesAvailable: true, rawPower: symbols.getPower())
            }, write: { enabled in
                symbols.setPower(enabled ? 1 : 0)
            }, now: { ProcessInfo.processInfo.systemUptime }, pause: { Thread.sleep(forTimeInterval: 0.1) })
        } else { result = .failed(.unsupported) }
        guard let data = BluetoothPowerHelperProtocol.encode(result) else { return 70 }
        do { try FileHandle.standardOutput.write(contentsOf: data) }
        catch { return 74 }
        return 0
    }
}

private final class BluetoothPowerSymbols {
    typealias Getter = @convention(c) () -> Int32
    typealias Setter = @convention(c) (Int32) -> Void
    let available: Getter
    let getPower: Getter
    let setPower: Setter
    private let handle: UnsafeMutableRawPointer

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let available = dlsym(handle, "IOBluetoothPreferencesAvailable"),
              let getter = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState"),
              let setter = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else {
            dlclose(handle); return nil
        }
        self.handle = handle
        self.available = unsafeBitCast(available, to: Getter.self)
        getPower = unsafeBitCast(getter, to: Getter.self)
        setPower = unsafeBitCast(setter, to: Setter.self)
    }

    deinit { dlclose(handle) }
}

private final class BluetoothPowerChildCancellation: @unchecked Sendable {
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
        if let child, child.isRunning { child.terminate() }
    }
}

@MainActor protocol BluetoothAuthorizationRequesting: AnyObject {
    func start(_ update: @escaping @MainActor (BluetoothPowerAuthorization) -> Void)
}

/// Created only by the explicit access button. Keeping a central manager is
/// sufficient for the system authorization flow; no scanning, connections,
/// peripheral retrieval or device metadata are requested.
@MainActor private final class CoreBluetoothAuthorizationRequest: NSObject, CBCentralManagerDelegate, BluetoothAuthorizationRequesting {
    private var manager: CBCentralManager?
    private var update: (@MainActor (BluetoothPowerAuthorization) -> Void)?

    func start(_ update: @escaping @MainActor (BluetoothPowerAuthorization) -> Void) {
        guard manager == nil else { return }
        self.update = update
        manager = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            self?.update?(.decode(rawValue: CBManager.authorization.rawValue))
        }
    }
}

@MainActor
final class SystemBluetoothControl: ObservableObject {
    static let shared = SystemBluetoothControl()
    @Published private(set) var enabled: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?
    @Published private(set) var availability = BluetoothPowerAvailability.unknown
    @Published private(set) var authorization = BluetoothPowerAuthorization.unknown
    @Published private(set) var isRequestingAccess = false
    private let device: any BluetoothPowerControlling
    private let authorizationReader: () -> BluetoothPowerAuthorization
    private let authorizationRequesterFactory: @MainActor () -> any BluetoothAuthorizationRequesting
    private var authorizationRequester: (any BluetoothAuthorizationRequesting)?
    private var accessRequestState = BluetoothAccessRequestState()
    private var authorizationRefreshPending = false

    init(device: any BluetoothPowerControlling = NativeBluetoothPowerDevice(),
         authorizationReader: @escaping () -> BluetoothPowerAuthorization = {
             .decode(rawValue: CBManager.authorization.rawValue)
         },
         authorizationRequesterFactory: @escaping @MainActor () -> any BluetoothAuthorizationRequesting = {
             CoreBluetoothAuthorizationRequest()
         }) {
        self.device = device
        self.authorizationReader = authorizationReader
        self.authorizationRequesterFactory = authorizationRequesterFactory
    }

    @discardableResult func refresh() async -> BluetoothPowerResult {
        // The class property can be queried before allocating a CBManager. Read
        // it in the main app, never reuse a probe/helper's authorization. This
        // does not ask for access and does not predict the legacy SPI outcome.
        let changed = updateAuthorization(authorizationReader())
        if changed && isBusy { authorizationRefreshPending = true }
        return await submit(.refresh)
    }

    /// A user action, never called by initialization, refresh or a view task.
    /// Denied/restricted states belong in System Settings, not repeated prompts.
    @discardableResult func requestAccess() -> Bool {
        let changed = updateAuthorization(authorizationReader())
        if changed && authorization != .notDetermined { refreshAfterAuthorizationChange() }
        guard accessRequestState.begin(authorization: authorization) else { return false }
        isRequestingAccess = accessRequestState.isRequesting
        let requester = authorizationRequesterFactory()
        authorizationRequester = requester
        requester.start { [weak self] newAuthorization in
            guard let self, self.updateAuthorization(newAuthorization) else { return }
            self.refreshAfterAuthorizationChange()
        }
        return true
    }

    private func refreshAfterAuthorizationChange() {
        if isBusy { authorizationRefreshPending = true }
        else { Task { @MainActor [weak self] in await self?.refresh() } }
    }

    @discardableResult private func updateAuthorization(_ value: BluetoothPowerAuthorization) -> Bool {
        let changed = value != authorization
        authorization = value
        accessRequestState.observe(value)
        isRequestingAccess = accessRequestState.isRequesting
        return changed
    }

    /// The UI calls this only for a deliberate click. If no current state has
    /// been read yet, that click refreshes only; it never guesses which way to set.
    @discardableResult func toggle() async -> BluetoothPowerResult {
        guard !isBusy else { return .failed(.busy) }
        guard let enabled else { return await refresh() }
        return await submit(.toggle(expectedEnabled: enabled))
    }

    private func submit(_ command: BluetoothPowerCommand) async -> BluetoothPowerResult {
        guard !isBusy else { return .failed(.busy) }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        isBusy = true; errorKey = nil
        defer {
            isBusy = false
            if authorizationRefreshPending {
                authorizationRefreshPending = false
                Task { @MainActor [weak self] in await self?.refresh() }
            }
        }
        let result = await device.execute(command)
        enabled = result.enabled
        errorKey = result.failure?.messageKey
        availability = result.availability
        return result
    }
}
