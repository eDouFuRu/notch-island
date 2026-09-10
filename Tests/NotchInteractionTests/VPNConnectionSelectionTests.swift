import XCTest
@testable import NotchInteractionCore

final class VPNConnectionSelectionTests: XCTestCase {
    private let a = "11111111-2222-3333-4444-555555555555"
    private let b = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private func row(_ id: String, _ state: String, name: String = "Office VPN", kind: String = "VPN:com.example.tunnel", enabled: Bool = true) -> String {
        "\(enabled ? "*" : " ") (\(state))  \(id) VPN (Example)  \"\(name)\"  [\(kind)]"
    }
    private func output(_ rows: [String]) -> Data {
        (VPNConnectionListParser.header + "\n" + rows.joined(separator: "\n") + "\n").data(using: .utf8)!
    }
    private func ok(_ rows: [String]) -> VPNConnectionProcessOutput { .init(exitCode: 0, output: output(rows)) }

    func testParsesProviderIPSecAndL2TPWithStableIDsAndActualTransitions() throws {
        let c = "22222222-2222-3333-4444-555555555555"
        let read = try XCTUnwrap(VPNConnectionListParser.parse(output([
            row(a, "Connected", name: "公司 VPN"), row(b, "Connecting", name: "Home", kind: "IPSec"),
            row(c, "Disconnecting", kind: "PPP:L2TP")
        ])))
        XCTAssertEqual(read.services.map(\.id), [a, b, c])
        XCTAssertEqual(read.services.map(\.status), [.connected, .connecting, .disconnecting])
        XCTAssertTrue(read.services[0].canToggle)
        XCTAssertFalse(read.services[1].canToggle)
    }

    func testDoesNotOfferDisabledVPNOrOrdinaryPPPoEAndDoesNotGuessUnknownStatus() throws {
        let c = "22222222-2222-3333-4444-555555555555"
        let read = try XCTUnwrap(VPNConnectionListParser.parse(output([
            row(a, "Invalid", enabled: false), row(b, "Connected", kind: "PPP:PPPoE"), row(c, "Invalid")
        ])))
        XCTAssertEqual(read.unsupportedServiceCount, 2)
        XCTAssertEqual(read.services.count, 1)
        XCTAssertEqual(read.services[0].status, .unknown)
        XCTAssertFalse(read.services[0].canToggle)
    }

    func testDuplicateIDsMalformedOutputAndOversizeAreRejectedNotReportedAsEmpty() {
        XCTAssertNil(VPNConnectionListParser.parse(output([row(a, "Connected"), row(a, "Disconnected")])))
        XCTAssertNil(VPNConnectionListParser.parse(output(["unexpected status/configuration payload"])))
        XCTAssertNil(VPNConnectionListParser.parse(Data()))
        XCTAssertNil(VPNConnectionListParser.parse(Data(repeating: 32, count: VPNConnectionListParser.maximumBytes + 1)))
        XCTAssertNil(VPNConnectionListParser.parse(output([row(a, "Disconnected", name: "name\nsecond line")])))
        XCTAssertEqual(VPNConnectionListParser.parse(output([]))?.services, [])
    }

    func testNamesAreDisplayOnlyAndCommandsAcceptCanonicalUUIDOnly() throws {
        let name = #"Quotes "stay"; $(not-a-command) `literal`"#
        let read = try XCTUnwrap(VPNConnectionListParser.parse(output([row(a, "Disconnected", name: name)])))
        XCTAssertEqual(read.services[0].displayName, name)
        XCTAssertEqual(VPNConnectionInvocation.connect(a).arguments, ["--nc", "start", a])
        XCTAssertEqual(VPNConnectionInvocation.disconnect(a).arguments, ["--nc", "stop", a])
        XCTAssertNil(VPNConnectionInvocation.connect(name).arguments)
        XCTAssertNil(VPNConnectionInvocation.disconnect("--help").arguments)
    }

