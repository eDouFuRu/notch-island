import Foundation
import XCTest
@testable import NotchIslandCore

final class RestSessionStoreTests: XCTestCase {
    private final class MemoryPersistence: RestSessionPersistence {
        var data: Data?
        var writes = 0
        func loadData() -> Data? { data }
        func saveData(_ data: Data) { self.data = data; writes += 1 }
    }

    private final class Clock {
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
    }

    func testStartsOneMinuteAndCompletesAtDeadlineExactlyOnce() {
        let storage = MemoryPersistence()
        let clock = Clock()
        let store = RestSessionStore(storage: storage, now: { clock.date })
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertEqual(store.remainingSeconds, 60)
        XCTAssertFalse(store.state.hasTree)

        store.start()
        let deadline = store.state.endDate
        clock.advance(10)
        store.start()
        XCTAssertEqual(store.state.endDate, deadline, "A double click must not restart a running rest")
        clock.advance(49.2)
        store.reconcile()
        XCTAssertEqual(store.remainingSeconds, 1)
        XCTAssertEqual(store.state.phase, .running)
        clock.advance(0.8)
        store.reconcile()
        XCTAssertEqual(store.remainingSeconds, 0)
        XCTAssertEqual(store.state.phase, .completed)
        XCTAssertTrue(store.state.hasTree)
        XCTAssertEqual(store.state.completedSessions, 1)
        let writes = storage.writes
        for _ in 0..<30 { store.reconcile() }
        XCTAssertEqual(store.state.completedSessions, 1)
        XCTAssertEqual(storage.writes, writes, "Idle display ticks must not rewrite the snapshot")
    }

    func testPauseResumePreservesFractionalTimeAcrossLongPause() {
        let clock = Clock()
        let store = RestSessionStore(storage: MemoryPersistence(), now: { clock.date })
        store.start()
        clock.advance(17.25)
        store.pause()
        XCTAssertEqual(store.state.phase, .paused)
        XCTAssertEqual(store.state.pausedRemaining, 42.75, accuracy: 0.001)
        XCTAssertEqual(store.remainingSeconds, 43)
        XCTAssertNil(store.state.endDate)
        clock.advance(10_000)
        store.reconcile()
        store.start()
        XCTAssertEqual(store.state.phase, .paused)
        XCTAssertFalse(store.state.hasTree)
        store.resume()
        clock.advance(42.7)
        store.reconcile()
        XCTAssertEqual(store.state.phase, .running)
        XCTAssertEqual(store.remainingSeconds, 1)
        clock.advance(0.05)
        store.reconcile()
        XCTAssertEqual(store.state.phase, .completed)
    }

    func testCancelRunningAndPausedDoesNotAwardTree() {
        let clock = Clock()
        let store = RestSessionStore(storage: MemoryPersistence(), now: { clock.date })
        store.start()
        clock.advance(30)
        store.cancel()
        clock.advance(100)
        store.reconcile()
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertEqual(store.remainingSeconds, 60)
        XCTAssertFalse(store.state.hasTree)
        XCTAssertFalse(store.state.growthAnimationPending)
        store.start()
        clock.advance(10)
        store.pause()
        store.cancel()
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertEqual(store.state.completedSessions, 0)
    }

    func testLaunchAfterDeadlineCompletesAndKeepsOnePendingAnimation() {
        let storage = MemoryPersistence()
        let clock = Clock()
        let first = RestSessionStore(storage: storage, now: { clock.date })
        first.start()
        clock.advance(3_600)
        let recovered = RestSessionStore(storage: storage, now: { clock.date })
        XCTAssertEqual(recovered.state.phase, .completed)
        XCTAssertEqual(recovered.state.completedSessions, 1)
        XCTAssertTrue(recovered.state.growthAnimationPending)
        XCTAssertTrue(recovered.consumeGrowthAnimation())
        XCTAssertFalse(recovered.consumeGrowthAnimation())
        let reopened = RestSessionStore(storage: storage, now: { clock.date })
        XCTAssertEqual(reopened.state.completedSessions, 1)
        XCTAssertTrue(reopened.state.hasTree)
        XCTAssertFalse(reopened.consumeGrowthAnimation())
    }

