import XCTest
@testable import NotchInteractionCore

/// A global key monitor sees every application's keystrokes. The danger these pin down is not
/// a missing shortcut but the opposite: a monitor left listening while the user is working
/// elsewhere, turning their ⌘C into "overwrite the clipboard with the shelf's selection".
final class ShelfChordActivationTests: XCTestCase {
    func testListensOnlyWhileThePointerIsOnTheShelf() {
        XCTAssertTrue(ShelfChordActivation.mayListen(pointerOverShelf: true, accessibilityTrusted: true))
        XCTAssertFalse(ShelfChordActivation.mayListen(pointerOverShelf: false, accessibilityTrusted: true))
    }

    func testWithoutAccessibilityAccessNothingIsInstalled() {
        // The documented degradation: the shortcuts simply do not exist, with no prompt and no
        // error, and the right-click menu — which needs no permission — carries every command.
        XCTAssertFalse(ShelfChordActivation.mayListen(pointerOverShelf: true, accessibilityTrusted: false))
        XCTAssertFalse(ShelfChordActivation.mayListen(pointerOverShelf: false, accessibilityTrusted: false))
    }

    func testThePointerLeavingAlwaysTearsTheMonitorDown() {
        XCTAssertTrue(ShelfChordActivation.mustStopListening(pointerOverShelf: false))
        XCTAssertFalse(ShelfChordActivation.mustStopListening(pointerOverShelf: true))
    }

    func testLosingTrustDoesNotByItselfTearDownAMonitorTheUserIsStillUnder() {
        // Deliberately not the negation of `mayListen`: an already-installed monitor that has
        // lost trust is inert, not dangerous, and tearing it down on a trust check would make
        // teardown depend on a value that can change without the pointer moving.
        XCTAssertFalse(ShelfChordActivation.mustStopListening(pointerOverShelf: true))
        XCTAssertFalse(ShelfChordActivation.mayListen(pointerOverShelf: true, accessibilityTrusted: false))
    }
}
