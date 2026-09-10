// Custom changes for 工位充电岛: shelf drag-out removal semantics.
import Foundation
import CoreGraphics

/// The held-key chord that marks "move this item out of the shelf" for a single drag.
///
/// Every option except `legacyCommandD` is modifier-only on purpose. A chord containing a
/// letter is also a menu shortcut in whatever app the pointer is over — dropping onto Finder
/// while holding ⌘D fires Finder's own "Duplicate" and derails the drop — so a letter-free
/// chord is the only kind that cannot be intercepted by the drop target.
public enum ShelfDragRemovalTrigger: String, CaseIterable, Sendable {
    /// No chord ever removes an item; only the standing "always remove" preference can.
    case off
    case optionCommand
    case controlCommand
    /// Kept for muscle memory. Carries the letter-key conflict described above.
    case legacyCommandD
}

/// The key state the trigger is matched against, kept free of AppKit so the decision stays
/// testable. The AppKit layer translates `NSEvent.modifierFlags` and the hardware D key into
/// this.
public struct ShelfDragModifierSnapshot: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ShelfDragModifierSnapshot(rawValue: 1 << 0)
    public static let option = ShelfDragModifierSnapshot(rawValue: 1 << 1)
    public static let control = ShelfDragModifierSnapshot(rawValue: 1 << 2)
    public static let letterD = ShelfDragModifierSnapshot(rawValue: 1 << 3)
}

/// Decides whether a shelf item leaves the shelf once it has been dropped elsewhere.
public enum ShelfDragRemovalPolicy {
    /// Subset match: the chord's own keys must be held, and unrelated keys are ignored.
    ///
    /// Requiring an exact match would let a stray Caps Lock or numeric-pad bit silently break
    /// the gesture, which trains people to give up and switch on the blunt "always remove"
    /// preference instead — a strictly more destructive setting than the one they abandoned.
    public static func triggerIsSatisfied(_ trigger: ShelfDragRemovalTrigger,
                                          by snapshot: ShelfDragModifierSnapshot) -> Bool {
        switch trigger {
        case .off:
            return false
        case .optionCommand:
            return snapshot.isSuperset(of: [.command, .option])
        case .controlCommand:
            return snapshot.isSuperset(of: [.command, .control])
        case .legacyCommandD:
            return snapshot.isSuperset(of: [.command, .letterD])
        }
    }

    public static func removesAfterDrop(alwaysRemove: Bool, triggerSatisfied: Bool) -> Bool {
        alwaysRemove || triggerSatisfied
    }

    /// A drop that landed back on one of our own windows is a change of mind, not a delivery.
    ///
    /// Checked at the source rather than left to each drop target: any in-app target that
    /// answers "yes" makes the drag look delivered, and one that forgets to refuse a
    /// self-drag — as the Quick Share tile did — silently destroys the item the user was
    /// only putting back.
    public static func dropLandedOnOwnUI(_ point: CGPoint, ownWindowFrames: [CGRect]) -> Bool {
        ownWindowFrames.contains { $0.contains(point) }
    }

    /// Only a drop another app actually accepted counts. A cancelled drag must leave the
    /// shelf untouched, or aborting would silently destroy the item.
    public static func shouldRemove(afterDropAccepted accepted: Bool,
                                    landedOnOwnUI: Bool,
                                    alwaysRemove: Bool,
                                    triggerSatisfied: Bool) -> Bool {
        accepted
            && !landedOnOwnUI
            && removesAfterDrop(alwaysRemove: alwaysRemove, triggerSatisfied: triggerSatisfied)
    }
}
