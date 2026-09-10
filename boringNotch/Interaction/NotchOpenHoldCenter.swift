import Combine
import Foundation

/// Why the island is being held open by something other than the pointer.
///
/// `pinnedPage` is deliberately separate from `popover`: a pinned page keeps the island
/// open when the pointer leaves, but must not swallow an explicit click outside, or the
/// island could never be dismissed. Callers distinguish the two through
/// `isHoldingAgainstPointerExit` and `isHoldingAgainstExplicitDismissal`.
enum NotchOpenHoldReason: Hashable {
    /// A SwiftUI popover is on screen. Its content is its own window and can extend past
    /// the island, so pointer-based collapse has to be suspended while it is up.
    case popover(UUID)
    /// A page that the user has to work inside of, such as the shelf.
    case pinnedPage
}

/// Keeps the island expanded for reasons the pointer cannot observe.
///
/// `NotchPointerCoordinator` already suppresses collapse for tracked `NSMenu`s, an
/// explicit user command, and the sharing/battery popovers. Those paths stay as they are;
/// this registry covers the cases added on top of them, so a SwiftUI popover — which is
/// not an `NSMenu` and therefore raises no tracking notification — can hold the island
/// open the same way a menu does.
@MainActor
final class NotchOpenHoldCenter {
    static let shared = NotchOpenHoldCenter()

    /// Popovers can be torn down by the system without their `isPresented` binding ever
    /// flipping back, which would wedge the island open with no way out. They therefore
    /// expire on their own. A pinned page is not covered: it is driven by the current page,
    /// which always reports a change, and expiring it would silently unpin a shelf the user
    /// is still working in.
    ///
    /// Long enough to outlast real use: the display-mode picker lists dozens of modes, and at
    /// 30s the island collapsed — taking the popover with it — while the list was still being
    /// read. This is a stuck-state backstop, not a usage timeout, so it should only ever fire
    /// when the binding genuinely never came back.
    static let maximumPopoverHoldDuration: TimeInterval = 180

    private(set) var reasons: Set<NotchOpenHoldReason> = []

    /// Fires *after* the set has been mutated, once per real change.
    ///
    /// Every island has its own coordinator, so this has to reach an arbitrary number of
    /// subscribers that come and go with their screens — a single stored callback would let
    /// whichever coordinator registered last silently take the notification away from the
    /// rest. A subject also unsubscribes with its `AnyCancellable`, so no coordinator has to
    /// remember to deregister.
    ///
    /// Not `@Published`: that publishes in `willSet`, so a subscriber reading
    /// `isHoldingAgainstPointerExit` from the callback would still see the previous value.
    let changes = PassthroughSubject<Void, Never>()

    private var releaseTasks: [NotchOpenHoldReason: Task<Void, Never>] = [:]
    private var expiryTasks: [NotchOpenHoldReason: Task<Void, Never>] = [:]

    private init() {}

    /// Holds that only survive while the pointer is away. A pinned page is included.
    var isHoldingAgainstPointerExit: Bool { !reasons.isEmpty }

    /// Holds that also survive a click outside the island. A pinned page is not included:
    /// clicking away is the user asking for the island to go, and that has to win.
    var isHoldingAgainstExplicitDismissal: Bool {
        reasons.contains { if case .popover = $0 { return true } else { return false } }
    }

    func begin(_ reason: NotchOpenHoldReason) {
        releaseTasks.removeValue(forKey: reason)?.cancel()
        expiryTasks.removeValue(forKey: reason)?.cancel()
        if case .popover = reason {
            expiryTasks[reason] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.maximumPopoverHoldDuration))
                guard !Task.isCancelled, let self, self.reasons.contains(reason) else { return }
                NSLog("NotchOpenHoldCenter: released a popover hold after \(Self.maximumPopoverHoldDuration)s with no explicit end")
                self.finish(reason)
            }
        }
        guard reasons.insert(reason).inserted else { return }
        changes.send()
    }

    func end(_ reason: NotchOpenHoldReason) {
        releaseTasks.removeValue(forKey: reason)?.cancel()
        finish(reason)
    }

    /// Releases after a delay so the pointer has time to travel from a dismissed popover
    /// back onto the island. Without it the popover's own frame — which the island's hit
    /// region does not cover — becomes an instant collapse the moment a choice is made.
    func endAfterGrace(_ reason: NotchOpenHoldReason, grace: TimeInterval) {
        guard reasons.contains(reason) else { return }
        releaseTasks.removeValue(forKey: reason)?.cancel()
        releaseTasks[reason] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled, let self else { return }
            self.releaseTasks.removeValue(forKey: reason)
            self.finish(reason)
        }
    }

    private func finish(_ reason: NotchOpenHoldReason) {
        expiryTasks.removeValue(forKey: reason)?.cancel()
        guard reasons.remove(reason) != nil else { return }
        changes.send()
    }
}
