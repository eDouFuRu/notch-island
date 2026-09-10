import XCTest
@testable import NotchInteractionCore

final class TabHoverSwitchMachineTests: XCTestCase {
    private enum Tab { case island, home, shelf, tools }

    func testHoveringTheOpenTabNeverSchedulesASwitch() {
        var machine = TabHoverSwitchMachine<Tab>()
        XCTAssertNil(machine.update(hovered: .home, current: .home, now: 0))
        XCTAssertNil(machine.pending)
        XCTAssertNil(machine.update(hovered: .home, current: .home, now: 10))
    }

    func testSwitchingRequiresTheDwellToElapse() {
        var machine = TabHoverSwitchMachine<Tab>(delay: 0.12)
        XCTAssertNil(machine.update(hovered: .tools, current: .home, now: 0))
        XCTAssertEqual(machine.pending?.deadline, 0.12)
        XCTAssertNil(machine.update(hovered: .tools, current: .home, now: 0.119))
        XCTAssertEqual(machine.update(hovered: .tools, current: .home, now: 0.12), .tools)
        XCTAssertNil(machine.pending, "Firing consumes the pending switch")
    }

    /// Moving within one button must not keep pushing its deadline away, or a slowly
    /// drifting pointer would never trigger a switch at all.
    func testMovementWithinTheSameTabDoesNotRestartTheDwell() {
        var machine = TabHoverSwitchMachine<Tab>(delay: 0.12)
        XCTAssertNil(machine.update(hovered: .tools, current: .home, now: 0))
        XCTAssertNil(machine.update(hovered: .tools, current: .home, now: 0.05))
        XCTAssertEqual(machine.pending?.deadline, 0.12)
        XCTAssertNil(machine.update(hovered: .tools, current: .home, now: 0.10))
        XCTAssertEqual(machine.update(hovered: .tools, current: .home, now: 0.12), .tools)
    }

    func testMovingToAnotherTabRestartsTheDwellForTheNewTarget() {
        var machine = TabHoverSwitchMachine<Tab>(delay: 0.12)
        XCTAssertNil(machine.update(hovered: .tools, current: .home, now: 0))
        XCTAssertNil(machine.update(hovered: .shelf, current: .home, now: 0.10))
        XCTAssertEqual(machine.pending?.tab, .shelf)
        XCTAssertEqual(machine.pending?.deadline, 0.22)
        XCTAssertNil(machine.update(hovered: .shelf, current: .home, now: 0.12),
                     "The first target's deadline must not carry over to the second")
        XCTAssertEqual(machine.update(hovered: .shelf, current: .home, now: 0.22), .shelf)
    }

    /// A pointer sweeping across the whole bar must land on nothing rather than firing
    /// each tab it passed over.
    func testSweepingAcrossEveryTabSwitchesToNone() {
        var machine = TabHoverSwitchMachine<Tab>(delay: 0.12)
        XCTAssertNil(machine.update(hovered: .island, current: .home, now: 0))
        XCTAssertNil(machine.update(hovered: .shelf, current: .home, now: 0.03))
        XCTAssertNil(machine.update(hovered: .tools, current: .home, now: 0.06))
        XCTAssertNil(machine.update(hovered: nil, current: .home, now: 0.09))
        XCTAssertNil(machine.pending)
    }

    func testLeavingTheBarCancelsAnAlreadyElapsedDwell() {
        var machine = TabHoverSwitchMachine<Tab>(delay: 0.12)
        XCTAssertNil(machine.update(hovered: .tools, current: .home, now: 0))
        XCTAssertNil(machine.update(hovered: nil, current: .home, now: 5),
                     "Leaving must win over the deadline having passed")
        XCTAssertNil(machine.pending)
    }

    /// The tab can change under the machine when the user clicks instead of hovering.
    func testTargetBecomingTheCurrentTabDropsThePendingSwitch() {
        var machine = TabHoverSwitchMachine<Tab>(delay: 0.12)
        XCTAssertNil(machine.update(hovered: .tools, current: .home, now: 0))
        XCTAssertNil(machine.update(hovered: .tools, current: .tools, now: 0.13))
        XCTAssertNil(machine.pending)
    }
}
