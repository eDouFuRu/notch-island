// Dependency doubles and assertions only; the production helper is inserted verbatim.
import SwiftUI
import Foundation
enum Defaults { enum Key { case autoScrollToNextEvent }; static var enabled = false; static subscript(_ key: Key) -> Bool { enabled } }
enum EventType { case event, reminder(completed: Bool) }
struct Event { let id: String; let isAllDay: Bool; let end: Date; var type: EventType = .event }
typealias EventModel = Event
struct EventFilter {
    // PRODUCTION_EVENT_FILTER
}
@MainActor enum Calls { static var ids: [String] = [] }
struct ScrollViewProxy { @MainActor func scrollTo(_ id: String, anchor: UnitPoint) { Calls.ids.append(id) } }
@MainActor struct EventScroller {
    var autoScrollToNextEvent: Bool { Defaults.enabled }
    var filteredEvents = [Event(id: "past", isAllDay: false, end: .distantPast), Event(id: "next", isAllDay: false, end: .distantFuture)]
    func run() { scrollToRelevantEvent(proxy: ScrollViewProxy()) }
    // PRODUCTION_SCROLL_HELPER

}
@main struct Harness {
    @MainActor static func main() async {
        let scroller = EventScroller()
        Defaults.enabled = false
        scroller.run(); try? await Task.sleep(for: .milliseconds(1))
        precondition(Calls.ids.isEmpty, "disabled auto-scroll must not scroll on appear/update")
        Defaults.enabled = true
        scroller.run(); try? await Task.sleep(for: .milliseconds(1))
        precondition(Calls.ids == ["next"], "enabled auto-scroll selects next event")
        Calls.ids = []
        scroller.run()
        Defaults.enabled = false
        try? await Task.sleep(for: .milliseconds(1))
        precondition(Calls.ids.isEmpty, "disabling before scheduled task executes cancels the scroll")
        let events = [
            Event(id: "timed", isAllDay: false, end: .distantFuture),
            Event(id: "all-day", isAllDay: true, end: .distantFuture),
            Event(id: "completed", isAllDay: false, end: .distantFuture, type: .reminder(completed: true)),
            Event(id: "all-day-reminder", isAllDay: true, end: .distantFuture, type: .reminder(completed: false)),
        ]
        precondition(EventFilter.filteredEvents(events: events, hideCompletedReminders: false, hideAllDayEvents: false).count == 4)
        precondition(EventFilter.filteredEvents(events: events, hideCompletedReminders: true, hideAllDayEvents: false).map(\.id) == ["timed", "all-day", "all-day-reminder"])
        precondition(EventFilter.filteredEvents(events: events, hideCompletedReminders: false, hideAllDayEvents: true).map(\.id) == ["timed", "completed"])
        precondition(EventFilter.filteredEvents(events: events, hideCompletedReminders: true, hideAllDayEvents: true).map(\.id) == ["timed"])
        print("Actual calendar UI helper checks: 7 passed (3 scrolling + 4 filtering)")
    }
}
