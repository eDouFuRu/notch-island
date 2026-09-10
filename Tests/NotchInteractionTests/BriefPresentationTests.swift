import XCTest
@testable import NotchInteractionCore

final class BriefPresentationTests: XCTestCase {
    private func availableState() -> BriefPresentationState {
        var state = BriefPresentationState()
        state.setApplicationAvailable(true)
        return state
    }

    func testUnavailableEventsCannotBecomeVisibleAfterResumption() {
        var state = BriefPresentationState()
        state.receiveHi(id: "hidden-notice", now: 10)
        state.receiveSongChange(id: "hidden-track", now: 10)
        XCTAssertEqual(state.selection(now: 10, hudActive: true, lyricAvailable: true), .none)
        XCTAssertNil(state.nextDeadline)
        state.setApplicationAvailable(true)
        state.receiveHi(id: "hidden-notice", now: 11)
        state.receiveSongChange(id: "hidden-track", now: 11)
        XCTAssertEqual(state.selection(now: 11, hudActive: false), .none)
        state.receiveHi(id: "new-notice", now: 12)
        XCTAssertEqual(state.selection(now: 12, hudActive: false), .hi)
    }

    func testPriorityAndDeadlinesRemainIndependentOfWhatIsCurrentlyVisible() {
        var state = availableState()
        state.receiveSongChange(id: "track-a", now: 100)
        state.receiveHi(id: "notice-a", now: 100)
        XCTAssertEqual(state.nextDeadline, 101.5)
        XCTAssertEqual(state.selection(now: 100, hudActive: true, lyricAvailable: true), .hud)
        XCTAssertEqual(state.selection(now: 101, hudActive: false, lyricAvailable: true), .hi)
        state.expire(now: 102)
        XCTAssertNil(state.songChange)
        XCTAssertEqual(state.nextDeadline, 105)
        state.expire(now: 105)
        XCTAssertEqual(state.selection(now: 105, hudActive: false, lyricAvailable: true), .lyric)
        XCTAssertNil(state.nextDeadline)
    }

    func testExpiredSongOrHiCannotReplayWhenAHigherPriorityHUDLeaves() {
        var state = availableState()
        state.receiveHi(id: "notice-a", now: 0)
        state.receiveSongChange(id: "track-a", now: 0)
        XCTAssertEqual(state.selection(now: 8, hudActive: true, lyricAvailable: true), .hud)
        // Even a late scheduler callback cannot expose stale cached peeks.
        XCTAssertEqual(state.selection(now: 8, hudActive: false, lyricAvailable: true), .lyric)
        state.expire(now: 8)
        state.receiveHi(id: "notice-a", now: 9)
        state.receiveSongChange(id: "track-a", now: 9)
        XCTAssertEqual(state.selection(now: 9, hudActive: false), .none)
    }

    func testLatestHiGetsItsOwnDeadlineAndRepeatedSourcePublicationDoesNotExtendIt() {
        var state = availableState()
        state.receiveHi(id: "notice-a", now: 0)
        state.receiveHi(id: "notice-a", now: 4)
        XCTAssertEqual(state.hi?.expiration, 5)
        state.receiveHi(id: "notice-b", now: 4)
        state.expire(now: 5)
        XCTAssertEqual(state.hi?.id, "notice-b")
        XCTAssertEqual(state.nextDeadline, 9)
        state.expire(now: 9)
        XCTAssertNil(state.hi)
    }

    func testHoveredHiPreservesRemainingTimeWithoutHoldingAnObscuredSong() {
        var state = availableState()
        state.receiveHi(id: "notice-a", now: 0)
        state.receiveSongChange(id: "track-a", now: 1)
        state.setHovered(true, now: 2)
        XCTAssertEqual(state.nextDeadline, 2.5)
        state.expire(now: 90)
        XCTAssertNil(state.songChange)
        XCTAssertEqual(state.selection(now: 90, hudActive: false), .hi)
        XCTAssertNil(state.nextDeadline)
        state.setHovered(false, now: 100)
        XCTAssertEqual(state.nextDeadline, 103)
        XCTAssertEqual(state.selection(now: 102.99, hudActive: false), .hi)
        state.expire(now: 103)
        XCTAssertEqual(state.selection(now: 103, hudActive: false), .none)
    }

    func testLateHoverDoesNotResurrectAnExpiredNotice() {
        var state = availableState()
        state.receiveHi(id: "notice-a", now: 0)
        state.setHovered(true, now: 5)
        XCTAssertFalse(state.isHovered)
        XCTAssertNil(state.hi)
        XCTAssertNil(state.nextDeadline)
    }

    func testNewNoticeWhileHoveredGetsFiveSecondsAfterLeaving() {
        var state = availableState()
        state.receiveHi(id: "notice-a", now: 0)
        state.setHovered(true, now: 2)
        state.receiveHi(id: "notice-b", now: 20)
        state.setHovered(true, now: 30)
        state.receiveHi(id: "notice-b", now: 90)
        state.setHovered(false, now: 100)
        XCTAssertEqual(state.hi?.id, "notice-b")
        XCTAssertEqual(state.hi?.expiration, 105)
    }

