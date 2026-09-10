// Custom changes for 工位充电岛: shelf drag-out removal chord.
import AppKit
import Defaults

/// Reads the live keyboard for the configured "drag this out of the shelf" chord.
///
/// Both the click path and the drag path have to agree on whether the chord is down: the chord
/// contains ⌘, which is also the multi-select modifier, so if the two paths sampled it
/// separately they could disagree and the gesture would select an item it is about to drag
/// away. Everything funnels through `snapshot(from:)` here so there is a single answer.
enum ShelfDragRemovalChord {
    static var configuredTrigger: ShelfDragRemovalTrigger {
        Defaults[.shelfDragRemovalTrigger].coreTrigger
    }

    /// `D` is an ordinary key, so it never appears in `modifierFlags`, and the shelf panel
    /// never becomes key so no `keyDown` arrives either. The hardware key state is the only
    /// source available.
    private static func isRemoveKeyDown() -> Bool {
        let kVK_ANSI_D: CGKeyCode = 0x02
        return CGEventSource.keyState(.combinedSessionState, key: kVK_ANSI_D)
    }

    private static func snapshot(from flags: NSEvent.ModifierFlags,
                                 probingLetterD: Bool) -> ShelfDragModifierSnapshot {
        var snapshot: ShelfDragModifierSnapshot = []
        if flags.contains(.command) { snapshot.insert(.command) }
        if flags.contains(.option) { snapshot.insert(.option) }
        if flags.contains(.control) { snapshot.insert(.control) }
        // Only the legacy chord needs the hardware probe, so skip it otherwise.
        if probingLetterD, isRemoveKeyDown() { snapshot.insert(.letterD) }
        return snapshot
    }

    /// Samples the keyboard as it is right now. The static `NSEvent.modifierFlags` works
    /// without a key window, which this panel never becomes, and can be read at any moment
    /// rather than only when an event happens to arrive — which is what lets a chord pressed
    /// mid-drag count.
    static func isHeldNow() -> Bool {
        isSatisfied(by: NSEvent.modifierFlags)
    }

    /// Matches against the flags carried by a specific event, so a click is judged by the keys
    /// held at the moment it was made rather than by whatever is down once it is processed.
    static func isSatisfied(by flags: NSEvent.ModifierFlags) -> Bool {
        let trigger = configuredTrigger
        guard trigger != .off else { return false }
        let snapshot = snapshot(from: flags, probingLetterD: trigger == .legacyCommandD)
        return ShelfDragRemovalPolicy.triggerIsSatisfied(trigger, by: snapshot)
    }
}