    func testRefreshNeverWritesAndEmptyMeansNoControllableServicesOnly() {
        var calls: [VPNConnectionInvocation] = []
        let result = VPNConnectionTransaction.execute(.refresh) { invocation in
            calls.append(invocation); return self.ok([])
        }
        XCTAssertEqual(calls, [.list])
        XCTAssertEqual(result.failure, .noServices)
        XCTAssertFalse(result.requestAccepted)
    }

    func testAcceptedCommandRequiresActualReadbackAndNeverRepeatsWrite() {
        var calls: [VPNConnectionInvocation] = []
        let request = VPNConnectionRequest(serviceID: a, connected: true, expectedStatus: .disconnected)
        let result = VPNConnectionTransaction.execute(.set(request)) { invocation in
            calls.append(invocation)
            if invocation == .connect(self.a) { return .init(exitCode: 0, output: Data()) }
            return self.ok([self.row(self.a, calls.count == 1 ? "Disconnected" : "Connecting")])
        }
        XCTAssertEqual(calls, [.list, .connect(a), .list])
        XCTAssertTrue(result.requestAccepted)
        XCTAssertEqual(result.failure, .confirmationPending)
        XCTAssertEqual(result.reading?.services.first?.status, .connecting)
    }

    func testAlreadyConnectedAndMissingOrTransitioningSourcesNeverWrite() {
        for state in ["Connected", "Connecting", "Disconnecting", "Invalid"] {
            var calls: [VPNConnectionInvocation] = []
            let result = VPNConnectionTransaction.execute(.set(.init(serviceID: a, connected: true, expectedStatus: .disconnected))) {
                calls.append($0); return self.ok([self.row(self.a, state)])
            }
            XCTAssertEqual(calls, [.list])
            XCTAssertFalse(result.requestAccepted)
            if state == "Connected" { XCTAssertNil(result.failure) } else { XCTAssertNotNil(result.failure) }
        }
        let result = VPNConnectionTransaction.execute(.set(.init(serviceID: b, connected: true, expectedStatus: .disconnected))) { _ in self.ok([self.row(self.a, "Disconnected")]) }
        XCTAssertEqual(result.failure, .serviceMissing)
    }

    func testTimeoutAndCancellationCannotRetryOrClaimOldStatusAsCurrent() {
        for cancelled in [false, true] {
            var calls: [VPNConnectionInvocation] = []
            let result = VPNConnectionTransaction.execute(.set(.init(serviceID: a, connected: false, expectedStatus: .connected))) { invocation in
                calls.append(invocation)
                if invocation == .list { return self.ok([self.row(self.a, "Connected")]) }
                return .init(exitCode: -1, output: Data(), timedOut: !cancelled, cancelled: cancelled)
            }
            XCTAssertEqual(calls, [.list, .disconnect(a)])
            XCTAssertNil(result.reading)
            XCTAssertEqual(result.failure, cancelled ? .cancelled : .timedOut)
        }
        var called = false
        _ = VPNConnectionTransaction.execute(.refresh, run: { _ in called = true; return self.ok([]) }, isCancelled: { true })
        XCTAssertFalse(called)
    }

    func testConfirmedDisconnectAndRejectedConnectRemainDistinct() {
        var calls = 0
        let success = VPNConnectionTransaction.execute(.set(.init(serviceID: a, connected: false, expectedStatus: .connected))) { invocation in
            calls += 1
            if invocation == .disconnect(self.a) { return .init(exitCode: 0, output: Data()) }
            return self.ok([self.row(self.a, calls == 1 ? "Connected" : "Disconnected")])
        }
        XCTAssertNil(success.failure)
        XCTAssertEqual(success.reading?.services[0].status, .disconnected)
        let rejected = VPNConnectionTransaction.execute(.set(.init(serviceID: a, connected: true, expectedStatus: .disconnected))) { invocation in
            invocation == .list ? self.ok([self.row(self.a, "Disconnected")]) : .init(exitCode: 1, output: Data())
        }
        XCTAssertEqual(rejected.failure, .requestRejected)
        XCTAssertNil(rejected.reading)
        XCTAssertFalse(rejected.requestAccepted)
    }
}