    func testHidingClearsHoveredContentAndConsumesLateCallbacks() {
        var state = availableState()
        state.receiveHi(id: "notice-a", now: 0)
        state.receiveSongChange(id: "track-a", now: 0)
        state.setHovered(true, now: 1)
        state.setApplicationAvailable(false)
        state.receiveHi(id: "late-notice", now: 2)
        state.receiveSongChange(id: "late-track", now: 2)
        XCTAssertNil(state.hi)
        XCTAssertNil(state.songChange)
        XCTAssertFalse(state.isHovered)
        XCTAssertNil(state.nextDeadline)
        state.setApplicationAvailable(true)
        state.receiveHi(id: "late-notice", now: 3)
        XCTAssertEqual(state.selection(now: 3, hudActive: false), .none)
    }

    func testDismissalDoesNotAffectOtherSourcesAndDoesNotReplayTheSameNotice() {
        var state = availableState()
        state.receiveHi(id: "notice-a", now: 0)
        state.receiveSongChange(id: "track-a", now: 0)
        state.dismissHi()
        state.receiveHi(id: "notice-a", now: 0.5)
        XCTAssertEqual(state.selection(now: 0.5, hudActive: false), .songChange)
        state.dismissSongChange()
        XCTAssertEqual(state.selection(now: 0.5, hudActive: false, lyricAvailable: true), .lyric)
    }

    func testDisabledSourcesFallThroughAndHUDAlwaysRemainsExclusive() {
        var state = availableState()
        state.receiveHi(id: "notice-a", now: 0)
        state.receiveSongChange(id: "track-a", now: 0)
        XCTAssertEqual(state.selection(now: 0, hudActive: false, hiEnabled: false, lyricAvailable: true), .songChange)
        XCTAssertEqual(state.selection(now: 0, hudActive: false, hiEnabled: false, songEnabled: false, lyricAvailable: true), .lyric)
        XCTAssertEqual(state.selection(now: 0, hudActive: false, hiEnabled: false, songEnabled: false), .none)
        XCTAssertFalse(state.selection(now: 0, hudActive: true).usesBriefRow)
    }

    func testInvalidTimeOrDurationCannotCreateAnUnboundedPeek() {
        for (now, duration) in [(Double.nan, 5.0), (.infinity, 5), (0, .nan),
                                (0, .infinity), (0, 0), (0, -1), (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)] {
            var state = availableState()
            state.receiveHi(id: "notice-a", now: now, duration: duration)
            state.receiveSongChange(id: "track-a", now: now, duration: duration)
            XCTAssertNil(state.nextDeadline)
            XCTAssertNil(state.hi)
            XCTAssertNil(state.songChange)
        }
    }

    func testReturningToATrackAfterADifferentTrackIsANewPeek() {
        var state = availableState()
        state.receiveSongChange(id: "track-a", now: 0)
        state.receiveSongChange(id: "track-b", now: 2)
        state.receiveSongChange(id: "track-a", now: 4)
        XCTAssertEqual(state.songChange?.id, "track-a")
        XCTAssertEqual(state.nextDeadline, 5.5)
    }

    func testClosedBriefAddsCompactRowWithoutWideningTheExistingNotch() {
        for base in [CGSize(width: 197, height: 32), CGSize(width: 485, height: 32)] {
            let layout = BriefPresentationLayout(active: true, standardHUD: false, expanded: false,
                                                 baseClosedSize: base, headerHeight: 32)
            XCTAssertEqual(layout.addedHeight, 28)
            XCTAssertEqual(layout.size.height, base.height + 28)
            XCTAssertEqual(layout.size.width, base.width)
            XCTAssertEqual(layout.rowTopInset, base.height)
        }
    }

    func testExpandedBriefPreservesTheRegularPageAndStandardHUDCannotStackWithIt() {
        for baseHeight: CGFloat in [250, 274] {
            let brief = BriefPresentationLayout(active: true, standardHUD: false, expanded: true,
                baseClosedSize: CGSize(width: 197, height: 32), baseExpandedHeight: baseHeight, headerHeight: 32)
            XCTAssertEqual(brief.size, CGSize(width: 640, height: baseHeight + 28))
            XCTAssertEqual(brief.rowTopInset, 32)
            let suppressed = BriefPresentationLayout(active: true, standardHUD: true, expanded: true,
                baseClosedSize: CGSize(width: 197, height: 32), baseExpandedHeight: baseHeight, headerHeight: 32)
            let hud = SystemHUDLayout(active: true, inline: false, expanded: true, notchWidth: 185,
                headerHeight: 32, baseClosedSize: CGSize(width: 197, height: 32), baseExpandedHeight: suppressed.size.height)
            XCTAssertFalse(suppressed.showsBrief)
            XCTAssertEqual(hud.size.height, brief.size.height, "HUD replaces the lyric row without changing the expanded shell height")
        }
    }

