import Foundation
import XCTest
@testable import NotchIslandCore

final class PotatoSessionStoreTests: XCTestCase {
    private final class Memory: RestSessionPersistence {
        var data: Data?
        var writes: [Data] = []
        func loadData() -> Data? { data }
        func saveData(_ data: Data) { self.data = data; writes.append(data) }
    }
    private final class Clock {
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func advance(_ seconds: Double) { date.addTimeInterval(seconds) }
    }
    private func make(_ memory: Memory, _ clock: Clock, legacy: Memory? = nil) -> PotatoSessionStore {
        PotatoSessionStore(storage: memory, legacyStorage: legacy, now: { clock.date })
    }

    func testRestCreditsEveryFullMinuteInAtomicSnapshotAndKeepsPartialOnCancel() throws {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        store.setRestDurationMinutes(3)
        store.start()
        clock.advance(59.75)
        store.reconcile()
        XCTAssertEqual(store.state.potatoCount, 0)
        let writes = memory.writes.count
        clock.advance(0.25)
        store.reconcile()
        XCTAssertEqual(store.state.potatoCount, 1)
        XCTAssertEqual(store.state.creditedRestCycles, 1)
        XCTAssertEqual(store.state.pendingHarvestCount, 1)
        XCTAssertEqual(memory.writes.count, writes + 1)
        let saved = try JSONDecoder().decode(PotatoSessionState.self, from: XCTUnwrap(memory.data))
        XCTAssertEqual(saved.potatoCount, 1)
        XCTAssertEqual(saved.creditedRestCycles, 1)
        XCTAssertEqual(saved.pendingHarvestCount, 1)
        clock.advance(79.5)
        store.cancel()
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertEqual(store.state.potatoCount, 2)
        XCTAssertEqual(store.state.pendingHarvestCount, 2)
        clock.advance(1_000)
        store.reconcile()
        XCTAssertEqual(store.state.potatoCount, 2)
    }

    func testPauseResumeKeepsFractionalElapsedAndDoesNotCountPausedTime() {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        store.setRestDurationMinutes(2)
        store.start()
        clock.advance(59.25)
        store.pause()
        XCTAssertEqual(store.elapsedSeconds, 59.25, accuracy: 0.001)
        XCTAssertEqual(store.remainingSeconds, 61)
        clock.advance(10_000)
        let restored = make(memory, clock)
        XCTAssertEqual(restored.state.phase, .paused)
        XCTAssertEqual(restored.elapsedSeconds, 59.25, accuracy: 0.001)
        XCTAssertEqual(restored.state.potatoCount, 0)
        restored.resume()
        clock.advance(0.75)
        restored.reconcile()
        XCTAssertEqual(restored.state.potatoCount, 1)
        clock.advance(60)
        restored.reconcile()
        XCTAssertEqual(restored.state.potatoCount, 2)
        XCTAssertEqual(restored.state.phase, .completed)
    }

    func testSleepAndRepeatedRelaunchRecoverMissingCyclesExactlyOnce() {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        store.setRestDurationMinutes(3)
        store.start()
        clock.advance(145)
        let restored = make(memory, clock)
        XCTAssertEqual(restored.state.potatoCount, 2)
        XCTAssertEqual(restored.remainingSeconds, 35)
        let writes = memory.writes.count
        for _ in 0..<20 { restored.reconcile() }
        XCTAssertEqual(memory.writes.count, writes)
        clock.advance(100_000)
        XCTAssertEqual(make(memory, clock).state.potatoCount, 3)
        XCTAssertEqual(make(memory, clock).state.potatoCount, 3)
        XCTAssertEqual(make(memory, clock).state.pendingHarvestCount, 3)
    }

    func testHarvestDeliveryIsSeparateFromInventoryAndOnlyConsumedOnce() {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        store.setRestDurationMinutes(2)
        store.start()
        clock.advance(120)
        store.reconcile()
        XCTAssertEqual(store.state.pendingHarvestCount, 2)
        XCTAssertEqual(make(memory, clock).consumeHarvest(), 2)
        XCTAssertEqual(store.state.potatoCount, 2)
        let restored = make(memory, clock)
        XCTAssertEqual(restored.consumeHarvest(), 0)
        XCTAssertEqual(restored.state.potatoCount, 2)
        XCTAssertEqual(restored.state.phase, .completed)
    }

