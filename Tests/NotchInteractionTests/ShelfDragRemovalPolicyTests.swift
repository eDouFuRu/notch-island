// Custom changes for 工位充电岛: shelf drag-out removal semantics.
import XCTest
@testable import NotchInteractionCore

final class ShelfDragRemovalPolicyTests: XCTestCase {

    // MARK: - Which chord counts

    func testOffTriggerNeverSatisfied() {
        // Even with every key down, "off" must stay off.
        let everything: ShelfDragModifierSnapshot = [.command, .option, .control, .letterD]
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.off, by: everything))
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.off, by: []))
    }

    func testOptionCommandRequiresBothKeys() {
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.optionCommand, by: []))
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.optionCommand, by: [.command]))
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.optionCommand, by: [.option]))
        XCTAssertTrue(ShelfDragRemovalPolicy.triggerIsSatisfied(.optionCommand, by: [.command, .option]))
    }

    func testControlCommandRequiresBothKeys() {
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.controlCommand, by: [.command]))
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.controlCommand, by: [.control]))
        XCTAssertTrue(ShelfDragRemovalPolicy.triggerIsSatisfied(.controlCommand, by: [.command, .control]))
    }

    func testLegacyCommandDRequiresBothKeys() {
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.legacyCommandD, by: [.command]))
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.legacyCommandD, by: [.letterD]))
        XCTAssertTrue(ShelfDragRemovalPolicy.triggerIsSatisfied(.legacyCommandD, by: [.command, .letterD]))
    }

    func testExtraModifiersAreIgnored() {
        // Subset match: a stray Caps Lock or numeric-pad bit must not break the gesture.
        XCTAssertTrue(ShelfDragRemovalPolicy.triggerIsSatisfied(
            .optionCommand, by: [.command, .option, .control, .letterD]))
    }

    func testTriggersDoNotCrossSatisfy() {
        // Holding ⌥⌘ must not satisfy the ⌘D chord, and vice versa.
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.legacyCommandD, by: [.command, .option]))
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.optionCommand, by: [.command, .letterD]))
        XCTAssertFalse(ShelfDragRemovalPolicy.triggerIsSatisfied(.controlCommand, by: [.command, .option]))
    }

    // MARK: - Whether to remove

    func testPlainDragKeepsTheItem() {
        XCTAssertFalse(ShelfDragRemovalPolicy.removesAfterDrop(alwaysRemove: false,
                                                              triggerSatisfied: false))
    }

    func testTriggerSatisfiedRemoves() {
        XCTAssertTrue(ShelfDragRemovalPolicy.removesAfterDrop(alwaysRemove: false,
                                                             triggerSatisfied: true))
    }

    func testStandingPreferenceRemovesWithoutAnyChord() {
        XCTAssertTrue(ShelfDragRemovalPolicy.removesAfterDrop(alwaysRemove: true,
                                                             triggerSatisfied: false))
    }

    // MARK: - Acceptance gate (must never be destructive on a cancelled drag)

    func testCancelledDragKeepsTheItemEvenWithTriggerSatisfied() {
        XCTAssertFalse(ShelfDragRemovalPolicy.shouldRemove(afterDropAccepted: false,
                                                           landedOnOwnUI: false,
                                                           alwaysRemove: false,
                                                           triggerSatisfied: true))
    }

    func testCancelledDragKeepsTheItemEvenWithStandingPreference() {
        XCTAssertFalse(ShelfDragRemovalPolicy.shouldRemove(afterDropAccepted: false,
                                                           landedOnOwnUI: false,
                                                           alwaysRemove: true,
                                                           triggerSatisfied: true))
    }

    func testAcceptedDropWithTriggerRemoves() {
        XCTAssertTrue(ShelfDragRemovalPolicy.shouldRemove(afterDropAccepted: true,
                                                          landedOnOwnUI: false,
                                                          alwaysRemove: false,
                                                          triggerSatisfied: true))
    }

    func testAcceptedPlainDropKeepsTheItem() {
        XCTAssertFalse(ShelfDragRemovalPolicy.shouldRemove(afterDropAccepted: true,
                                                           landedOnOwnUI: false,
                                                           alwaysRemove: false,
                                                           triggerSatisfied: false))
    }

    // MARK: - Putting it back on our own UI is never a delivery

    func testDropLandedOnOwnUIDetectsPointInsideAWindow() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 50),
                      CGRect(x: 200, y: 200, width: 10, height: 10)]
        XCTAssertTrue(ShelfDragRemovalPolicy.dropLandedOnOwnUI(CGPoint(x: 50, y: 25),
                                                               ownWindowFrames: frames))
        XCTAssertTrue(ShelfDragRemovalPolicy.dropLandedOnOwnUI(CGPoint(x: 205, y: 205),
                                                               ownWindowFrames: frames))
        XCTAssertFalse(ShelfDragRemovalPolicy.dropLandedOnOwnUI(CGPoint(x: 150, y: 25),
                                                                ownWindowFrames: frames))
    }

    func testDropLandedOnOwnUIIsFalseWithNoWindows() {
        XCTAssertFalse(ShelfDragRemovalPolicy.dropLandedOnOwnUI(.zero, ownWindowFrames: []))
    }

    func testOwnUIDropKeepsTheItemEvenWhenTheTargetSaidYes() {
        // The Quick Share tile used to accept a self-drag, which made "put it back" delete
        // the item. Acceptance from our own UI must never count.
        XCTAssertFalse(ShelfDragRemovalPolicy.shouldRemove(afterDropAccepted: true,
                                                           landedOnOwnUI: true,
                                                           alwaysRemove: false,
                                                           triggerSatisfied: true))
    }

    func testOwnUIDropKeepsTheItemEvenWithStandingPreference() {
        XCTAssertFalse(ShelfDragRemovalPolicy.shouldRemove(afterDropAccepted: true,
                                                           landedOnOwnUI: true,
                                                           alwaysRemove: true,
                                                           triggerSatisfied: false))
    }

    // MARK: - End-to-end chord → removal, mirroring the real call site

    func testOffTriggerDoesNotRemoveEvenWithEveryKeyHeld() {
        let satisfied = ShelfDragRemovalPolicy.triggerIsSatisfied(
            .off, by: [.command, .option, .control, .letterD])
        XCTAssertFalse(ShelfDragRemovalPolicy.shouldRemove(afterDropAccepted: true,
                                                           landedOnOwnUI: false,
                                                           alwaysRemove: false,
                                                           triggerSatisfied: satisfied))
    }

    func testOptionCommandChordRemovesOnAcceptedDrop() {
        let satisfied = ShelfDragRemovalPolicy.triggerIsSatisfied(.optionCommand,
                                                                  by: [.command, .option])
        XCTAssertTrue(ShelfDragRemovalPolicy.shouldRemove(afterDropAccepted: true,
                                                          landedOnOwnUI: false,
                                                          alwaysRemove: false,
                                                          triggerSatisfied: satisfied))
    }
}
