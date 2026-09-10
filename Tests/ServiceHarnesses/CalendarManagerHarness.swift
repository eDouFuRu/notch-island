// Dependency doubles and assertions only; production source is assembled at test time.
struct CalendarModel { let id: String; let isReminder: Bool }
struct EventModel { let id: String }
enum Defaults {
    protocol Serializable {}
    enum Key { case calendarSelectionState }
    static var selection = CalendarSelectionState.all
    static subscript(_ key: Key) -> CalendarSelectionState { get { selection } set { selection = newValue } }
}
@MainActor final class CalendarService {
    static let entries = [CalendarModel(id: "A", isReminder: false), CalendarModel(id: "B", isReminder: true)]
    static var queries: [[String]] = []
    static var permissionRequests = 0
    static var delayedDay: Date?
    static var delayedQueryStarted = false
    func calendars() async -> [CalendarModel] { Self.entries }
    func requestAccess(to type: EKEntityType) async throws -> Bool { Self.permissionRequests += 1; return false }
    func events(from start: Date, to end: Date, calendars: [String]) async -> [EventModel] {
        Self.queries.append(calendars)
        if Self.delayedDay == start {
            Self.delayedQueryStarted = true
            try? await Task.sleep(for: .milliseconds(150))
        }
        return calendars.map { EventModel(id: "\(Int(start.timeIntervalSince1970)):\($0)") }
    }
    func setReminderCompleted(reminderID: String, completed: Bool) async {}
}
@main struct Harness {
    @MainActor static func main() async {
        var checks = 0
        @MainActor func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        let manager = CalendarManager.shared
        await Task.yield()
        await manager.reloadCalendarAndReminderLists()
        expect(CalendarService.permissionRequests == 0, "calendar initialization never requests access")
        await manager.checkCalendarAuthorization()
        await manager.checkReminderAuthorization()
        expect(CalendarService.permissionRequests == 0, "passive settings checks never request access")
        let a = CalendarService.entries[0], b = CalendarService.entries[1]
        await manager.setCalendarSelected(a, isSelected: false)
        expect(CalendarService.queries.last == ["B"], "deselect A limits query to B")
        let prior = CalendarService.queries.count
        await manager.setCalendarSelected(b, isSelected: false)
        expect(!manager.hasSelectedCalendars, "last deselection yields explicit empty selection")
        expect(manager.events.isEmpty, "last deselection clears events immediately")
        expect(CalendarService.queries.count == prior, "empty selection never queries all calendars")
        if case .selected(let ids) = Defaults.selection { expect(ids.isEmpty, "empty selection stays selected-empty") }
        else { preconditionFailure("empty selection incorrectly became all") }
        let data = try! JSONEncoder().encode(Defaults.selection)
        let restored = try! JSONDecoder().decode(CalendarSelectionState.self, from: data)
        if case .selected(let ids) = restored { expect(ids.isEmpty, "round trip retains explicit empty selection") }
        else { preconditionFailure("empty selection lost during encoding") }
        await manager.setCalendarSelected(a, isSelected: true)
        expect(CalendarService.queries.last == ["A"], "reselecting one calendar queries only that calendar")
        await manager.setCalendarSelected(b, isSelected: true)
        if case .all = Defaults.selection { expect(true, "reselecting every calendar can normalize to all") }
        else { preconditionFailure("all-calendar state mismatch") }
        let older = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 100000))
        let newer = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 300000))
        CalendarService.delayedDay = older
        let slow = Task { await manager.updateCurrentDate(older) }
        for _ in 0..<100 {
            if CalendarService.delayedQueryStarted { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        precondition(CalendarService.delayedQueryStarted, "slow-query injection did not start")
        await manager.updateCurrentDate(newer)
        await slow.value
        expect(manager.events.allSatisfy { $0.id.hasPrefix("\(Int(newer.timeIntervalSince1970)):") }, "late older query cannot replace new date events")
        print("Calendar selection/refresh checks: \(checks) passed")
    }
}