    func testFocusTakesSixBitesAndChargesOneOnlyAtCompletion() {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        store.setRestDurationMinutes(2)
        store.start()
        clock.advance(120)
        store.reconcile()
        XCTAssertTrue(store.selectMode(.focus))
        XCTAssertEqual(store.durationMinutes, 25)
        store.start()
        for bite in 1...5 {
            clock.advance(250)
            store.reconcile()
            XCTAssertEqual(store.focusBitesTaken, bite)
            XCTAssertEqual(store.state.potatoCount, 2)
            XCTAssertFalse(store.state.pendingFocusReminder)
        }
        clock.advance(250)
        store.reconcile()
        XCTAssertEqual(store.focusBitesTaken, 6)
        XCTAssertEqual(store.state.phase, .completed)
        XCTAssertEqual(store.state.potatoCount, 1)
        XCTAssertTrue(store.state.pendingFocusReminder)
        for _ in 0..<20 { store.reconcile() }
        XCTAssertEqual(make(memory, clock).state.potatoCount, 1)
        XCTAssertTrue(store.consumeFocusReminder())
        XCTAssertFalse(store.consumeFocusReminder())
        XCTAssertFalse(make(memory, clock).state.pendingFocusReminder)
    }

    func testFocusWithNoInventoryCanCompleteAndReminderIsStillDelivered() {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        store.selectMode(.focus)
        store.setFocusDurationMinutes(1)
        store.start()
        clock.advance(60)
        let restored = make(memory, clock)
        XCTAssertEqual(restored.state.phase, .completed)
        XCTAssertEqual(restored.state.potatoCount, 0)
        XCTAssertTrue(restored.consumeFocusReminder())
        XCTAssertFalse(restored.consumeFocusReminder())
        XCTAssertEqual(restored.state.pendingHarvestCount, 0)
    }

    func testCancellingRunningOrPausedFocusDoesNotChargeOrNotify() {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        store.start()
        clock.advance(60)
        store.reconcile()
        store.selectMode(.focus)
        store.setFocusDurationMinutes(1)
        store.start()
        clock.advance(59)
        store.cancel()
        XCTAssertEqual(store.state.potatoCount, 1)
        XCTAssertFalse(store.state.pendingFocusReminder)
        store.start()
        clock.advance(30)
        store.pause()
        clock.advance(1_000)
        store.cancel()
        XCTAssertEqual(store.state.potatoCount, 1)
        XCTAssertFalse(store.state.pendingFocusReminder)
        XCTAssertEqual(store.focusBitesTaken, 0)
    }

    func testDurationsClampAndChangingDefaultsDoesNotChangeAnActiveSession() {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        XCTAssertEqual(store.state.restDurationMinutes, 1)
        XCTAssertEqual(store.state.focusDurationMinutes, 25)
        store.setRestDurationMinutes(-5)
        store.setFocusDurationMinutes(999)
        XCTAssertEqual(store.state.restDurationMinutes, 1)
        XCTAssertEqual(store.state.focusDurationMinutes, 120)
        store.start()
        let deadline = store.state.endDate
        clock.advance(10.25)
        store.setRestDurationMinutes(7)
        XCTAssertEqual(store.durationMinutes, 1)
        XCTAssertEqual(store.state.endDate, deadline)
        XCTAssertFalse(store.selectMode(.focus))
        store.start()
        XCTAssertEqual(store.state.endDate, deadline)
        store.pause()
        store.setDurationMinutes(9)
        XCTAssertEqual(store.durationMinutes, 1)
        XCTAssertEqual(store.elapsedSeconds, 10.25, accuracy: 0.001)
        XCTAssertFalse(store.selectMode(.focus))
        store.cancel()
        XCTAssertEqual(store.durationMinutes, 9)
        store.start()
        XCTAssertEqual(store.remainingSeconds, 540)
        XCTAssertEqual(make(memory, clock).state.restDurationMinutes, 9)
    }

    func testLateCancelHonorsCompletedFocusDeadline() {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        store.start()
        clock.advance(60)
        store.reconcile()
        store.selectMode(.focus)
        store.setFocusDurationMinutes(1)
        store.start()
        clock.advance(61)
        store.cancel()
        XCTAssertEqual(store.state.phase, .completed)
        XCTAssertEqual(store.state.potatoCount, 0)
        XCTAssertTrue(store.state.pendingFocusReminder)
    }

    func testCompletedDurationShowsNextConfigurationWithoutChangingFinishedProgress() {
        for mode in PotatoSessionMode.allCases {
            let memory = Memory(), clock = Clock(), store = make(memory, clock)
            store.selectMode(mode)
            store.setDurationMinutes(1)
            store.start()
            clock.advance(60)
            store.reconcile()
            store.setDurationMinutes(3)

            let restored = make(memory, clock)
            XCTAssertEqual(restored.state.phase, .completed)
            XCTAssertEqual(restored.durationMinutes, 3)
            XCTAssertEqual(restored.duration, 180)
            XCTAssertEqual(restored.state.sessionDuration, 60)
            XCTAssertEqual(restored.progress, 1)
            XCTAssertEqual(restored.focusBitesTaken, mode == .focus ? 6 : 0)
            restored.start()
            XCTAssertEqual(restored.remainingSeconds, 180)
            XCTAssertEqual(restored.progress, 0)
            XCTAssertEqual(restored.focusBitesTaken, 0)
        }
    }

