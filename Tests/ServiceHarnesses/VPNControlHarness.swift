// Compile alongside Core/VPNConnectionSelection.swift and SystemVPNControl.swift.
// Every device is injected; this executable never creates a real scutil device.
import Foundation

private actor FakeVPNDevice: VPNConnectionControlling {
    private var results: [VPNConnectionResult]
    private var calls: [VPNConnectionCommand] = []
    private let delay: UInt64
    init(_ results: [VPNConnectionResult], delay: UInt64 = 0) {
        self.results = results; self.delay = delay
    }
    func execute(_ command: VPNConnectionCommand) async -> VPNConnectionResult {
        calls.append(command)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        guard !results.isEmpty else { return .init(reading: nil, failure: .unavailable) }
        return results.removeFirst()
    }
    func writeCount() -> Int { calls.filter { if case .set = $0 { true } else { false } }.count }
    func callCount() -> Int { calls.count }
}

@main private struct VPNControlHarness {
    static let id = "11111111-2222-3333-4444-555555555555"
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool) {
        checks += 1; precondition(condition(), "VPN service assertion \(checks) failed")
    }
    static func result(_ status: VPNConnectionState?, failure: VPNConnectionFailure? = nil,
                       accepted: Bool = false) -> VPNConnectionResult {
        .init(reading: .init(services: status.map { [.init(id: id, displayName: "Fake VPN", status: $0)] } ?? [],
                            unsupportedServiceCount: 0), failure: failure, requestAccepted: accepted)
    }

    @MainActor static func main() async {
        let device = FakeVPNDevice([result(.disconnected), result(.connecting, failure: .confirmationPending, accepted: true), result(.connecting), result(.connected)])
        let control = SystemVPNControl(device: device, confirmationDelay: 1, confirmationAttempts: 3)
        let refreshed = await control.refresh()
        check(refreshed); check(control.services[0].status == .disconnected)
        let initialWrites = await device.writeCount(); check(initialWrites == 0)
        let connected = await control.setConnected(id: id, connected: true)
        check(connected); check(control.services[0].status == .connected); check(control.errorKey == nil); check(!control.isBusy)
        let writes = await device.writeCount(); check(writes == 1)

        let unchangedDevice = FakeVPNDevice([result(.connected), result(.connected, failure: .confirmationPending, accepted: true), result(.connected)])
        let unchanged = SystemVPNControl(device: unchangedDevice, confirmationDelay: 1, confirmationAttempts: 1)
        _ = await unchanged.refresh()
        let stopped = await unchanged.setConnected(id: id, connected: false)
        check(!stopped); check(unchanged.services[0].status == .connected)
        check(unchanged.errorKey == VPNConnectionFailure.confirmationPending.messageKey)
        let unchangedWrites = await unchangedDevice.writeCount(); check(unchangedWrites == 1)

        let missingDevice = FakeVPNDevice([result(.disconnected), result(.connecting, failure: .confirmationPending, accepted: true), result(nil)])
        let missing = SystemVPNControl(device: missingDevice, confirmationDelay: 1, confirmationAttempts: 2)
        _ = await missing.refresh()
        let missingSuccess = await missing.setConnected(id: id, connected: true)
        check(!missingSuccess); check(missing.services.isEmpty)
        check(missing.errorKey == VPNConnectionFailure.serviceMissing.messageKey)

        let unknownDevice = FakeVPNDevice([result(.disconnected), result(.connecting, failure: .confirmationPending, accepted: true), result(.unknown)])
        let unknown = SystemVPNControl(device: unknownDevice, confirmationDelay: 1, confirmationAttempts: 2)
        _ = await unknown.refresh()
        let unknownSuccess = await unknown.setConnected(id: id, connected: true)
        check(!unknownSuccess); check(unknown.errorKey == VPNConnectionFailure.statusUnknown.messageKey)

        let failedDevice = FakeVPNDevice([result(.disconnected), .init(reading: nil, failure: .requestRejected, statusCode: 1)])
        let failed = SystemVPNControl(device: failedDevice)
        _ = await failed.refresh()
        let failedSuccess = await failed.setConnected(id: id, connected: true)
        check(!failedSuccess); check(failed.services.isEmpty); check(failed.lastStatusCode == 1)
        check(failed.errorKey == VPNConnectionFailure.requestRejected.messageKey)

        let busyDevice = FakeVPNDevice([result(.disconnected), result(.connected, accepted: true)], delay: 30_000_000)
        let busy = SystemVPNControl(device: busyDevice)
        _ = await busy.refresh()
        let first = Task { await busy.setConnected(id: id, connected: true) }
        try? await Task.sleep(nanoseconds: 1_000_000)
        let duplicate = await busy.setConnected(id: id, connected: true)
        check(!duplicate)
        let busyRefresh = await busy.refresh(); check(!busyRefresh)
        let firstSuccess = await first.value; check(firstSuccess)
        let busyWrites = await busyDevice.writeCount(); check(busyWrites == 1)

        let cancelDevice = FakeVPNDevice([result(.disconnected), result(.connecting, failure: .confirmationPending, accepted: true)])
        let cancelled = SystemVPNControl(device: cancelDevice, confirmationDelay: 10_000_000_000)
        _ = await cancelled.refresh()
        let pending = Task { await cancelled.setConnected(id: id, connected: true) }
        try? await Task.sleep(nanoseconds: 2_000_000)
        pending.cancel()
        let cancelledSuccess = await pending.value
        check(!cancelledSuccess); check(!cancelled.isBusy)
        check(cancelled.errorKey == VPNConnectionFailure.cancelled.messageKey)
        let cancelledWrites = await cancelDevice.writeCount(); check(cancelledWrites == 1)
        let cancelledCalls = await cancelDevice.callCount(); check(cancelledCalls == 2)

        let monitorDevice = FakeVPNDevice([result(.disconnected)])
        let monitor = SystemVPNControl(device: monitorDevice)
        let watching = Task { await monitor.monitorWhileVisible() }
        try? await Task.sleep(nanoseconds: 2_000_000)
        watching.cancel(); await watching.value
        let monitorWrites = await monitorDevice.writeCount(); check(monitorWrites == 0)
        check(!monitor.isBusy)
        print("VPN fake service assertions passed: \(checks); actual network writes: 0")
    }
}
