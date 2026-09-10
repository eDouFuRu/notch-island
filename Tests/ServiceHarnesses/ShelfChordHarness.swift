// Fault injection against the real `ShelfKeyboardChords`, not a copy of its logic.
//
// The claim under test is a safety one: a global key monitor sees every application's
// keystrokes, so the shelf must never leave one installed when the pointer is elsewhere, and
// must install nothing at all without accessibility access. Proving that by actually revoking
// the grant would take the HUD down with it and leave the user re-granting by hand, so the
// trust probe is injected instead — the production install/teardown path is otherwise real.

import AppKit
import Foundation

struct ShelfItem {
    let id = UUID()
}

@MainActor
final class ShelfSelectionModel {
    static let shared = ShelfSelectionModel()
    var selected: [ShelfItem] = []
    func selectedItems(in _: [ShelfItem]) -> [ShelfItem] { selected }
}

@MainActor
final class ShelfStateViewModel {
    static let shared = ShelfStateViewModel()
    var items: [ShelfItem] = []
}

@MainActor
enum ShelfClipboardActions {
    static var pasteCount = 0
    static var copied: [ShelfItem] = []
    static var cutItems: [ShelfItem] = []
    static func paste() -> Int { pasteCount += 1; return 0 }
    static func copy(_ items: [ShelfItem]) { copied = items }
    static func cut(_ items: [ShelfItem]) { cutItems = items }
}

@main
enum ShelfChordHarness {
    static var checks = 0

    static func check(_ condition: Bool, _ label: String) {
        guard condition else {
            print("FAIL \(label)")
            exit(1)
        }
        checks += 1
        print("PASS \(label)")
    }

    @MainActor
    static func main() {
        let chords = ShelfKeyboardChords.shared

        chords.accessibilityTrusted = { false }
        chords.setActive(true)
        check(!chords.isListening,
              "without accessibility access nothing is installed even with the pointer on the shelf")
        check(!chords.isAvailable, "availability reports the injected trust state")

        chords.accessibilityTrusted = { true }
        chords.setActive(true)
        check(chords.isListening, "with access and the pointer present a monitor is installed")

        chords.setActive(true)
        check(chords.isListening, "repeated activation does not stack a second monitor")

        chords.setActive(false)
        check(!chords.isListening, "the pointer leaving tears the monitor down")

        // Trust can be revoked while the pointer is still on the shelf. The already-installed
        // monitor goes inert rather than dangerous, so teardown must not depend on trust.
        chords.setActive(true)
        chords.accessibilityTrusted = { false }
        chords.setActive(true)
        check(chords.isListening, "losing trust does not by itself tear down a live monitor")
        chords.setActive(false)
        check(!chords.isListening, "the pointer leaving still tears it down after trust was lost")

        chords.accessibilityTrusted = { false }
        chords.setActive(false)
        chords.setActive(true)
        check(!chords.isListening, "a fresh activation without access installs nothing")

        print("Shelf chord activation checks: \(checks) passed")
    }
}
