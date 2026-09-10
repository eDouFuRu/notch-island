// Custom changes for 工位充电岛: when the shelf's ⌘ chords may listen to the keyboard.
import Foundation

/// Decides whether the shelf's ⌘C/⌘X/⌘V monitors may be installed.
///
/// A global key monitor sees keystrokes in *every* application, so getting this wrong is not a
/// missing feature — it is a ⌘C aimed at some other app silently overwriting the clipboard
/// with the shelf's selection. Both conditions are therefore required, and the rule lives here
/// where it can be tested rather than inline next to the `NSEvent` calls, which cannot be.
public enum ShelfChordActivation {
    /// - Parameters:
    ///   - pointerOverShelf: The island never becomes the key window, so pointer presence is
    ///     the only honest signal that the user means the keystroke for the shelf.
    ///   - accessibilityTrusted: Without this, a global key monitor never fires. Installing one
    ///     anyway would not crash, but it would be a listener that can never do anything.
    public static func mayListen(pointerOverShelf: Bool, accessibilityTrusted: Bool) -> Bool {
        pointerOverShelf && accessibilityTrusted
    }

    /// Whether an already-installed monitor has to come down. Note this is *not* the negation
    /// of `mayListen`: trust can be revoked while the pointer is still on the shelf, and a
    /// monitor already installed then must not be torn down on that account — losing trust
    /// makes it inert, not dangerous. Only the pointer leaving makes it dangerous.
    public static func mustStopListening(pointerOverShelf: Bool) -> Bool {
        !pointerOverShelf
    }
}