    func testRunningAndPausedSessionsRestoreBeforeDeadline() {
        let storage = MemoryPersistence()
        let clock = Clock()
        let initial = RestSessionStore(storage: storage, now: { clock.date })
        initial.start()
        clock.advance(20)
        let running = RestSessionStore(storage: storage, now: { clock.date })
        XCTAssertEqual(running.state.phase, .running)
        XCTAssertEqual(running.remainingSeconds, 40)
        running.pause()
        clock.advance(86_400)
        let paused = RestSessionStore(storage: storage, now: { clock.date })
        XCTAssertEqual(paused.state.phase, .paused)
        XCTAssertEqual(paused.remainingSeconds, 40)
        XCTAssertEqual(paused.state.completedSessions, 0)
    }

    func testTreeSurvivesFutureCancellationAndAnotherCompletedRest() {
        let clock = Clock()
        let store = RestSessionStore(storage: MemoryPersistence(), now: { clock.date })
        store.start()
        clock.advance(60)
        store.reconcile()
        XCTAssertTrue(store.consumeGrowthAnimation())
        store.start()
        clock.advance(5)
        store.cancel()
        XCTAssertTrue(store.state.hasTree)
        XCTAssertEqual(store.state.completedSessions, 1)
        store.start()
        clock.advance(60)
        store.reconcile()
        XCTAssertEqual(store.state.completedSessions, 2)
        XCTAssertTrue(store.consumeGrowthAnimation())
        XCTAssertFalse(store.consumeGrowthAnimation())
    }

    func testWakeAndLateButtonPressRespectTheElapsedDeadline() {
        for operation in ["pause", "cancel"] {
            let clock = Clock()
            let store = RestSessionStore(storage: MemoryPersistence(), now: { clock.date })
            store.start()
            clock.advance(100)
            if operation == "pause" { store.pause() } else { store.cancel() }
            XCTAssertEqual(store.state.phase, .completed)
            XCTAssertEqual(store.state.completedSessions, 1)
        }
    }

    func testDamagedSnapshotsRecoverAndReplaceInvalidData() throws {
        let invalid: [Data] = [
            Data("not json".utf8),
            Data("{}".utf8),
            Data(#"{"phase":"paused","pausedRemaining":-1,"completedSessions":0,"growthAnimationPending":false,"schemaVersion":1}"#.utf8),
            Data(#"{"phase":"running","pausedRemaining":0,"completedSessions":0,"growthAnimationPending":false,"schemaVersion":1}"#.utf8),
            Data(#"{"phase":"idle","pausedRemaining":0,"completedSessions":0,"growthAnimationPending":true,"schemaVersion":1}"#.utf8),
            Data(#"{"phase":"idle","pausedRemaining":0,"completedSessions":0,"growthAnimationPending":false,"schemaVersion":99}"#.utf8)
        ]
        for data in invalid {
            let storage = MemoryPersistence()
            storage.data = data
            let store = RestSessionStore(storage: storage)
            XCTAssertEqual(store.state.phase, .idle)
            XCTAssertFalse(store.state.hasTree)
            XCTAssertEqual(store.remainingSeconds, 60)
            XCTAssertEqual(storage.writes, 1)
            let recovered = try JSONDecoder().decode(RestSessionState.self, from: XCTUnwrap(storage.data))
            XCTAssertEqual(recovered, store.state)
        }
    }

    func testClockMovingBackwardNeverShowsMoreThanConfiguredDuration() {
        let clock = Clock()
        let store = RestSessionStore(storage: MemoryPersistence(), now: { clock.date })
        store.start()
        clock.advance(-3_600)
        XCTAssertEqual(store.remainingSeconds, 60)
        store.pause()
        XCTAssertEqual(store.remainingSeconds, 60)
        XCTAssertEqual(store.state.phase, .paused)
    }

    func testInvalidDurationUsesSafeDefault() {
        for duration in [Double.nan, .infinity, -1, 0, 100_000] {
            let store = RestSessionStore(storage: MemoryPersistence(), duration: duration)
            XCTAssertEqual(store.duration, 60)
            XCTAssertEqual(store.remainingSeconds, 60)
        }
    }

    func testUserDefaultsPersistenceRoundTripsInIsolatedSuite() throws {
        let suiteName = "NotchIslandCoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = UserDefaultsRestSessionPersistence(defaults: defaults, key: "snapshot")
        let clock = Clock()
        let first = RestSessionStore(storage: storage, now: { clock.date })
        first.start()
        clock.advance(60)
        first.reconcile()
        let restored = RestSessionStore(storage: storage, now: { clock.date })
        XCTAssertEqual(restored.state, first.state)
        XCTAssertNotNil(defaults.data(forKey: "snapshot"))
    }
}
