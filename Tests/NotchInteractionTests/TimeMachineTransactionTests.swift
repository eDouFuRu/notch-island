import XCTest
@testable import NotchInteractionCore

final class TimeMachineTransactionTests: XCTestCase {
    private func plist(_ dictionary: [String: Any]) -> TimeMachineProcessOutput {
        .init(exitCode: 0,
              output: try! PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0), error: Data())
    }
    private func status(_ running: Bool) -> TimeMachineProcessOutput { plist(["Running": running]) }
    private func destinations(_ configured: Bool) -> TimeMachineProcessOutput {
        plist(["Destinations": configured ? [["ID": "fixture", "Name": "must not be retained"]] : []])
    }
    private var accepted: TimeMachineProcessOutput { .init(exitCode: 0, output: Data(), error: Data()) }

    private func run(_ command: TimeMachineCommand, responses: [TimeMachineProcessOutput]) -> (TimeMachineResult, [TimeMachineInvocation], Int) {
        var pending = responses, calls: [TimeMachineInvocation] = [], pauses = 0
        let result = TimeMachineTransaction.execute(command, run: { invocation in
            calls.append(invocation)
            guard !pending.isEmpty else { XCTFail("Unexpected extra CLI invocation"); return .init(exitCode: 1, output: Data(), error: Data()) }
            return pending.removeFirst()
        }, pause: { pauses += 1 })
        XCTAssertTrue(pending.isEmpty)
        return (result, calls, pauses)
    }

    func testRefreshIsReadOnlyAndRetainsOnlyBooleans() {
        let (result, calls, _) = run(.refresh, responses: [status(true), destinations(true)])
        XCTAssertEqual(calls, [.status, .destinations])
        XCTAssertEqual(result, .init(running: true, configAvailable: true, failure: nil))
    }

    func testStartRequiresActualRunningReadbackAfterCommandExit() {
        let (result, calls, pauses) = run(.start, responses: [status(false), destinations(true), accepted, status(false), status(true)])
        XCTAssertEqual(calls, [.status, .destinations, .start, .status, .status])
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(result, .init(running: true, configAvailable: true, failure: nil))
    }

    func testExplicitStopWorksForExistingBackupAndConfirmsNotRunning() {
        let (result, calls, _) = run(.stop, responses: [status(true), destinations(true), accepted, status(false)])
        XCTAssertEqual(calls, [.status, .destinations, .stop, .status])
        XCTAssertEqual(result, .init(running: false, configAvailable: true, failure: nil))
    }

    func testAlreadyInRequestedStateDoesNotSendAnAction() {
        XCTAssertEqual(run(.start, responses: [status(true), destinations(true)]).1, [.status, .destinations])
        XCTAssertEqual(run(.stop, responses: [status(false), destinations(true)]).1, [.status, .destinations])
    }

    func testNoDestinationCannotStartBackup() {
        let (result, calls, _) = run(.start, responses: [status(false), destinations(false)])
        XCTAssertEqual(calls, [.status, .destinations])
        XCTAssertEqual(result, .init(running: false, configAvailable: false, failure: .noDestination))
    }

    func testMacOS26EmptyDestinationDictionaryIsValidUnconfiguredState() {
        // Observed from a successful, read-only destinationinfo -X on this Mac.
        let (refreshed, refreshCalls, _) = run(.refresh, responses: [status(false), plist([:])])
        XCTAssertEqual(refreshCalls, [.status, .destinations])
        XCTAssertEqual(refreshed, .init(running: false, configAvailable: false, failure: nil))
        let (started, startCalls, _) = run(.start, responses: [status(false), plist([:])])
        XCTAssertEqual(startCalls, [.status, .destinations])
        XCTAssertEqual(started, .init(running: false, configAvailable: false, failure: .noDestination))
    }

    func testUnknownOrFailedDestinationSchemaIsNotAssumedUnconfigured() {
        XCTAssertNil(TimeMachineTransaction.configured(from: plist(["Unknown": []])))
        XCTAssertNil(TimeMachineTransaction.configured(from: plist(["Destinations": "not an array"])))
        let failedEmpty = TimeMachineProcessOutput(exitCode: 1, output: plist([:]).output, error: Data())
        XCTAssertNil(TimeMachineTransaction.configured(from: failedEmpty))
    }

    func testMalformedStateCannotStartOrStopBackup() {
        for command in [TimeMachineCommand.start, .stop] {
            let (result, calls, _) = run(command, responses: [plist(["BackupPhase": "Copying"])])
            XCTAssertEqual(calls, [.status])
            XCTAssertEqual(result, .failed(.unavailable))
        }
        for value: Any in ["1", 2, -1, 0.5, 1.0] {
            XCTAssertNil(TimeMachineTransaction.running(from: plist(["Running": value])))
        }
        XCTAssertEqual(TimeMachineTransaction.running(from: plist(["Running": 1])), true)
    }

    func testPermissionDeniedStopsBeforeMutationWithoutRawMessage() {
        let denied = TimeMachineProcessOutput(exitCode: 77, output: Data(),
            error: Data("tmutil: destinationinfo requires Full Disk Access privileges. private destination detail".utf8))
        let (result, calls, _) = run(.start, responses: [status(false), denied])
        XCTAssertEqual(calls, [.status, .destinations])
        XCTAssertEqual(result.failure, .permissionRequired)
        XCTAssertFalse(result.failure!.messageKey.contains("private destination detail"))
    }

    func testNonzeroActionDoesNotReuseStalePreActionState() {
        let rejected = TimeMachineProcessOutput(exitCode: 1, output: Data(), error: Data("rejected".utf8))
        let (result, calls, _) = run(.start, responses: [status(false), destinations(true), rejected])
        XCTAssertEqual(calls, [.status, .destinations, .start])
        XCTAssertEqual(result, .failed(.commandFailed, configured: true))
    }

    func testPollingIsBoundedAndSuccessExitAloneCannotClaimRunning() {
        let (result, calls, pauses) = run(.start, responses: [status(false), destinations(true), accepted] + Array(repeating: status(false), count: 10))
        XCTAssertEqual(calls.filter { $0 == .start }.count, 1)
        XCTAssertEqual(pauses, 9)
        XCTAssertEqual(result, .init(running: false, configAvailable: true, failure: .unconfirmed))
    }

    func testCancellationAfterStartNeverAutomaticallyStopsBackup() {
        let cancelled = TimeMachineProcessOutput(exitCode: -1, output: Data(), error: Data(), cancelled: true)
        let (result, calls, _) = run(.start, responses: [status(false), destinations(true), accepted, cancelled])
        XCTAssertEqual(result, .failed(.cancelled, configured: true))
        XCTAssertFalse(calls.contains(.stop))
    }

    func testTimeoutRemainsUnknownInsteadOfAssumingIdle() {
        let timedOut = TimeMachineProcessOutput(exitCode: -1, output: Data(), error: Data(), timedOut: true)
        let (result, calls, _) = run(.refresh, responses: [timedOut])
        XCTAssertEqual(calls, [.status])
        XCTAssertEqual(result, .failed(.timedOut))
    }

    func testEmptyConfigurationDiagnosticMustMatchExactly() {
        let empty = TimeMachineProcessOutput(exitCode: 1, output: Data(), error: Data("tmutil: No destinations configured.\n".utf8))
        XCTAssertEqual(TimeMachineTransaction.configured(from: empty), false)
        let other = TimeMachineProcessOutput(exitCode: 1, output: Data(), error: Data("could not read destinations".utf8))
        XCTAssertNil(TimeMachineTransaction.configured(from: other))
    }

    func testInvocationAllowlistNeverChangesScheduleOrDestination() {
        XCTAssertEqual(TimeMachineInvocation.start.arguments, ["startbackup"])
        XCTAssertEqual(TimeMachineInvocation.stop.arguments, ["stopbackup"])
        XCTAssertEqual(TimeMachineInvocation.status.arguments, ["status", "-X"])
        XCTAssertEqual(TimeMachineInvocation.destinations.arguments, ["destinationinfo", "-X"])
    }
}
