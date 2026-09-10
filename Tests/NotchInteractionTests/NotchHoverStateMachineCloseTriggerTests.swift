import XCTest
@testable import NotchInteractionCore

/// `externalClickOnly` exists so the island can stay open while the pointer is elsewhere.
/// The collapse itself is the coordinator's job, so what has to hold here is that the
/// machine never schedules or emits one on its own.
final class NotchHoverStateMachineCloseTriggerTests: XCTestCase {
    private func step(_ machine: inout NotchHoverStateMachine, now: TimeInterval,
                      trigger: Bool = false, visible: Bool = false, holdsOpen: Bool = false,
                      expanded: Bool = true,
                      closeTrigger: NotchHoverStateMachine.CloseTrigger) -> NotchHoverStateMachine.Action? {
        machine.update(enabled: true, expanded: expanded, inTrigger: trigger,
                       inVisibleContent: visible, holdsOpen: holdsOpen, now: now,
                       closeTrigger: closeTrigger)
    }

    func testExternalClickOnlyNeverSchedulesOrEmitsAutomaticClose() {
        var machine = NotchHoverStateMachine()
        for now in stride(from: 0.0, through: 5.0, by: 0.25) {
            XCTAssertNil(step(&machine, now: now, closeTrigger: .externalClickOnly),
                         "The pointer being away must not collapse the island in this mode")
            XCTAssertNil(machine.pending, "No close may even be scheduled")
        }
    }

    func testHoverOutStillClosesSoTheModeIsWhatMakesTheDifference() {
        var machine = NotchHoverStateMachine()
        XCTAssertNil(step(&machine, now: 0, closeTrigger: .hoverOut))
        XCTAssertEqual(machine.pending?.action, .close)
        XCTAssertEqual(step(&machine, now: 0.100, closeTrigger: .hoverOut), .close)
    }

    /// Only collapse is suppressed. If opening broke too, the island could never be shown
    /// by hovering in this mode.
    func testExternalClickOnlyLeavesOpeningUntouched() {
        var machine = NotchHoverStateMachine()
        XCTAssertNil(step(&machine, now: 0, trigger: true, expanded: false,
                          closeTrigger: .externalClickOnly))
        XCTAssertEqual(machine.pending?.action, .open)
        XCTAssertEqual(step(&machine, now: 0.150, trigger: true, expanded: false,
                            closeTrigger: .externalClickOnly), .open)
    }

    /// Switching back mid-dwell must not leave a stale pending close behind that fires the
    /// moment the mode changes.
    func testSwitchingBackToHoverOutRestartsRatherThanResumesADwell() {
        var machine = NotchHoverStateMachine()
        XCTAssertNil(step(&machine, now: 0, closeTrigger: .hoverOut))
        XCTAssertNil(step(&machine, now: 0.050, closeTrigger: .externalClickOnly))
        XCTAssertNil(machine.pending, "Entering the mode clears the pending close")
        XCTAssertNil(step(&machine, now: 0.060, closeTrigger: .hoverOut))
        XCTAssertEqual(machine.pending?.deadline, 0.160, "Dwell restarts from the switch, not from 0")
    }

    /// The added parameter defaults so the existing call sites keep their old behaviour.
    /// If the default ever flipped, the island would silently stop collapsing.
    func testOmittingTheParameterKeepsHoverOutBehaviour() {
        var machine = NotchHoverStateMachine()
        XCTAssertNil(machine.update(enabled: true, expanded: true, inTrigger: false,
                                    inVisibleContent: false, holdsOpen: false, now: 0))
        XCTAssertEqual(machine.update(enabled: true, expanded: true, inTrigger: false,
                                      inVisibleContent: false, holdsOpen: false, now: 0.100),
                       .close)
    }

    /// A hold and the mode suppress collapse independently; neither should mask a bug in
    /// the other.
    func testHoldStillSuppressesCloseInHoverOutMode() {
        var machine = NotchHoverStateMachine()
        XCTAssertNil(step(&machine, now: 0, holdsOpen: true, closeTrigger: .hoverOut))
        XCTAssertNil(machine.pending)
        XCTAssertNil(step(&machine, now: 5, holdsOpen: true, closeTrigger: .hoverOut))
    }
}
