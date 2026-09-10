import XCTest
@testable import NotchInteractionCore

/// The floating controls are drawn from `centerOffsetX`/`topEdgeOffset` and hit tested from
/// `rect`. If those two ever disagree the button renders in a place the window refuses
/// clicks, which looks exactly like a dead button.
final class NotchAccessoryControlTests: XCTestCase {
    private let visible = CGRect(x: 500, y: 800, width: 640, height: 300)

    private func rects(_ frame: CGRect) -> [CGRect] {
        NotchAccessorySlot.allCases.map { NotchAccessoryControl.rect(visibleFrame: frame, slot: $0) }
    }

    private func region(withAccessory: Bool) -> NotchHitRegion {
        NotchHitRegion(triggerRect: CGRect(x: 800, y: 1070, width: 200, height: 30),
                       visibleFrame: visible, topRadius: 19, bottomRadius: 24,
                       accessoryRects: withAccessory ? rects(visible) : [])
    }

    /// The y offset handed to `.overlay(alignment: .top)` positions the button's top edge,
    /// while the x offset positions its centre. Build 288 shipped the x convention on the y
    /// axis and every control drew half a diameter below where it was clickable.
    func testDrawnEdgesMatchTheHitTestedEdges() {
        for slot in NotchAccessorySlot.allCases {
            let rect = NotchAccessoryControl.rect(visibleFrame: visible, slot: slot)
            let drawnCentreX = visible.midX + NotchAccessoryControl.centerOffsetX(visibleWidth: visible.width)
            XCTAssertEqual(rect.midX, drawnCentreX, accuracy: 0.001)

            let drawnTopFromIslandTop = NotchAccessoryControl.topEdgeOffset(
                visibleHeight: visible.height, slot: slot)
            XCTAssertEqual(visible.maxY - rect.maxY, drawnTopFromIslandTop, accuracy: 0.001)
        }
    }

    /// The user asked for a pair that reads as balanced, so each control owns the centre of
    /// its own half and the two are mirror images about the island's horizontal axis.
    func testThePairIsSymmetricAboutTheIslandsHorizontalAxis() {
        let top = NotchAccessoryControl.rect(visibleFrame: visible, slot: .collapse)
        let bottom = NotchAccessoryControl.rect(visibleFrame: visible, slot: .clearShelf)
        XCTAssertEqual(visible.maxY - top.midY, bottom.midY - visible.minY, accuracy: 0.001)
        XCTAssertEqual(top.midY + bottom.midY, 2 * visible.midY, accuracy: 0.001)
        XCTAssertEqual(top.size, bottom.size, "A mismatched pair does not read as balanced")
    }

    func testTheTwoControlsDoNotOverlap() {
        let all = rects(visible)
        XCTAssertFalse(all[0].intersects(all[1]))
    }

    func testControlsSitFullyOutsideTheIslandWithAGap() {
        for rect in rects(visible) {
            XCTAssertEqual(rect.minX - visible.maxX, NotchAccessoryControl.gap, accuracy: 0.001)
            XCTAssertFalse(rect.intersects(visible),
                           "A control overlapping the island is not floating outside it")
        }
    }

    func testWindowMarginLeavesRoomForTheWholeControl() {
        XCTAssertGreaterThanOrEqual(NotchAccessoryControl.requiredSideMargin,
                                    NotchAccessoryControl.gap + NotchAccessoryControl.diameter,
                                    "The carrier window would clip the control")
    }

    func testCentreOfEachControlIsHit() {
        for rect in rects(visible) {
            XCTAssertTrue(region(withAccessory: true).containsAccessory(CGPoint(x: rect.midX, y: rect.midY)))
        }
    }

    /// They float over open desktop, so their square corners must not swallow clicks meant
    /// for whatever is behind them.
    func testCornersOfTheSquareFrameAreNotHit() {
        for rect in rects(visible) {
            for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                XCTAssertFalse(region(withAccessory: true).containsAccessory(corner))
            }
        }
    }

    /// The gap between the two circles is desktop, not button.
    func testTheSpaceBetweenTheControlsIsNotHit() {
        let all = rects(visible)
        let midpoint = CGPoint(x: all[0].midX, y: (all[0].minY + all[1].maxY) / 2)
        XCTAssertFalse(region(withAccessory: true).containsAccessory(midpoint))
    }

    func testNothingIsHitWhileTheControlsAreHidden() {
        for rect in rects(visible) {
            XCTAssertFalse(region(withAccessory: false).containsAccessory(CGPoint(x: rect.midX, y: rect.midY)))
        }
    }

    /// Clicking a control is using the island, so it must not read as an outside click
    /// and dismiss the very thing it is attached to.
    func testControlsCountAsPartOfTheIslandForOutsideClicks() {
        for rect in rects(visible) {
            let point = CGPoint(x: rect.midX, y: rect.midY)
            XCTAssertTrue(region(withAccessory: true).containsExpandedHover(point))
            XCTAssertFalse(region(withAccessory: false).containsExpandedHover(point),
                           "With no control there, that point really is outside")
        }
    }

    /// Reaching for a control means leaving the painted shape; if that counted as
    /// leaving the island it would collapse before it could be pressed.
    func testHoveringAControlCountsAsInteractiveContent() {
        for rect in rects(visible) {
            XCTAssertTrue(region(withAccessory: true)
                .containsInteractiveContent(CGPoint(x: rect.midX, y: rect.midY)))
        }
    }

    /// Only the physical notch may open the island. The controls must never be able to.
    func testControlsAreNotPartOfTheOpenTrigger() {
        for rect in rects(visible) {
            XCTAssertFalse(region(withAccessory: true).containsTrigger(CGPoint(x: rect.midX, y: rect.midY)))
        }
    }

    /// The shelf's height is a runtime value that changes on every animation frame, so the
    /// anchors have to be read from it rather than from a compile-time constant.
    func testControlsTrackTheIslandAsItAnimates() {
        for size in [CGSize(width: 200, height: 120), CGSize(width: 400, height: 220),
                     CGSize(width: 640, height: 300)] {
            let frame = CGRect(origin: CGPoint(x: 500, y: 800), size: size)
            let all = rects(frame)
            for rect in all {
                XCTAssertEqual(rect.minX - frame.maxX, NotchAccessoryControl.gap, accuracy: 0.001)
            }
            XCTAssertEqual(all[0].midY + all[1].midY, 2 * frame.midY, accuracy: 0.001,
                           "The pair must stay symmetric at every frame of the expansion")
        }
    }
}
