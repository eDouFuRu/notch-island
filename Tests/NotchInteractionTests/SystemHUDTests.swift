import XCTest
@testable import NotchInteractionCore

final class SystemHUDTests: XCTestCase {
    func testUnavailableStateRejectsDeliveryAndClearsPendingPresentation() {
        var state = SystemHUDState()
        state.show(kind: .volume, value: 0.5, now: 10)
        XCTAssertNil(state.activeKind)
        state.setApplicationAvailable(true)
        state.show(kind: .brightness, value: 0.75, now: 11)
        state.setApplicationAvailable(false)
        XCTAssertNil(state.activeKind)
        XCTAssertNil(state.expiration)
        state.show(kind: .volume, value: 1, now: 12)
        XCTAssertNil(state.activeKind, "Late hardware callbacks must not resurrect a hidden HUD")
    }

    func testLatestControlReplacesPreviousAndGetsItsOwnTwoSecondDeadline() {
        var state = SystemHUDState()
        state.setApplicationAvailable(true)
        state.show(kind: .volume, value: 0.2, now: 10)
        XCTAssertEqual(state.expiration, 12)
        state.show(kind: .brightness, value: 0.8, now: 11.5)
        state.expire(now: 12)
        XCTAssertEqual(state.activeKind, .brightness)
        XCTAssertEqual(state.value, 0.8)
        XCTAssertEqual(state.expiration, 13.5)
        state.expire(now: 13.5)
        XCTAssertNil(state.activeKind)
    }

    func testRepeatedSameKeyExtendsItsPresentation() {
        var state = SystemHUDState()
        state.setApplicationAvailable(true)
        for index in 0..<10 { state.show(kind: .volume, value: Double(index) / 16, now: Double(index) * 0.1) }
        state.expire(now: 2)
        XCTAssertEqual(state.value, 9.0 / 16)
        XCTAssertNotNil(state.activeKind)
        state.expire(now: 3)
        XCTAssertNil(state.activeKind)
    }

    func testConfirmedValuesClampAndErrorsRemainSeparateFromValues() {
        var state = SystemHUDState()
        state.setApplicationAvailable(true)
        for (input, expected) in [(-1.0, 0.0), (2.0, 1.0), (.infinity, 0.0), (.nan, 0.0)] {
            state.show(kind: .volume, value: input, now: 0)
            XCTAssertEqual(state.value, expected)
        }
        state.show(kind: .brightness, value: 0.4, error: "Unavailable", now: 0)
        XCTAssertEqual(state.error, "Unavailable")
        XCTAssertEqual(state.value, 0.4)
        state.show(kind: .brightness, value: 0.6, now: 1)
        XCTAssertNil(state.error)
    }

    func testEveryHUDKindCanExpireWithoutMutatingExternalTimerOrMusicState() {
        for kind in [SystemHUDKind.volume, .brightness, .backlight, .mic] {
            var state = SystemHUDState()
            state.setApplicationAvailable(true)
            state.show(kind: kind, value: 0.5, now: 100)
            XCTAssertEqual(state.activeKind, kind)
            state.expire(now: 102)
            XCTAssertNil(state.activeKind)
            XCTAssertTrue(state.applicationAvailable)
        }
    }

    func testClosedInlineMeasurementsFitBothWingsAndExactCameraGap() {
        for gap: CGFloat in [120, 185, 210, 400] {
            let layout = makeLayout(active: true, inline: true, expanded: false, gap: gap)
            XCTAssertEqual(layout.physicalGapWidth, gap)
            XCTAssertEqual(layout.size.width, 2 * layout.wingWidth + gap + 12)
            XCTAssertLessThanOrEqual(layout.size.width, 640)
            XCTAssertGreaterThanOrEqual(layout.wingWidth, 104)
            XCTAssertEqual(layout.size.height, 32)
            XCTAssertTrue(layout.showsInline)
            XCTAssertFalse(layout.showsRow)
        }
    }

    func testExpandedInlineUsesExistingHeaderAndPreservesBodyHeight() {
        let layout = makeLayout(active: true, inline: true, expanded: true)
        XCTAssertEqual(layout.size, CGSize(width: 640, height: 250))
        XCTAssertEqual(layout.size.width, 2 * layout.wingWidth + layout.physicalGapWidth + 62)
    }