    func testBriefExpiryRestoresTheExactClosedBaseAndConfigurableWidthIsBounded() {
        let base = CGSize(width: 273, height: 32)
        let inactive = BriefPresentationLayout(active: false, standardHUD: false, expanded: false,
            baseClosedSize: base, headerHeight: 32)
        XCTAssertEqual(inactive.size, base)
        let bounded = BriefPresentationLayout(active: true, standardHUD: false, expanded: false,
            baseClosedSize: base, headerHeight: 32, minimumBriefWidth: 800, maximumWidth: 640)
        XCTAssertEqual(bounded.size.width, 640)
    }

    func testNoticeWidensTheClosedShellWithoutTouchingTheExpandedOrInactiveOne() {
        let base = CGSize(width: 197, height: 32)
        let minimum = BriefPresentationLayout.noticeMinimumWidth
        XCTAssertGreaterThan(minimum, base.width, "a notice needs more than the physical notch")
        let notice = BriefPresentationLayout(active: true, standardHUD: false, expanded: false,
            baseClosedSize: base, headerHeight: 32, minimumBriefWidth: minimum)
        XCTAssertEqual(notice.size.width, minimum)
        XCTAssertEqual(notice.size.height, base.height + BriefPresentationLayout.rowHeight)
        // A wider closed shell must never shrink below what the other closed sources already use.
        let wide = BriefPresentationLayout(active: true, standardHUD: false, expanded: false,
            baseClosedSize: CGSize(width: 520, height: 32), headerHeight: 32, minimumBriefWidth: minimum)
        XCTAssertEqual(wide.size.width, 520)
        // The HUD replaces the row, so it must not inherit the notice width.
        let hudReplaced = BriefPresentationLayout(active: true, standardHUD: true, expanded: false,
            baseClosedSize: base, headerHeight: 32, minimumBriefWidth: 0)
        XCTAssertEqual(hudReplaced.size, base)
        let expanded = BriefPresentationLayout(active: true, standardHUD: false, expanded: true,
            baseClosedSize: base, baseExpandedHeight: 250, headerHeight: 32, minimumBriefWidth: minimum)
        XCTAssertEqual(expanded.size.width, 640)
    }

    func testBriefHitRegionUsesTheActualScreenRectAndExcludesHeaderAndBody() {
        for origin in [CGPoint(x: 100, y: 700), CGPoint(x: -1_700, y: -400)] {
            let shell = CGRect(origin: origin, size: CGSize(width: 640, height: 290))
            let row = BriefInteractionRegion.rowRect(visibleRect: shell, rowTopInset: 32)
            XCTAssertEqual(row, CGRect(x: shell.minX, y: shell.maxY - 60, width: 640, height: 28))
            XCTAssertTrue(BriefInteractionRegion.contains(CGPoint(x: row.midX, y: row.midY), visibleRect: shell, rowTopInset: 32))
            XCTAssertFalse(BriefInteractionRegion.contains(CGPoint(x: row.midX, y: row.maxY + 1), visibleRect: shell, rowTopInset: 32))
            XCTAssertFalse(BriefInteractionRegion.contains(CGPoint(x: row.midX, y: row.minY - 1), visibleRect: shell, rowTopInset: 32))
            XCTAssertFalse(BriefInteractionRegion.contains(CGPoint(x: row.minX - 1, y: row.midY), visibleRect: shell, rowTopInset: 32))
        }
    }

    func testHitRegionClipsToTheShellAndRejectsInvalidGeometry() {
        let shell = CGRect(x: 0, y: 0, width: 360, height: 50)
        XCTAssertEqual(BriefInteractionRegion.rowRect(visibleRect: shell, rowTopInset: 32),
                       CGRect(x: 0, y: 0, width: 360, height: 18))
        for rect in [CGRect.null, .infinite, .zero] {
            XCTAssertFalse(BriefInteractionRegion.contains(.zero, visibleRect: rect, rowTopInset: 32))
        }
        XCTAssertFalse(BriefInteractionRegion.contains(CGPoint(x: Double.nan, y: 10), visibleRect: shell, rowTopInset: 32))
        XCTAssertTrue(BriefInteractionRegion.rowRect(visibleRect: shell, rowTopInset: -1).isNull)
        XCTAssertTrue(BriefInteractionRegion.rowRect(visibleRect: shell, rowTopInset: 32, height: 0).isNull)
    }
    func testLongLineHoldsBeginningThenRevealsTailWithoutLooping() {
        XCTAssertEqual(BriefMarqueeProgress.offset(textWidth: 300, viewportWidth: 180, elapsed: 1.9), 0)
        XCTAssertEqual(BriefMarqueeProgress.offset(textWidth: 300, viewportWidth: 180, elapsed: 4), 44)
        XCTAssertEqual(BriefMarqueeProgress.offset(textWidth: 300, viewportWidth: 180, elapsed: 30), 120)
        XCTAssertEqual(BriefMarqueeProgress.offset(textWidth: 100, viewportWidth: 180, elapsed: 30), 0)
        XCTAssertEqual(BriefMarqueeProgress.offset(textWidth: 300, viewportWidth: 180, elapsed: .nan), 0)
    }

}
