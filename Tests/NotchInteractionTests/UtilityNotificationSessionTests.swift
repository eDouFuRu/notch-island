import XCTest
@testable import NotchInteractionCore

final class UtilityNotificationSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testOlderSnapshotWithoutNotificationIDsStillRestores() throws {
        var original = UtilityClockSnapshot()
        _ = original.countdown.start(seconds: 60, at: start)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "timerNotificationID")
        json.removeValue(forKey: "alarmNotificationID")
        let restored = try JSONDecoder().decode(UtilityClockSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.countdown.deadline, start.addingTimeInterval(60))
        XCTAssertNil(restored.timerNotificationID)
        XCTAssertNil(restored.alarmNotificationID)
    }

    func testRestartReusesSameSessionIDAndDoesNotCreateAnotherRequest() throws {
        var state = UtilityClockSnapshot()
        _ = state.countdown.start(seconds: 120, at: start)
        let id = state.ensureNotificationID(for: .timer, token: "original")
        state = try JSONDecoder().decode(UtilityClockSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state.ensureNotificationID(for: .timer, token: "would-be-another-request"), id)
        XCTAssertEqual(state.notificationIDs, [id])
    }

    func testDelayedOldRequestCleanupCannotCancelNewSessionOrIndependentAlarm() {
        var state = UtilityClockSnapshot()
        _ = state.countdown.start(seconds: 60, at: start)
        let old = state.ensureNotificationID(for: .timer, token: "A")
        state.countdown.pause(at: start.addingTimeInterval(2))
        XCTAssertEqual(state.invalidateNotification(for: .timer), old)
        state.countdown.resume(at: start.addingTimeInterval(5))
        let new = state.ensureNotificationID(for: .timer, token: "B")
        state.alarmDate = start.addingTimeInterval(100)
        let alarm = state.ensureNotificationID(for: .alarm, token: "alarm")
        XCTAssertNotEqual(old, new)
        // This is evaluated against current ownership after a pending-request read suspends.
        let stale = state.staleNotificationIDs(in: [old, new, alarm, "other.feature.request", "island.utility.timer"])
        XCTAssertEqual(Set(stale), [old, "island.utility.timer"])
        XCTAssertEqual(state.notificationIDs, [new, alarm])
        state.countdown.cancel()
        XCTAssertEqual(state.invalidateNotification(for: .timer), new)
        XCTAssertEqual(state.notificationIDs, [alarm])
    }

    func testSettlingAtDeadlineDoesNotRevokeNotificationBeforeSystemDelivery() {
        var state = UtilityClockSnapshot()
        _ = state.countdown.start(seconds: 1, at: start)
        let timer = state.ensureNotificationID(for: .timer, token: "timer")
        state.alarmDate = start.addingTimeInterval(1)
        let alarm = state.ensureNotificationID(for: .alarm, token: "alarm")
        XCTAssertTrue(state.countdown.settle(at: start.addingTimeInterval(1)))
        XCTAssertTrue(state.settleAlarm(at: start.addingTimeInterval(1)))
        XCTAssertNil(state.countdown.deadline)
        XCTAssertNil(state.alarmDate)
        XCTAssertEqual(state.notificationIDs, [timer, alarm])
        XCTAssertTrue(state.staleNotificationIDs(in: [timer, alarm]).isEmpty)
    }

    func testOnlyValidNumericDurationCanStartIncludingOneSecondAnd24HourBounds() {
        XCTAssertEqual(UtilityTimerInput.duration(minutes: "0", seconds: "1"), 1)
        XCTAssertEqual(UtilityTimerInput.duration(minutes: "1440", seconds: "0"), 86_400)
        XCTAssertEqual(UtilityTimerInput.duration(minutes: " 05 ", seconds: "09"), 309)
        for pair in [("", "1"), ("abc", "0"), ("5abc", "0"), ("-1", "0"), ("1.5", "0"),
                     ("0", "0"), ("0", "60"), ("1440", "1"), ("1441", "0"),
                     (String(repeating: "9", count: 100), "0"), ("1", "1e2")] {
            XCTAssertNil(UtilityTimerInput.duration(minutes: pair.0, seconds: pair.1), "Invalid input must not start a previously valid duration: \(pair)")
        }
    }
}
