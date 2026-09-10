import XCTest
@testable import NotchInteractionCore

final class HiAXCardTrackerTests: XCTestCase {
    private func card(_ id: String = "card", _ fingerprint: String = "content", payload: Bool = true) -> HiAXCardContent {
        HiAXCardContent(cardID: id, fingerprint: fingerprint, hasPayload: payload)
    }

    func testBaselineDoesNotDeliverOnEnableOrLaterUnchangedScans() {
        var tracker = HiAXCardTracker(sessionID: "test")
        tracker.beginBaseline([card()], now: 1)
        for time in [1.1, 10, 1000] { XCTAssertEqual(tracker.observe(card(), now: time), .ignored) }
    }

    func testIncompleteSnapshotCannotForgetVisibleBaseline() {
        var tracker = HiAXCardTracker()
        tracker.beginBaseline([card()], now: 1)
        tracker.reconcileVisibleCards([], snapshotComplete: false)
        XCTAssertEqual(tracker.trackedCount, 1)
        XCTAssertEqual(tracker.observe(card(), now: 2), .ignored)
    }

    func testConfirmedAbsencePrunesBaselineAndAllowsReusedCardID() {
        var tracker = HiAXCardTracker(sessionID: "test")
        tracker.beginBaseline([card()], now: 1)
        tracker.reconcileVisibleCards([], snapshotComplete: true)
        XCTAssertEqual(tracker.trackedCount, 0)
        XCTAssertEqual(tracker.observe(card(), now: 3), .new(eventID: "test-1"))
    }

    func testInitialTextHydrationUpdatesSameEventAndNotCount() {
        var tracker = HiAXCardTracker(sessionID: "test")
        XCTAssertEqual(tracker.observe(card("card", "empty", payload: false), now: 1), .new(eventID: "test-1"))
        XCTAssertEqual(tracker.observe(card("card", "title", payload: false), now: 1.1), .update(eventID: "test-1"))
        XCTAssertEqual(tracker.observe(card("card", "body"), now: 1.5), .update(eventID: "test-1"))
        XCTAssertEqual(tracker.observe(card("card", "body"), now: 3), .ignored)
    }

    func testSlowFirstBodyHydrationDoesNotCreateAnotherEvent() {
        var tracker = HiAXCardTracker(sessionID: "test")
        tracker.observe(card("card", "empty", payload: false), now: 1)
        XCTAssertEqual(tracker.observe(card("card", "body"), now: 5), .update(eventID: "test-1"))
    }

    func testStableNonemptyBodyChangeCreatesUniqueEventOnReusedCard() {
        var tracker = HiAXCardTracker(sessionID: "test")
        XCTAssertEqual(tracker.observe(card("card", "one"), now: 1), .new(eventID: "test-1"))
        XCTAssertEqual(tracker.observe(card("card", "two"), now: 1.8), .new(eventID: "test-2"))
        XCTAssertEqual(tracker.observe(card("card", "two-filled"), now: 1.9), .update(eventID: "test-2"))
    }

    func testBaselineCanBecomeNewEventOnlyAfterStableBodyChanges() {
        var tracker = HiAXCardTracker(sessionID: "test")
        tracker.beginBaseline([card("card", "old")], now: 1)
        XCTAssertEqual(tracker.observe(card("card", "new"), now: 2), .new(eventID: "test-1"))
    }

    func testUnknownFieldsAndBaselineHydrationStaySuppressed() {
        var tracker = HiAXCardTracker(sessionID: "test")
        tracker.beginBaseline([card("card", "empty", payload: false)], now: 1)
        XCTAssertEqual(tracker.observe(card("card", "body"), now: 10), .ignored)
        XCTAssertEqual(tracker.observe(card("card", "title-only", payload: false), now: 20), .ignored)
    }

    func testTrackerIsBoundedAndResetDoesNotReuseEventIdentity() {
        var tracker = HiAXCardTracker(sessionID: "test")
        for index in 0..<100 { tracker.observe(card("card-\(index)"), now: Double(index)) }
        XCTAssertEqual(tracker.trackedCount, HiAXCardTracker.capacity)
        tracker.clear()
        XCTAssertEqual(tracker.trackedCount, 0)
        XCTAssertEqual(tracker.observe(card(), now: 101), .new(eventID: "test-101"))
    }

    func testHydrationAndReuseIntegrateWithBurstCountWithoutExtendingDuplicate() {
        var tracker = HiAXCardTracker(sessionID: "test")
        var state = HiNotificationState()
        state.setEnabled(true); state.setApplicationAvailable(true); state.setDetailed(true)
        for (time, content, payload) in [(1.0, "title", false), (1.2, "body", true), (1.3, "body", true), (2.2, "next", true)] {
            switch tracker.observe(card("same", content, payload: payload), now: time) {
            case let .new(eventID):
                state.receive(HiNotificationCandidate(identity: eventID, sender: "Test", body: content), now: time)
            case let .update(eventID):
                state.refreshCurrentContent(HiNotificationCandidate(identity: eventID, sender: "Test", body: content))
            case .ignored: break
            }
        }
        XCTAssertEqual(state.current?.count, 2)
        XCTAssertEqual(state.current?.id, "test-2")
        XCTAssertEqual(state.current?.receivedAt, 2.2)
        XCTAssertEqual(state.current?.body, "next")
    }
}
