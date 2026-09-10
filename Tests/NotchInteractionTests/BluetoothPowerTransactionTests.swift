import XCTest
@testable import NotchInteractionCore

final class BluetoothPowerTransactionTests: XCTestCase {
    func testAccessRequestRequiresUndeterminedAuthorization() {
        for status: BluetoothPowerAuthorization in [.allowed, .denied, .restricted, .unknown] {
            var request = BluetoothAccessRequestState()
            XCTAssertFalse(request.begin(authorization: status))
            XCTAssertFalse(request.hasStarted)
            XCTAssertFalse(request.isRequesting)
        }
    }

    func testExplicitAccessRequestStartsOnlyOnce() {
        var request = BluetoothAccessRequestState()
        XCTAssertTrue(request.begin(authorization: .notDetermined))
        XCTAssertTrue(request.hasStarted)
        XCTAssertTrue(request.isRequesting)
        XCTAssertFalse(request.begin(authorization: .notDetermined))
    }

    func testReadOnlyAuthorizationObservationCannotBeginRequest() {
        var request = BluetoothAccessRequestState()
        for status: BluetoothPowerAuthorization in [.notDetermined, .unknown, .allowed, .denied, .restricted] {
            request.observe(status)
            XCTAssertFalse(request.hasStarted)
            XCTAssertFalse(request.isRequesting)
        }
    }

    func testResolutionClearsRequestingWithoutAllowingRepeatedNativeCreation() {
        for resolution: BluetoothPowerAuthorization in [.allowed, .denied, .restricted] {
            var request = BluetoothAccessRequestState()
            XCTAssertTrue(request.begin(authorization: .notDetermined))
            request.observe(.notDetermined)
            XCTAssertTrue(request.isRequesting)
            request.observe(resolution)
            XCTAssertFalse(request.isRequesting)
            XCTAssertTrue(request.hasStarted)
            XCTAssertFalse(request.begin(authorization: .notDetermined))
        }
    }

    func testPublicAuthorizationRawValuesRemainDistinctFromPower() {
        XCTAssertEqual(BluetoothPowerAuthorization.decode(rawValue: 0), .notDetermined)
        XCTAssertEqual(BluetoothPowerAuthorization.decode(rawValue: 1), .restricted)
        XCTAssertEqual(BluetoothPowerAuthorization.decode(rawValue: 2), .denied)
        XCTAssertEqual(BluetoothPowerAuthorization.decode(rawValue: 3), .allowed)
    }

    func testFutureOrInvalidAuthorizationValuesAreUnknown() {
        for raw in [-1, 4, 255, Int.max] {
            XCTAssertEqual(BluetoothPowerAuthorization.decode(rawValue: raw), .unknown)
        }
    }

    private func execute(_ command: BluetoothPowerCommand,
                         readings: [BluetoothPowerReading],
                         pause: () -> Void = {},
                         now: () -> TimeInterval = { 0 },
                         cancelled: () -> Bool = { false }) -> (BluetoothPowerResult, [Bool], Int) {
        var pending = readings, writes: [Bool] = [], readCount = 0
        let result = BluetoothPowerTransaction.execute(command, read: {
            readCount += 1
            guard !pending.isEmpty else { XCTFail("Unexpected extra power read"); return .unavailable }
            return pending.removeFirst()
        }, write: { writes.append($0) }, now: now, pause: pause, isCancelled: cancelled)
        XCTAssertTrue(pending.isEmpty)
        return (result, writes, readCount)
    }

    func testReadOnlyRefreshNeverCallsSetter() {
        for enabled in [false, true] {
            let (result, writes, _) = execute(.refresh, readings: [.state(enabled)])
            XCTAssertEqual(result, .init(enabled: enabled, failure: nil))
            XCTAssertEqual(result.availability, .supported)
            XCTAssertTrue(writes.isEmpty)
        }
    }

