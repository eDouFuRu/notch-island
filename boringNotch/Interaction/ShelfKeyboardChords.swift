import AppKit
import ApplicationServices

/// ⌘C / ⌘X / ⌘V for the shelf.
///
/// The island never becomes the key window on purpose — it must not take focus away from
/// whatever the user is typing in — so the responder chain never delivers a key event to it
/// and `.keyboardShortcut` cannot work. Seeing the chord at all requires an event monitor,
/// which macOS gates behind accessibility trust.
///
/// Two consequences, both deliberate:
///
/// * **Without that trust the shortcuts simply do not exist.** No prompt, no error message.
///   An item's right-click menu carries every one of these commands and needs no permission,
///   so for copy and cut this is pure enhancement. Paste is the one exception: the shelf's
///   empty-space menu was removed in 302, so with an empty shelf there is no item to
///   right-click and ⌘V is the only way in — that path does need the trust.
/// * **The monitor is installed only while the pointer is over the shelf**, and removed the
///   moment it leaves. A global key monitor sees keystrokes in every application, so leaving
///   one running would mean a ⌘C aimed at another app silently overwrote the clipboard with
///   the shelf's selection. Pointer presence is the same signal the island already uses to
///   decide whether it owns the input.
@MainActor
final class ShelfKeyboardChords {
    static let shared = ShelfKeyboardChords()

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    /// Whether the chords can work at all in this process right now.
    var isAvailable: Bool { accessibilityTrusted() }

    /// Injectable so the "no accessibility access" path can be exercised in a test without
    /// revoking the real grant, which would also take the HUD down with it.
    var accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }

    /// Exposed for verification: whether a monitor is currently listening.
    var isListening: Bool { globalMonitor != nil || localMonitor != nil }

    func setActive(_ pointerOverShelf: Bool) {
        if ShelfChordActivation.mustStopListening(pointerOverShelf: pointerOverShelf) {
            teardown()
            return
        }
        guard ShelfChordActivation.mayListen(pointerOverShelf: pointerOverShelf,
                                             accessibilityTrusted: accessibilityTrusted()),
              !isListening else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { _ = ShelfKeyboardChords.shared.handle(event) }
        }
        // The settings window can make this app active while the pointer is still on the
        // shelf; a global monitor sees nothing then, so the local one covers that case.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { ShelfKeyboardChords.shared.handle(event) }
            return handled ? nil : event
        }
    }

    private func teardown() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// Returns whether the chord was consumed. Anything not consumed is passed on untouched.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return false
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            let selected = selection()
            guard !selected.isEmpty else { return false }
            ShelfClipboardActions.copy(selected)
            return true
        case "x":
            let selected = selection()
            guard !selected.isEmpty else { return false }
            ShelfClipboardActions.cut(selected)
            return true
        case "v":
            return ShelfClipboardActions.paste() > 0
        default:
            return false
        }
    }

    private func selection() -> [ShelfItem] {
        ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
    }
}
