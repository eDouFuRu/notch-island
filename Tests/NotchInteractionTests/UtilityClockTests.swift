import XCTest
@testable import NotchInteractionCore

final class UtilityClockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    func testStopwatchPauseResumeAndRestartPersistence() throws {
        var watch = UtilityStopwatch(); watch.start(at: start)
        watch.pause(at: start.addingTimeInterval(12.5))
        XCTAssertEqual(watch.elapsed(at: start.addingTimeInterval(100)), 12.5)
        watch.start(at: start.addingTimeInterval(100))
        watch = try JSONDecoder().decode(UtilityStopwatch.self, from: JSONEncoder().encode(watch))
        watch.lap(at: start.addingTimeInterval(110))
        XCTAssertEqual(watch.laps, [22.5])
        watch.reset(); XCTAssertEqual(watch.elapsed(at: start), 0)
    }
    func testCountdownPausesWithoutLosingRemainingDuration() {
        var timer = UtilityCountdown(); XCTAssertTrue(timer.start(seconds: 60, at: start))
        timer.pause(at: start.addingTimeInterval(20))
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(1_000)), 40)
        timer.resume(at: start.addingTimeInterval(1_000))
        XCTAssertFalse(timer.settle(at: start.addingTimeInterval(1_039)))
        XCTAssertTrue(timer.settle(at: start.addingTimeInterval(1_040)))
        XCTAssertFalse(timer.settle(at: start.addingTimeInterval(1_100)))
    }
    func testOfflineExpiryAndCancelCannotDeliverTwice() throws {
        var timer = UtilityCountdown(); _ = timer.start(seconds: 1, at: start)
        timer = try JSONDecoder().decode(UtilityCountdown.self, from: JSONEncoder().encode(timer))
        XCTAssertTrue(timer.settle(at: start.addingTimeInterval(3_600)))
        XCTAssertTrue(timer.completed); timer.cancel()
        XCTAssertFalse(timer.settle(at: start.addingTimeInterval(7_200)))
    }
    func testPauseAtExpiryCompletesInsteadOfCreatingZeroPausedTimer() {
        var timer = UtilityCountdown(); _ = timer.start(seconds: 2, at: start)
        timer.pause(at: start.addingTimeInterval(2))
        XCTAssertTrue(timer.completed); XCTAssertFalse(timer.isActive)
    }
    func testInvalidDurationsLeaveActiveCountdownUntouched() {
        var timer = UtilityCountdown(); _ = timer.start(seconds: 60, at: start)
        let original = timer
        for value in [Double.nan, .infinity, -1, 0, 86_401] {
            XCTAssertFalse(timer.start(seconds: value, at: start)); XCTAssertEqual(timer, original)
        }
    }
    func testAlarmAfterRestartSettlesOnceAndIndependently() throws {
        var state = UtilityClockSnapshot(); state.alarmDate = start.addingTimeInterval(10)
        state.stopwatch.start(at: start)
        state = try JSONDecoder().decode(UtilityClockSnapshot.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(state.settleAlarm(at: start.addingTimeInterval(1_000)))
        XCTAssertFalse(state.settleAlarm(at: start.addingTimeInterval(1_001)))
        XCTAssertEqual(state.stopwatch.elapsed(at: start.addingTimeInterval(1_000)), 1_000)
    }
}
