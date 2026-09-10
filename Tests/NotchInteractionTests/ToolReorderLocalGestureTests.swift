import XCTest
@testable import NotchInteractionCore

final class ToolReorderLocalGestureTests: XCTestCase {
    func testOneTerminalMovementThenReleaseCanCommitOnce() {
        var gesture = ToolReorderLocalGesture()
        var state = ToolGridConfiguration(allIDs: ["a", "b", "c"], defaultVisible: ["a", "b", "c"])
        let payload = ToolGridDragPayload(toolID: "a", sourceID: "local")
        gesture.press()
        // A native/source event producer may deliver only the endpoint move.
        XCTAssertTrue(gesture.move(distance: 86))
        XCTAssertEqual(state.selectedIDs, ["a", "b", "c"])
        if gesture.finish(acceptedTargets: 1) {
            XCTAssertTrue(state.drop(payload, on: "b", sourceID: "local"))
        }
        XCTAssertEqual(state.selectedIDs, ["b", "a", "c"])
        XCTAssertFalse(gesture.finish(acceptedTargets: 1))
        XCTAssertEqual(state.selectedIDs, ["b", "a", "c"])
    }

    func testClickAndSubthresholdMovementDoNotReorder() {
        var gesture = ToolReorderLocalGesture()
        gesture.press()
        XCTAssertFalse(gesture.move(distance: 2.9))
        XCTAssertFalse(gesture.move(distance: 3))
        XCTAssertFalse(gesture.finish(acceptedTargets: 1))
        gesture.press()
        XCTAssertTrue(gesture.move(distance: 3.01))
        XCTAssertTrue(gesture.finish(acceptedTargets: 1))
    }

    func testCancellationRemainsTerminalThroughReentryAndMouseUp() {
        for _ in ["Escape", "window resigned", "outside window", "source removed"] {
            var gesture = ToolReorderLocalGesture()
            gesture.press()
            XCTAssertTrue(gesture.move(distance: 20))
            gesture.cancel()
            XCTAssertEqual(gesture.phase, .cancelled)
            XCTAssertFalse(gesture.move(distance: 50))
            XCTAssertFalse(gesture.finish(acceptedTargets: 1))
            gesture.press()
            XCTAssertTrue(gesture.move(distance: 50))
            XCTAssertTrue(gesture.finish(acceptedTargets: 1))
        }
    }

    func testReleaseUsesFreshTargetCountAndRejectsBlankOrAmbiguousTargets() {
        for targetsAtRelease in [0, 2, 14] {
            var gesture = ToolReorderLocalGesture()
            gesture.press()
            XCTAssertTrue(gesture.move(distance: 50))
            // A previously highlighted destination is deliberately not stored in
            // the gesture; only the fresh release-time hit result can authorize.
            XCTAssertFalse(gesture.finish(acceptedTargets: targetsAtRelease))
            XCTAssertFalse(gesture.finish(acceptedTargets: 1))
        }
    }

    func testUnstartedCancelledAndNonfiniteInputCannotCommit() {
        var gesture = ToolReorderLocalGesture()
        XCTAssertFalse(gesture.move(distance: 100))
        XCTAssertFalse(gesture.finish(acceptedTargets: 1))
        gesture.press()
        XCTAssertFalse(gesture.move(distance: .nan))
        XCTAssertFalse(gesture.move(distance: .infinity))
        XCTAssertFalse(gesture.finish(acceptedTargets: 1))
        gesture.press()
        gesture.cancel()
        XCTAssertFalse(gesture.move(distance: 100))
        XCTAssertFalse(gesture.finish(acceptedTargets: 1))
    }
}