    func testDefaultHUDAddsOneRowWithoutCompressingExpandedContent() {
        for header: CGFloat in [24, 32, 45, 60] {
            let baseHeight = max(250, header + 214)
            let layout = makeLayout(active: true, inline: false, expanded: true, header: header, baseHeight: baseHeight)
            XCTAssertEqual(layout.size.height - SystemHUDLayout.rowHeight, baseHeight)
            XCTAssertGreaterThanOrEqual(SystemHUDLayout.carrierHeight, layout.size.height + 20)
            XCTAssertTrue(layout.showsRow)
        }
    }

    /// The tools page is the tallest expanded view, and a HUD or brief row stacks on top
    /// of it. The carrier window cannot grow at runtime, so the page height plus that row
    /// plus the shadow margin has to fit inside it or the bottom card row is clipped away.
    func testTallestPagePlusHUDRowStillFitsInsideCarrierWindow() {
        for header: CGFloat in [24, 32, 45, 60] {
            let toolsHeight = SystemToolGridMetrics.expandedHeight(headerHeight: header)
            let layout = makeLayout(active: true, inline: false, expanded: true,
                                    header: header, baseHeight: toolsHeight)
            XCTAssertEqual(layout.size.height, toolsHeight + SystemHUDLayout.rowHeight)
            XCTAssertGreaterThanOrEqual(SystemHUDLayout.carrierHeight, layout.size.height + 20)
        }
    }

    /// The viewport must hold a whole number of cards, or the bottom row is sliced.
    func testGridViewportIsAWholeNumberOfRows() {
        let pitch = SystemToolGridMetrics.cardHeight + SystemToolGridMetrics.spacing
        XCTAssertEqual(SystemToolGridMetrics.gridViewportHeight,
                       CGFloat(SystemToolGridMetrics.visibleRows) * pitch - SystemToolGridMetrics.spacing)
        XCTAssertEqual(SystemToolGridMetrics.gridViewportHeight, 208)
    }

    func testFullscreenZeroHeightCanShowBothStylesAndReturnsToHiddenAfterExpiry() {
        for inline in [false, true] {
            let hidden = CGSize(width: 120, height: 0)
            let active = makeLayout(active: true, inline: inline, expanded: false, gap: 120, header: 0, baseSize: hidden)
            XCTAssertEqual(active.size.height, inline ? 24 : 52)
            let expired = makeLayout(active: false, inline: inline, expanded: false, gap: 120, header: 0, baseSize: hidden)
            XCTAssertEqual(expired.size, hidden)
        }
    }

    func testRestOrMediaBaseIsRestoredExactlyAfterEitherHUDStyle() {
        for base in [CGSize(width: 273, height: 32), CGSize(width: 485, height: 32), CGSize(width: 640, height: 72)] {
            for inline in [false, true] {
                let active = makeLayout(active: true, inline: inline, expanded: false, baseSize: base)
                XCTAssertEqual(active.size.height, inline ? 32 : 60)
                let inactive = makeLayout(active: false, inline: inline, expanded: false, baseSize: base)
                XCTAssertEqual(inactive.size, base)
            }
        }
    }

    func testHUDWidthDoesNotChangePhysicalHoverTrigger() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let trigger = NotchHitRegion.triggerRect(screenFrame: screen, safeTop: 32, leftAuxiliaryWidth: 707.5, rightAuxiliaryWidth: 707.5)
        for inline in [false, true] {
            let layout = makeLayout(active: true, inline: inline, expanded: false)
            let region = NotchHitRegion(triggerRect: trigger,
                visibleFrame: CGRect(x: screen.midX - layout.size.width / 2, y: screen.maxY - layout.size.height,
                                     width: layout.size.width, height: layout.size.height), topRadius: 6, bottomRadius: 14)
            XCTAssertTrue(region.containsTrigger(CGPoint(x: trigger.midX, y: trigger.midY)))
            XCTAssertFalse(region.containsTrigger(CGPoint(x: trigger.minX - 10, y: trigger.midY)))
            XCTAssertFalse(region.containsTrigger(CGPoint(x: trigger.midX, y: trigger.minY - 10)))
        }
    }

    private func makeLayout(active: Bool, inline: Bool, expanded: Bool, gap: CGFloat = 185,
                            header: CGFloat = 32, baseHeight: CGFloat = 250,
                            baseSize: CGSize = CGSize(width: 197, height: 32)) -> SystemHUDLayout {
        SystemHUDLayout(active: active, inline: inline, expanded: expanded, notchWidth: gap,
                        headerHeight: header, baseClosedSize: baseSize, baseExpandedHeight: baseHeight)
    }
}
