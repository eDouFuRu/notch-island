// Tests only: launches a compiled fake helper, never the app or a Bluetooth API.
import Foundation
import Darwin

actor RecordingDevice: BluetoothPowerControlling {
    private var commands: [BluetoothPowerCommand] = []
    private var paused: CheckedContinuation<BluetoothPowerResult, Never>?
    private var shouldPause = false
    func execute(_ command: BluetoothPowerCommand) async -> BluetoothPowerResult {
        commands.append(command)
        if shouldPause { return await withCheckedContinuation { paused = $0 } }
        switch command {
        case .refresh: return .init(enabled: true, failure: nil)
        case .toggle: return .init(enabled: false, failure: nil)
        }
    }
    func allCommands() -> [BluetoothPowerCommand] { commands }
    func pauseNext() { shouldPause = true }
    func hasPaused() -> Bool { paused != nil }
    func release() { shouldPause = false; paused?.resume(returning: .failed(.unavailable)); paused = nil }
}

@MainActor final class FakeBluetoothAuthorizationRequest: BluetoothAuthorizationRequesting {
    private var update: (@MainActor (BluetoothPowerAuthorization) -> Void)?
    private(set) var starts = 0
    func start(_ update: @escaping @MainActor (BluetoothPowerAuthorization) -> Void) {
        starts += 1
        self.update = update
    }
    func emit(_ value: BluetoothPowerAuthorization) { update?(value) }
}
@main struct Harness {
    static func check(_ pass: Bool, _ label: String) {
        guard pass else { fatalError(label) }
        print("PASS \(label)")
    }
    static var helperRoot: String { CommandLine.arguments[1] }
    static func device(_ name: String) -> NativeBluetoothPowerDevice {
        .init(executableURL: URL(fileURLWithPath: "\(helperRoot)/\(name)"))
    }
    static func noFakeChild() -> Bool {
        guard let text = try? String(contentsOfFile: "\(helperRoot)/child.pid", encoding: .utf8), let pid = Int32(text) else { return false }
        return kill(pid, 0) == -1 && errno == ESRCH
    }
    @MainActor static func main() async {
        check(BluetoothPowerHelper.runIfRequested(arguments: ["app"]) == nil, "normal app route does not load native API")
        check(BluetoothPowerHelper.runIfRequested(arguments: ["app", "--island-bluetooth-power", "unknown"]) == 64, "invalid helper route rejected")
        let normal = device("fake")
        check(await normal.execute(.refresh) == .init(enabled: false, failure: nil), "fake child read parses actual bool")
        check(await normal.execute(.toggle(expectedEnabled: false)) == .init(enabled: true, failure: nil), "fixed toggle command passes expected state")
        check(await device("bad").execute(.refresh) == .failed(.unavailable), "malformed child output cannot report success")
        check(await device("exit").execute(.refresh) == .failed(.unavailable), "nonzero child exit cannot report success")
        check(await NativeBluetoothPowerDevice(executableURL: nil).execute(.refresh) == .failed(.unsupported), "missing app executable unsupported")
        let start = ProcessInfo.processInfo.systemUptime
        check(await device("hang").execute(.refresh) == .failed(.timedOut), "hung native substitute has bounded timeout")
        check(ProcessInfo.processInfo.systemUptime - start < 11 && noFakeChild(), "SIGTERM-resistant own child killed and reaped")
        let task = Task { await device("hang").execute(.refresh) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        check(await task.value == .failed(.cancelled), "cancelled resistant child returns cancelled")
        check(noFakeChild(), "cancellation leaves no fake helper running")
        let recording = RecordingDevice()
        var authorizationReads = 0
        let model = SystemBluetoothControl(device: recording, authorizationReader: {
            authorizationReads += 1
            return .denied
        })
        check(await recording.allCommands().isEmpty && model.enabled == nil && !model.isBusy, "model initialization has no hardware query")
        check(authorizationReads == 0 && model.authorization == .unknown, "initialization does not query process authorization")
        _ = await model.toggle()
        check(await recording.allCommands() == [.refresh] && model.enabled == true, "unknown-state click only refreshes")
        check(authorizationReads == 1 && model.authorization == .denied && model.availability == .supported,
              "refresh reports authorization separately without overriding SPI outcome")
        _ = await model.toggle()
        check(await recording.allCommands() == [.refresh, .toggle(expectedEnabled: true)] && model.enabled == false, "deliberate click carries last confirmed state")
        await recording.pauseNext()
        let refresh = Task { await model.refresh() }
        while !(await recording.hasPaused()) { await Task.yield() }
        check(model.isBusy, "busy visible while processing")
        check(await model.toggle() == .failed(.busy), "duplicate click cannot write")
        await recording.release()
        _ = await refresh.value
        check(!model.isBusy && model.enabled == nil && model.availability == .unavailable && model.errorKey != nil, "failure releases busy without retaining fake success")

        let accessDevice = RecordingDevice()
        let accessRequester = FakeBluetoothAuthorizationRequest()
        var accessFactories = 0
        var accessStatus = BluetoothPowerAuthorization.notDetermined
        let accessModel = SystemBluetoothControl(device: accessDevice, authorizationReader: { accessStatus },
            authorizationRequesterFactory: { accessFactories += 1; return accessRequester })
        check(accessFactories == 0 && !accessModel.isRequestingAccess, "construction does not allocate an authorization requester")
        _ = await accessModel.refresh()
        check(accessFactories == 0 && accessRequester.starts == 0, "passive refresh cannot request Bluetooth permission")
        check(accessModel.requestAccess() && accessFactories == 1 && accessRequester.starts == 1,
              "explicit access action creates exactly one requester")
        check(accessModel.isRequestingAccess && !accessModel.requestAccess() && accessFactories == 1,
              "pending access action prevents duplicate requester creation")
        accessRequester.emit(.notDetermined)
        check(await accessDevice.allCommands() == [.refresh], "unchanged permission callback does not trigger power operations")
        accessStatus = .allowed
        accessRequester.emit(.allowed)
        for _ in 0..<100 {
            if await accessDevice.allCommands().count >= 2 { break }
            await Task.yield()
        }
        check(await accessDevice.allCommands() == [.refresh, .refresh], "permission resolution schedules only a read, never a toggle")
        check(accessModel.authorization == .allowed && !accessModel.isRequestingAccess, "permission resolution clears requesting state")
        check(!accessModel.requestAccess() && accessFactories == 1, "allowed state cannot allocate another requester")
        accessRequester.emit(.allowed)
        await Task.yield()
        check(await accessDevice.allCommands() == [.refresh, .refresh], "repeated delegate state does not replay permission refresh")

        for deniedStatus: BluetoothPowerAuthorization in [.denied, .restricted] {
            var creations = 0
            let blockedModel = SystemBluetoothControl(device: RecordingDevice(), authorizationReader: { deniedStatus },
                authorizationRequesterFactory: { creations += 1; return FakeBluetoothAuthorizationRequest() })
            check(!blockedModel.requestAccess() && creations == 0 && !blockedModel.isRequestingAccess,
                  "denied or restricted permission never opens a repeated authorization request")
        }

        let pendingDevice = RecordingDevice()
        let pendingRequester = FakeBluetoothAuthorizationRequest()
        var pendingStatus = BluetoothPowerAuthorization.notDetermined
        let pendingModel = SystemBluetoothControl(device: pendingDevice, authorizationReader: { pendingStatus },
                                                  authorizationRequesterFactory: { pendingRequester })
        await pendingDevice.pauseNext()
        let pendingRead = Task { await pendingModel.refresh() }
        while !(await pendingDevice.hasPaused()) { await Task.yield() }
        check(pendingModel.requestAccess(), "explicit permission action remains available during an existing power read")
        pendingStatus = .allowed
        pendingRequester.emit(.allowed)
        check(await pendingDevice.allCommands() == [.refresh], "permission resolution does not overlap an in-flight power read")
        await pendingDevice.release()
        _ = await pendingRead.value
        for _ in 0..<100 {
            if await pendingDevice.allCommands().count >= 2 { break }
            await Task.yield()
        }
        check(await pendingDevice.allCommands() == [.refresh, .refresh], "permission resolution queues one read after busy completes")
    }
}
