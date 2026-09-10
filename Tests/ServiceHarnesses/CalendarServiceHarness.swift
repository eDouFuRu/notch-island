// EventKit query doubles prevent permission prompts and reading or changing personal data.
enum EKEntityType { case event, reminder }
enum EKAuthorizationStatus { case fullAccess, authorized }
struct EKCalendar { let calendarIdentifier: String }
struct EKEvent { let id: String; let start: Date }
final class EKReminder {
    let id: String
    let calendarID: String
    var dueDateComponents: DateComponents?
    var isCompleted = false
    init(id: String, date: Date, calendarID: String = "R") {
        self.id = id
        self.calendarID = calendarID
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.calendar = Calendar.current
        components.timeZone = Calendar.current.timeZone
        dueDateComponents = components
    }
}
final class EKEventStore {
    static var permissionRequests = 0
    static var eventQueries = 0
    static var reminderCalendarIDs: [String] = []
    static var reminders: [EKReminder] = []
    static func authorizationStatus(for type: EKEntityType) -> EKAuthorizationStatus { .fullAccess }
    func requestFullAccessToEvents() async throws -> Bool { Self.permissionRequests += 1; return true }
    func requestFullAccessToReminders() async throws -> Bool { Self.permissionRequests += 1; return true }
    func requestAccess(to type: EKEntityType) async throws -> Bool { Self.permissionRequests += 1; return true }
    func calendars(for type: EKEntityType) -> [EKCalendar] {
        type == .event ? [EKCalendar(calendarIdentifier: "E")] : [EKCalendar(calendarIdentifier: "R"), EKCalendar(calendarIdentifier: "R2")]
    }
    func predicateForEvents(withStart start: Date, end: Date, calendars: [EKCalendar]) -> NSPredicate {
        Self.eventQueries += 1
        return NSPredicate(value: true)
    }
    func events(matching predicate: NSPredicate) -> [EKEvent] { [] }
    func predicateForReminders(in calendars: [EKCalendar]) -> NSPredicate {
        Self.reminderCalendarIDs = calendars.map(\.calendarIdentifier)
        return NSPredicate(value: true)
    }
    func fetchReminders(matching predicate: NSPredicate, completion: ([EKReminder]?) -> Void) {
        completion(Self.reminders.filter { Self.reminderCalendarIDs.contains($0.calendarID) })
    }
    func calendarItem(withIdentifier id: String) -> Any? { nil }
    func save(_ reminder: EKReminder, commit: Bool) throws {}
}
struct CalendarModel { init(from: EKCalendar) {} }
struct EventModel {
    let id: String
    let start: Date
    init?(from event: EKEvent) { id = event.id; start = event.start }
    init?(from reminder: EKReminder) { id = reminder.id; start = reminder.dueDateComponents!.date! }
}
@main struct Harness {
    @MainActor static func main() async {
        let service = CalendarService()
        let events = await service.events(from: .now, to: .now.addingTimeInterval(86400), calendars: [])
        precondition(events.isEmpty && EKEventStore.permissionRequests == 0)
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        EKEventStore.reminders = [
            EKReminder(id: "before", date: start.addingTimeInterval(-1)),
            EKReminder(id: "start", date: start),
            EKReminder(id: "last", date: end.addingTimeInterval(-1)),
            EKReminder(id: "next-day", date: end),
            EKReminder(id: "unselected", date: start, calendarID: "R2"),
        ]
        let selected = await service.events(from: start, to: end, calendars: ["R"])
        precondition(selected.map(\.id) == ["start", "last"], "day excludes next midnight and other calendars")
        precondition(EKEventStore.eventQueries == 0, "reminder-only selection must not query every event calendar")
        precondition(EKEventStore.reminderCalendarIDs == ["R"], "only selected reminder calendars reach the query")
        print("Actual CalendarService filtering checks: 4 passed (EventKit substituted)")
    }
}