    func testMissingInterfaceAndUnreadableStateAreDistinctAndCannotWrite() {
        let (unsupported, unsupportedWrites, _) = execute(.toggle(expectedEnabled: true), readings: [.unsupported])
        XCTAssertEqual(unsupported, .failed(.unsupported))
        XCTAssertEqual(unsupported.availability, .unsupported)
        XCTAssertTrue(unsupportedWrites.isEmpty)
        let (unavailable, unavailableWrites, _) = execute(.toggle(expectedEnabled: true), readings: [.unavailable])
        XCTAssertEqual(unavailable, .failed(.unavailable))
        XCTAssertEqual(unavailable.availability, .unavailable)
        XCTAssertTrue(unavailableWrites.isEmpty)
    }

    func testOnlyBinaryPowerReadingsAreAccepted() {
        XCTAssertEqual(BluetoothPowerReading.decode(preferencesAvailable: true, rawPower: 0), .state(false))
        XCTAssertEqual(BluetoothPowerReading.decode(preferencesAvailable: true, rawPower: 1), .state(true))
        for raw: Int32? in [nil, -1, 2, 255] {
            XCTAssertEqual(BluetoothPowerReading.decode(preferencesAvailable: true, rawPower: raw), .unavailable)
        }
        XCTAssertEqual(BluetoothPowerReading.decode(preferencesAvailable: false, rawPower: 1), .unsupported)
    }

    func testStaleUIStateIsRefreshedWithoutTogglingOppositeWay() {
        let (result, writes, _) = execute(.toggle(expectedEnabled: true), readings: [.state(false)])
        XCTAssertEqual(result, .init(enabled: false, failure: .changedBeforeWrite))
        XCTAssertTrue(writes.isEmpty)
    }

    func testTurnOnWritesOnceAndWaitsForActualState() {
        var pauses = 0
        let (result, writes, reads) = execute(.toggle(expectedEnabled: false),
            readings: [.state(false), .state(false), .state(false), .state(true)], pause: { pauses += 1 })
        XCTAssertEqual(writes, [true])
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(pauses, 2)
        XCTAssertEqual(result, .init(enabled: true, failure: nil))
    }

    func testTurnOffDoesNotClaimSuccessUntilReadback() {
        let (result, writes, _) = execute(.toggle(expectedEnabled: true), readings: [.state(true), .state(false)])
        XCTAssertEqual(writes, [false])
        XCTAssertEqual(result, .init(enabled: false, failure: nil))
    }

    func testReadbackFailureDoesNotReuseInitialOrTargetState() {
        let (result, writes, _) = execute(.toggle(expectedEnabled: false), readings: [.state(false), .unavailable])
        XCTAssertEqual(writes, [true])
        XCTAssertEqual(result, .failed(.readbackUnavailable))
    }

    func testInterfaceDisappearingDuringTransitionIsUnsupported() {
        let (result, writes, _) = execute(.toggle(expectedEnabled: true), readings: [.state(true), .unsupported])
        XCTAssertEqual(writes, [false])
        XCTAssertEqual(result.availability, .unsupported)
    }

    func testUnconfirmedWriteHasBoundedReadsAndNeverReturnsTarget() {
        var pauses = 0
        let (result, writes, reads) = execute(.toggle(expectedEnabled: false),
            readings: Array(repeating: .state(false), count: 52), pause: { pauses += 1 })
        XCTAssertEqual(writes, [true])
        XCTAssertEqual(reads, 52)
        XCTAssertEqual(pauses, 50)
        XCTAssertEqual(result, .init(enabled: false, failure: .unconfirmed))
    }

    func testDeadlineStopsPollingAndReportsLastActualValue() {
        var time: TimeInterval = 0
        let (result, writes, reads) = execute(.toggle(expectedEnabled: true), readings: [.state(true), .state(true)],
            pause: { time = 5.1 }, now: { time })
        XCTAssertEqual(writes, [false])
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(result, .init(enabled: true, failure: .timedOut))
    }

    func testCancellationBeforeReadDoesNothing() {
        let (result, writes, reads) = execute(.toggle(expectedEnabled: true), readings: [], cancelled: { true })
        XCTAssertEqual(result, .failed(.cancelled))
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(reads, 0)
    }

