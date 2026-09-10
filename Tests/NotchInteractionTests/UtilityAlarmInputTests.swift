import XCTest
@testable import NotchInteractionCore

final class UtilityAlarmInputTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private let minute = Date(timeIntervalSince1970: 1_800_000_000)

    func testExpiredDraftIsRefreshedOnlyWhenEnteringTheEditor() {
        let draft = UtilityAlarmInput.defaultDraft(at: minute, calendar: calendar)
        let later = minute.addingTimeInterval(6 * 60 + 27)
        let refreshed = UtilityAlarmInput.draftOnEntry(draft, at: later, calendar: calendar)
        XCTAssertEqual(refreshed, minute.addingTimeInterval(11 * 60))
        XCTAssertGreaterThan(refreshed, later)
        XCTAssertNil(UtilityAlarmInput.submission(draft, at: later, calendar: calendar))
        XCTAssertEqual(draft, minute.addingTimeInterval(5 * 60)) // Validation never changes it.
    }

    func testFutureUserDraftSurvivesReopeningAndDropsOnlyHiddenSeconds() {
        let draft = minute.addingTimeInterval(2 * 3_600 + 43.75)
        XCTAssertEqual(UtilityAlarmInput.draftOnEntry(draft, at: minute, calendar: calendar),
                       minute.addingTimeInterval(2 * 3_600))
    }

    func testDisplayedCurrentMinuteIsRejectedEvenWhenHiddenSecondsAreFuture() {
        for currentOffset in [0.0, 10.0, 59.9] {
            XCTAssertNil(UtilityAlarmInput.submission(minute.addingTimeInterval(59.99),
                at: minute.addingTimeInterval(currentOffset), calendar: calendar))
        }
        XCTAssertNil(UtilityAlarmInput.submission(minute.addingTimeInterval(-1), at: minute, calendar: calendar))
    }

    func testSubmitRechecksCrossingTheSelectedMinuteBoundary() {
        let draft = minute.addingTimeInterval(89)
        XCTAssertEqual(UtilityAlarmInput.submission(draft, at: minute.addingTimeInterval(59.999), calendar: calendar),
                       minute.addingTimeInterval(60))
        XCTAssertNil(UtilityAlarmInput.submission(draft, at: minute.addingTimeInterval(60), calendar: calendar))
    }

    func testDefaultsAndEarliestMinuteHaveNoHiddenSecondsAcrossMidnight() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 23, minute: 58, second: 42))!
        let draft = UtilityAlarmInput.defaultDraft(at: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day, .hour, .minute, .second], from: draft),
                       DateComponents(day: 8, hour: 0, minute: 3, second: 0))
        let earliest = UtilityAlarmInput.firstFutureMinute(after: now, calendar: calendar)
        XCTAssertEqual(earliest.timeIntervalSince(now), 18)
        XCTAssertNotNil(UtilityAlarmInput.submission(earliest, at: now, calendar: calendar))
    }

    func testFutureDefaultsAndPrecisionSurviveDaylightSavingTransitions() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let formatter = ISO8601DateFormatter()
        for text in ["2026-03-08T09:58:45Z", "2026-11-01T08:58:45Z"] {
            let now = formatter.date(from: text)!
            let draft = UtilityAlarmInput.defaultDraft(at: now, calendar: local)
            XCTAssertEqual(draft.timeIntervalSince(now), 255)
            XCTAssertEqual(local.component(.second, from: draft), 0)
            XCTAssertEqual(UtilityAlarmInput.submission(draft, at: now, calendar: local), draft)
        }
    }

    func testInvalidDateCannotBeSubmitted() {
        XCTAssertNil(UtilityAlarmInput.submission(Date(timeIntervalSince1970: .infinity), at: minute, calendar: calendar))
        XCTAssertNil(UtilityAlarmInput.submission(minute, at: Date(timeIntervalSince1970: .nan), calendar: calendar))
    }
}
