// Custom changes for 工位充电岛. Uses monotonic time supplied by the caller.
import Foundation

/// Dwell timer for switching tabs by hovering.
///
/// Separate from `NotchHoverStateMachine` on purpose: that one decides between two states
/// of a single thing and has to account for holds, whereas this picks any one of several
/// targets and leaves hit testing to the caller's `onHover`. Sharing a type would mean
/// carrying each other's concepts for no gain.
///
/// The caller supplies `now`, so behaviour is fully determined by its inputs and needs no
/// timer of its own to be tested.
struct TabHoverSwitchMachine<Tab: Equatable> {
    struct Pending: Equatable {
        let tab: Tab
        let deadline: TimeInterval
    }

    let delay: TimeInterval
    private(set) var pending: Pending?

    init(delay: TimeInterval = 0.12) {
        self.delay = delay
    }

    mutating func cancel() { pending = nil }

    /// - Parameter hovered: the tab under the pointer, or `nil` when it is over none.
    /// - Returns: the tab to switch to, once it has been dwelt on long enough.
    mutating func update(hovered: Tab?, current: Tab, now: TimeInterval) -> Tab? {
        // Hovering the open tab is not a request to switch, and leaving the bar entirely
        // abandons any switch in flight rather than completing it after the fact.
        guard let hovered, hovered != current else { cancel(); return nil }
        if pending?.tab != hovered {
            pending = Pending(tab: hovered, deadline: now + delay)
        }
        guard let pending, now >= pending.deadline else { return nil }
        self.pending = nil
        return hovered
    }
}
