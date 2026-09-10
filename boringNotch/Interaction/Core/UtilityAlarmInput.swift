import Foundation

/// Minute precision belongs to the alarm editor, not the second-precision timer
/// or persisted clock snapshot. These helpers never schedule notifications.
enum UtilityAlarmInput {
    static func minuteStart(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start
            ?? Date(timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate / 60) * 60)
    }

    static func firstFutureMinute(after now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        minuteStart(now, calendar: calendar).addingTimeInterval(60)
    }

    static func defaultDraft(at now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        minuteStart(now, calendar: calendar).addingTimeInterval(5 * 60)
    }

    /// Call only on explicit entry/reopening of the unset alarm editor. A ticker
    /// must never replace the draft while the person is still editing it.
    static func draftOnEntry(_ draft: Date, at now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        submission(draft, at: now, calendar: calendar) ?? defaultDraft(at: now, calendar: calendar)
    }

    /// A future hidden second within the current displayed minute is not a valid
    /// alarm. Recheck with the actual submit time to cover minute-boundary races.
    static func submission(_ draft: Date, at now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard draft.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let minute = minuteStart(draft, calendar: calendar)
        return minute > now ? minute : nil
    }
}