    func testSelectingCompletedModeAgainReturnsToIdleAndRetainsUndeliveredHarvest() {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        store.start()
        clock.advance(60)
        store.selectMode(.focus)
        store.setFocusDurationMinutes(1)
        store.start()
        clock.advance(60)
        store.reconcile()
        XCTAssertTrue(store.state.pendingFocusReminder)

        XCTAssertTrue(store.selectMode(.focus))
        let restored = make(memory, clock)
        XCTAssertEqual(restored.state.phase, .idle)
        XCTAssertFalse(restored.state.pendingFocusReminder)
        XCTAssertEqual(restored.state.pendingHarvestCount, 1)
        XCTAssertEqual(restored.progress, 0)
        restored.start()
        XCTAssertEqual(restored.state.phase, .running)
        XCTAssertEqual(restored.remainingSeconds, 60)
    }

    func testStartingOrSwitchingModeAfterHiddenCompletionDiscardsOnlyOldFocusReminder() {
        for restartFocus in [true, false] {
            let memory = Memory(), clock = Clock(), store = make(memory, clock)
            store.start()
            clock.advance(60)
            store.selectMode(.focus)
            store.setFocusDurationMinutes(1)
            store.start()
            clock.advance(60)
            // Completion has not been reconciled or presented before the explicit action.
            if restartFocus { store.start() } else { store.selectMode(.rest) }

            let restored = make(memory, clock)
            XCTAssertFalse(restored.state.pendingFocusReminder)
            XCTAssertFalse(restored.consumeFocusReminder())
            XCTAssertEqual(restored.state.pendingHarvestCount, 1)
            XCTAssertEqual(restored.state.potatoCount, 0)
            XCTAssertEqual(restored.state.mode, restartFocus ? .focus : .rest)
            XCTAssertEqual(restored.state.phase, restartFocus ? .running : .idle)
        }
    }

    func testV1MigrationPreservesStockPendingAndExpiredRunningSessionWithoutWritingV1() {
        let memory = Memory(), legacy = Memory(), clock = Clock()
        let oldStore = RestSessionStore(storage: legacy, now: { clock.date })
        oldStore.start()
        clock.advance(60)
        oldStore.reconcile()
        oldStore.start()
        let oldData = legacy.data, oldWrites = legacy.writes.count
        clock.advance(61)
        let store = make(memory, clock, legacy: legacy)
        XCTAssertEqual(store.state.schemaVersion, 2)
        XCTAssertEqual(store.state.potatoCount, 2)
        XCTAssertEqual(store.state.pendingHarvestCount, 2)
        XCTAssertEqual(store.state.phase, .completed)
        XCTAssertEqual(legacy.data, oldData)
        XCTAssertEqual(legacy.writes.count, oldWrites)
        XCTAssertEqual(make(memory, clock, legacy: legacy).state.potatoCount, 2)
    }

    func testV1PausedSessionPreservesExactRemainingAndConsumedAnimation() {
        let memory = Memory(), legacy = Memory(), clock = Clock()
        let oldStore = RestSessionStore(storage: legacy, now: { clock.date })
        oldStore.start()
        clock.advance(60)
        oldStore.reconcile()
        oldStore.consumeGrowthAnimation()
        oldStore.start()
        clock.advance(17.25)
        oldStore.pause()
        let store = make(memory, clock, legacy: legacy)
        XCTAssertEqual(store.state.phase, .paused)
        XCTAssertEqual(store.state.pausedRemaining, 42.75, accuracy: 0.001)
        XCTAssertEqual(store.elapsedSeconds, 17.25, accuracy: 0.001)
        XCTAssertEqual(store.state.potatoCount, 1)
        XCTAssertEqual(store.state.pendingHarvestCount, 0)
        store.resume()
        clock.advance(42.75)
        store.reconcile()
        XCTAssertEqual(store.state.potatoCount, 2)
    }

    func testDamagedV2NeverReimportsLegacyInventory() {
        let memory = Memory(), legacy = Memory(), clock = Clock()
        let oldStore = RestSessionStore(storage: legacy, now: { clock.date })
        oldStore.start()
        clock.advance(60)
        oldStore.reconcile()
        memory.data = Data("damaged v2".utf8)
        let oldData = legacy.data
        let store = make(memory, clock, legacy: legacy)
        XCTAssertEqual(store.state.potatoCount, 0)
        XCTAssertEqual(store.state.phase, .idle)
        XCTAssertEqual(legacy.data, oldData)
        XCTAssertEqual(make(memory, clock, legacy: legacy).state.potatoCount, 0)
    }