    func testCancellationBetweenPreReadAndWriteDoesNotInvokeSetter() {
        var checks = 0
        let (result, writes, _) = execute(.toggle(expectedEnabled: true), readings: [.state(true)], cancelled: {
            checks += 1
            return checks == 2
        })
        XCTAssertEqual(result, .failed(.cancelled))
        XCTAssertTrue(writes.isEmpty)
    }

    func testCancellationAfterWriteDoesNotAutomaticallyRestorePower() {
        var cancelled = false
        let (result, writes, _) = execute(.toggle(expectedEnabled: false), readings: [.state(false), .state(false)],
            pause: { cancelled = true }, cancelled: { cancelled })
        XCTAssertEqual(writes, [true])
        XCTAssertEqual(result, .failed(.cancelled))
    }

    func testHelperArgumentsRoundTripOnlyFixedCommands() {
        for command: BluetoothPowerCommand in [.refresh, .toggle(expectedEnabled: false), .toggle(expectedEnabled: true)] {
            XCTAssertEqual(BluetoothPowerHelperProtocol.command(from: BluetoothPowerHelperProtocol.arguments(for: command)), command)
        }
    }

    func testHelperRejectsExtraArgumentsAndNonBinaryPower() {
        let flag = BluetoothPowerHelperProtocol.flag
        for arguments in [[], [flag], [flag, "read", "extra"], [flag, "toggle"],
                          [flag, "toggle", "true"], [flag, "toggle", "2"],
                          [flag, "toggle", "1", "extra"], ["read"], [flag, "write", "1"]] {
            XCTAssertNil(BluetoothPowerHelperProtocol.command(from: arguments))
        }
    }

    func testHelperWireRoundTripsActualStatesAndFailures() throws {
        let results: [BluetoothPowerResult] = [
            .init(enabled: false, failure: nil), .init(enabled: true, failure: nil),
            .init(enabled: false, failure: .changedBeforeWrite), .init(enabled: true, failure: .unconfirmed),
            .init(enabled: false, failure: .timedOut), .failed(.timedOut),
            .failed(.unsupported), .failed(.unavailable), .failed(.readbackUnavailable),
            .failed(.cancelled), .failed(.busy)
        ]
        for result in results {
            let data = try XCTUnwrap(BluetoothPowerHelperProtocol.encode(result))
            XCTAssertEqual(BluetoothPowerHelperProtocol.decode(data, exitCode: 0), result)
        }
    }

    func testHelperNeverAcceptsFailureExitAsSuccess() throws {
        let data = try XCTUnwrap(BluetoothPowerHelperProtocol.encode(.init(enabled: true, failure: nil)))
        for code: Int32 in [-1, 1, 64, 70, 74] {
            XCTAssertEqual(BluetoothPowerHelperProtocol.decode(data, exitCode: code), .failed(.unavailable))
        }
    }

    func testHelperRejectsMissingStateUnknownVersionAndMalformedOutput() {
        for raw in ["", "true", "{}", "not JSON", "{\"version\":1}",
                    "{\"version\":2,\"enabled\":true}", "{\"version\":1,\"enabled\":1}",
                    "{\"version\":1,\"enabled\":true,\"failure\":\"invented\"}",
                    String(repeating: " ", count: 513)] {
            XCTAssertEqual(BluetoothPowerHelperProtocol.decode(Data(raw.utf8), exitCode: 0), .failed(.unavailable))
        }
    }

    func testHelperRejectsContradictoryStateFailurePairs() throws {
        for failure: BluetoothPowerFailure in [.unsupported, .unavailable, .readbackUnavailable, .cancelled, .busy] {
            let data = try XCTUnwrap(BluetoothPowerHelperProtocol.encode(.init(enabled: true, failure: failure)))
            XCTAssertEqual(BluetoothPowerHelperProtocol.decode(data, exitCode: 0), .failed(.unavailable))
        }
        for failure: BluetoothPowerFailure in [.changedBeforeWrite, .unconfirmed] {
            let data = try XCTUnwrap(BluetoothPowerHelperProtocol.encode(.failed(failure)))
            XCTAssertEqual(BluetoothPowerHelperProtocol.decode(data, exitCode: 0), .failed(.unavailable))
        }
    }
}
