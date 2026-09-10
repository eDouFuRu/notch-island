import XCTest
@testable import NotchInteractionCore

final class NotchInteractionTests: XCTestCase {
    private let screen = CGRect(x: -1_600, y: 100, width: 1_600, height: 1_000)

    func testCameraStopInvalidatesQueuedSetupAndQueuedStart() {
        var intent = CameraSessionIntent()
        let oldSetup = intent.requestStart()
        XCTAssertTrue(intent.accepts(oldSetup))
        intent.requestStop()
        XCTAssertFalse(intent.desiredRunning)
        XCTAssertFalse(intent.accepts(oldSetup), "A late setup completion cannot restart a hidden mirror")
        // Both setup and start-running phases use this same generation gate.
        XCTAssertFalse(intent.accepts(oldSetup))
    }

    func testNewCameraRequestCannotBeStartedByAnOlderCompletion() {
        var intent = CameraSessionIntent()
        let first = intent.requestStart()
        intent.requestStop()
        let second = intent.requestStart()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(intent.accepts(first))
        XCTAssertTrue(intent.accepts(second))
        intent.requestStop()
        intent.requestStop()
        XCTAssertFalse(intent.accepts(second))
        XCTAssertFalse(intent.desiredRunning)
    }

    func testPhysicalTriggerUsesExactAuxiliaryWidthsAndScreenOrigin() {
        let trigger = NotchHitRegion.triggerRect(screenFrame: screen, safeTop: 32,
                                                 leftAuxiliaryWidth: 705, rightAuxiliaryWidth: 710)
        XCTAssertEqual(trigger, CGRect(x: -895, y: 1_068, width: 185, height: 32))
        let region = makeRegion(trigger: trigger)
        XCTAssertTrue(region.containsTrigger(CGPoint(x: -800, y: 1_099)))
        XCTAssertFalse(region.containsTrigger(CGPoint(x: trigger.minX - 1, y: 1_090)))
        XCTAssertFalse(region.containsTrigger(CGPoint(x: trigger.maxX + 1, y: 1_090)))
        XCTAssertFalse(region.containsTrigger(CGPoint(x: -800, y: trigger.minY - 1)))
    }

    func testMissingNotchUsesCenteredFallbackCapsule() {
        let trigger = NotchHitRegion.triggerRect(screenFrame: screen, safeTop: 0,
                                                 leftAuxiliaryWidth: nil, rightAuxiliaryWidth: nil)
        XCTAssertEqual(trigger, CGRect(x: -860, y: 1_071, width: 120, height: 29))
        let malformed = NotchHitRegion.triggerRect(screenFrame: screen, safeTop: 32,
                                                   leftAuxiliaryWidth: 900, rightAuxiliaryWidth: 900)
        XCTAssertEqual(malformed, trigger)
    }

    func testVisibleContourExcludesConcaveTopAndRoundedBottomCorners() {
        let region = makeRegion()
        // Points are written in local top-down coordinates for easier visual reasoning.
        func visible(_ x: CGFloat, _ y: CGFloat) -> Bool {
            region.containsVisible(CGPoint(x: region.visibleFrame.minX + x,
                                           y: region.visibleFrame.maxY - y))
        }
        XCTAssertTrue(visible(200, 120))
        XCTAssertTrue(visible(20, 100))
        XCTAssertTrue(visible(15, 1))
        XCTAssertFalse(visible(2, 10))
        XCTAssertFalse(visible(18, 100))
        XCTAssertFalse(visible(20, 238))
        XCTAssertFalse(visible(400 - 20, 238))
        XCTAssertFalse(visible(200, 241))
    }

    func testExpandedHoverIncludesPhysicalCameraAndCurrentPresentationOnly() {
        var region = makeRegion()
        let lowerPoint = CGPoint(x: region.visibleFrame.midX, y: region.visibleFrame.minY + 1)
        XCTAssertTrue(region.containsExpandedHover(lowerPoint))
        region.visibleFrame.size.height = 80
        region.visibleFrame.origin.y = 1_100 - 80
        XCTAssertFalse(region.containsExpandedHover(lowerPoint))
        XCTAssertTrue(region.containsExpandedHover(CGPoint(x: -800, y: 1_090)))
    }

    func testClosedVisibleMediaWingCannotScheduleOpening() {
        var machine = NotchHoverStateMachine()
        XCTAssertNil(machine.update(enabled: true, expanded: false, inTrigger: false,
                                    inVisibleContent: true, holdsOpen: false, now: 0))
        XCTAssertNil(machine.pending)
        XCTAssertNil(machine.update(enabled: true, expanded: false, inTrigger: false,
                                    inVisibleContent: true, holdsOpen: false, now: 3))
    }

    func testOpeningRequiresContinuous150MillisecondsInsidePhysicalNotch() {
        var machine = NotchHoverStateMachine()
        XCTAssertNil(step(&machine, now: 0, trigger: true))
        XCTAssertEqual(machine.pending?.deadline, 0.150)
        XCTAssertNil(step(&machine, now: 0.080, trigger: true))
        XCTAssertEqual(machine.pending?.deadline, 0.150, "Movement inside the notch must not restart dwell")
        XCTAssertNil(step(&machine, now: 0.149, trigger: true))
        XCTAssertEqual(step(&machine, now: 0.150, trigger: true), .open)
    }