    func testClockRollbackCannotDuplicateAlreadyCreditedCycle() {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        store.setRestDurationMinutes(2)
        store.start()
        clock.advance(61)
        store.reconcile()
        XCTAssertEqual(store.state.potatoCount, 1)
        clock.advance(-200)
        store.reconcile()
        XCTAssertEqual(store.remainingSeconds, 120)
        XCTAssertEqual(store.elapsedSeconds, 0)
        clock.advance(200)
        store.reconcile()
        XCTAssertEqual(store.state.potatoCount, 1)
        clock.advance(59)
        store.reconcile()
        XCTAssertEqual(store.state.potatoCount, 2)
    }

    func testDurationAndInventoryOverflowRecoverSafely() {
        let memory = Memory(), legacy = Memory(), clock = Clock()
        legacy.data = Data("""
        {"schemaVersion":1,"phase":"completed","pausedRemaining":0,"completedSessions":\(Int.max),"growthAnimationPending":true}
        """.utf8)
        let store = make(memory, clock, legacy: legacy)
        store.start()
        clock.advance(60)
        store.reconcile()
        XCTAssertEqual(store.state.potatoCount, Int.max)
        XCTAssertEqual(store.state.pendingHarvestCount, 2)
        XCTAssertEqual(store.state.creditedRestCycles, 1)
        XCTAssertEqual(make(memory, clock).state.potatoCount, Int.max)
    }

    func testHarvestWaitsForVisibleRestModeRatherThanFocusOrHiddenPage() {
        let memory = Memory(), clock = Clock(), store = make(memory, clock)
        store.start()
        clock.advance(60)
        store.reconcile()
        let hidden = RestPresentationState(notchOpen: true, hidden: true, pageMounted: true)
        let visible = RestPresentationState(notchOpen: true, pageMounted: true)
        XCTAssertEqual(store.consumeHarvest(when: hidden), 0)
        store.selectMode(.focus)
        XCTAssertEqual(store.consumeHarvest(when: visible), 0)
        XCTAssertEqual(store.state.pendingHarvestCount, 1)
        store.selectMode(.rest)
        XCTAssertEqual(store.consumeHarvest(when: visible), 1)
        XCTAssertEqual(store.consumeHarvest(when: visible), 0)
        XCTAssertEqual(store.state.potatoCount, 1)
    }

    func testDeliveryWindowKeepsV2MinuteSettlementForEveryTrayCapacity() throws {
        for initialStock in [0, 1, 12, 13] {
            let memory = Memory(), clock = Clock(), store = make(memory, clock)
            // Earn the initial inventory through the real store, without a
            // parallel fixture implementation of the v2 snapshot.
            if initialStock > 0 {
                store.setRestDurationMinutes(initialStock)
                store.start()
                clock.advance(Double(initialStock * 60))
                store.reconcile()
                XCTAssertEqual(store.consumeHarvest(), initialStock)
                XCTAssertTrue(store.selectMode(.rest))
            }
            store.setRestDurationMinutes(2)
            store.start()
            let started = clock.date
            for elapsed in [54.0, 55.99, 56, 57, 59.95, 59.999] {
                clock.date = started.addingTimeInterval(elapsed)
                store.reconcile()
                XCTAssertEqual(store.state.potatoCount, initialStock, "Visual delivery must not credit at \(elapsed)s")
                XCTAssertEqual(store.state.pendingHarvestCount, 0)
            }
            for minute in 1...2 {
                clock.date = started.addingTimeInterval(Double(minute * 60))
                for _ in 0..<20 { store.reconcile() }
                let saved = try JSONDecoder().decode(PotatoSessionState.self, from: XCTUnwrap(memory.data))
                XCTAssertEqual(saved.schemaVersion, 2)
                XCTAssertEqual(saved.potatoCount, initialStock + minute)
                XCTAssertEqual(saved.creditedRestCycles, minute)
                XCTAssertEqual(saved.pendingHarvestCount, minute)
                XCTAssertEqual(saved.phase, minute == 1 ? .running : .completed)
                XCTAssertEqual(make(memory, clock).state.potatoCount, initialStock + minute)
            }
        }
    }

    func testPauseAndCancelDuringLandedVisualWindowNeverAwardPartialMinute() {
        for elapsed in [56.0, 59.95] {
            let memory = Memory(), clock = Clock(), store = make(memory, clock)
            store.setRestDurationMinutes(2)
            store.start()
            clock.advance(elapsed)
            store.pause()
            clock.advance(600)
            let restored = make(memory, clock)
            XCTAssertEqual(restored.elapsedSeconds, elapsed, accuracy: 0.000_001)
            XCTAssertEqual(restored.state.potatoCount, 0)
            restored.cancel()
            XCTAssertEqual(restored.state.phase, .idle)
            XCTAssertEqual(restored.state.pendingHarvestCount, 0)
            XCTAssertEqual(make(memory, clock).state.potatoCount, 0)
        }
    }
}
