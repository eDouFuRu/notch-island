// Custom changes for 工位充电岛. Uses monotonic time supplied by the caller.
import Foundation

struct NotchHoverStateMachine {
    enum Action: Equatable { case open, close }
    struct Pending: Equatable {
        let action: Action
        let deadline: TimeInterval
    }

    /// What is allowed to collapse an expanded island.
    enum CloseTrigger {
        /// The pointer leaving the island starts the dwell timer, as it always has.
        case hoverOut
        /// Only an explicit dismissal collapses the island. The pointer may wander off
        /// without consequence; the coordinator decides what counts as dismissal, so the
        /// state machine stays responsible for dwell timing alone.
        case externalClickOnly
    }

    let openDelay: TimeInterval
    let closeDelay: TimeInterval
    private(set) var pending: Pending?

    init(openDelay: TimeInterval = 0.150, closeDelay: TimeInterval = 0.100) {
        self.openDelay = openDelay
        self.closeDelay = closeDelay
    }

    mutating func cancel() { pending = nil }

    /// Repeated movement within one region does not restart its dwell timer.
    mutating func update(enabled: Bool, expanded: Bool, inTrigger: Bool,
                         inVisibleContent: Bool, holdsOpen: Bool, now: TimeInterval,
                         closeTrigger: CloseTrigger = .hoverOut) -> Action? {
        guard enabled else { cancel(); return nil }
        let desired: Action?
        if expanded {
            desired = (inTrigger || inVisibleContent || holdsOpen || closeTrigger == .externalClickOnly)
                ? nil : .close
        } else {
            // A visible media wing or a drag entering its region cannot open the island.
            desired = inTrigger ? .open : nil
        }
        guard let desired else { cancel(); return nil }
        if pending?.action != desired {
            pending = Pending(action: desired, deadline: now + (desired == .open ? openDelay : closeDelay))
        }
        if let pending, now >= pending.deadline {
            self.pending = nil
            return desired
        }
        return nil
    }
}