    func testLeavingTriggerCancelsPendingOpenAndReentryStartsNewDwell() {
        var machine = NotchHoverStateMachine()
        _ = step(&machine, now: 0, trigger: true)
        XCTAssertNil(step(&machine, now: 0.1, trigger: false, visible: true))
        XCTAssertNil(machine.pending)
        XCTAssertNil(step(&machine, now: 0.2, trigger: true))
        XCTAssertNil(step(&machine, now: 0.3, trigger: true))
        XCTAssertEqual(step(&machine, now: 0.351, trigger: true), .open)
    }

    func testContentTransitionAndPopupKeepOpenThenCloseAfter100Milliseconds() {
        var machine = NotchHoverStateMachine()
        XCTAssertNil(step(&machine, now: 0, expanded: true, trigger: true))
        XCTAssertNil(step(&machine, now: 0.1, expanded: true, visible: true))
        XCTAssertNil(machine.pending)
        XCTAssertNil(step(&machine, now: 0.2, expanded: true, holdsOpen: true))
        XCTAssertNil(machine.pending)
        XCTAssertNil(step(&machine, now: 0.3, expanded: true))
        XCTAssertNil(step(&machine, now: 0.399, expanded: true))
        XCTAssertEqual(step(&machine, now: 0.401, expanded: true), .close)
    }

    func testReentryCancelsPendingClose() {
        var machine = NotchHoverStateMachine()
        _ = step(&machine, now: 1, expanded: true)
        XCTAssertNil(step(&machine, now: 1.05, expanded: true, visible: true))
        XCTAssertNil(machine.pending)
        XCTAssertNil(step(&machine, now: 1.15, expanded: true, visible: true))
    }

    func testHiddenOrLockedCancelsDwellAndCannotReopenFromBackgroundEvent() {
        var machine = NotchHoverStateMachine()
        _ = step(&machine, now: 0, trigger: true)
        XCTAssertNil(step(&machine, now: 0.1, enabled: false, trigger: true))
        XCTAssertNil(machine.pending)
        XCTAssertNil(step(&machine, now: 20, enabled: false, trigger: true, visible: true))
        XCTAssertNil(machine.pending)
        XCTAssertNil(step(&machine, now: 21, trigger: true))
        XCTAssertEqual(step(&machine, now: 21.151, trigger: true), .open)
    }

    func testRepeatedCyclesAndMidDwellReversalsDoNotRetainStaleActions() {
        var machine = NotchHoverStateMachine()
        for cycle in 0..<20 {
            let start = Double(cycle)
            XCTAssertNil(step(&machine, now: start, trigger: true))
            XCTAssertEqual(step(&machine, now: start + 0.151, trigger: true), .open)
            XCTAssertNil(step(&machine, now: start + 0.2, expanded: true))
            XCTAssertNil(step(&machine, now: start + 0.25, expanded: true, visible: true))
            XCTAssertNil(step(&machine, now: start + 0.3, expanded: true))
            XCTAssertEqual(step(&machine, now: start + 0.401, expanded: true), .close)
            XCTAssertNil(machine.pending)
        }
    }

    func testClosingPresentationCanOnlyReverseAfterPhysicalNotchDwell() {
        var machine = NotchHoverStateMachine()
        for reversal in 0..<10 {
            let start = Double(reversal)
            _ = step(&machine, now: start, expanded: true)
            XCTAssertEqual(step(&machine, now: start + 0.101, expanded: true), .close)
            // The close target is already false while the rendered panel is still large.
            // Reentering that still-visible content must not reopen it.
            XCTAssertNil(step(&machine, now: start + 0.12, visible: true))
            XCTAssertNil(machine.pending)
            XCTAssertNil(step(&machine, now: start + 0.13, trigger: true, visible: true))
            XCTAssertNil(step(&machine, now: start + 0.279, trigger: true, visible: true))
            XCTAssertEqual(step(&machine, now: start + 0.281, trigger: true, visible: true), .open)
            XCTAssertNil(step(&machine, now: start + 0.3, expanded: true, trigger: true))
        }
    }

    private func makeRegion(trigger: CGRect? = nil) -> NotchHitRegion {
        NotchHitRegion(triggerRect: trigger ?? CGRect(x: -895, y: 1_068, width: 185, height: 32),
                       visibleFrame: CGRect(x: -1_000, y: 860, width: 400, height: 240),
                       topRadius: 19, bottomRadius: 24)
    }

    private func step(_ machine: inout NotchHoverStateMachine, now: TimeInterval,
                      enabled: Bool = true, expanded: Bool = false, trigger: Bool = false,
                      visible: Bool = false, holdsOpen: Bool = false) -> NotchHoverStateMachine.Action? {
        machine.update(enabled: enabled, expanded: expanded, inTrigger: trigger,
                       inVisibleContent: visible, holdsOpen: holdsOpen, now: now)
    }
}
