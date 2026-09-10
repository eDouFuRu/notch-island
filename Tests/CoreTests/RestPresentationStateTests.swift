import Foundation
import XCTest
@testable import NotchIslandCore

final class RestPresentationStateTests: XCTestCase {
    private final class MemoryPersistence: RestSessionPersistence {
        var data: Data?
        var writes = 0
        func loadData() -> Data? { data }
        func saveData(_ data: Data) { self.data = data; writes += 1 }
    }

    func testAllPresentationConditionsAreRequired() {
        for mask in 0..<32 {
            let presentation = RestPresentationState(
                notchOpen: mask & 1 != 0,
                isIslandPage: mask & 2 != 0,
                hidden: mask & 4 != 0,
                locked: mask & 8 != 0,
                pageMounted: mask & 16 != 0
            )
            XCTAssertEqual(presentation.canPresentGrowth, mask == 19, "Invalid delivery for flags \(mask)")
        }
    }

    func testBackgroundToolCompletionWaitsForVisibleIslandAndDeliversOnce() {
        let storage = MemoryPersistence()
        var instant = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = RestSessionStore(storage: storage, now: { instant })
        store.start()
        instant.addTimeInterval(60)
        store.reconcile()
        let writesAfterCompletion = storage.writes
        var presentation = RestPresentationState(notchOpen: true, isIslandPage: false, pageMounted: false)

        for _ in 0..<20 { XCTAssertFalse(store.consumeGrowthAnimation(when: presentation)) }
        XCTAssertTrue(store.state.growthAnimationPending)
        XCTAssertEqual(store.state.completedSessions, 1)
        XCTAssertEqual(storage.writes, writesAfterCompletion)

        presentation.isIslandPage = true
        XCTAssertFalse(store.consumeGrowthAnimation(when: presentation), "Routing alone must wait for the page to mount")
        presentation.pageMounted = true
        XCTAssertTrue(store.consumeGrowthAnimation(when: presentation))
        for _ in 0..<20 { XCTAssertFalse(store.consumeGrowthAnimation(when: presentation)) }
        XCTAssertFalse(store.state.growthAnimationPending)
        XCTAssertEqual(storage.writes, writesAfterCompletion + 1)
    }

    func testHiddenAndLockedCompletionSurvivesRelaunch() {
        let storage = MemoryPersistence()
        var instant = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let firstStore = RestSessionStore(storage: storage, now: { instant })
        firstStore.start()
        instant.addTimeInterval(90)
        firstStore.reconcile()
        var presentation = RestPresentationState(notchOpen: true, hidden: true, locked: true, pageMounted: true)
        XCTAssertFalse(firstStore.consumeGrowthAnimation(when: presentation))

        let restoredStore = RestSessionStore(storage: storage, now: { instant })
        XCTAssertEqual(restoredStore.state.completedSessions, 1)
        XCTAssertTrue(restoredStore.state.hasTree)
        XCTAssertTrue(restoredStore.state.growthAnimationPending)

        presentation.hidden = false
        XCTAssertFalse(restoredStore.consumeGrowthAnimation(when: presentation), "Showing a locked window cannot consume growth")
        presentation.locked = false
        XCTAssertTrue(restoredStore.consumeGrowthAnimation(when: presentation))
        XCTAssertFalse(RestSessionStore(storage: storage, now: { instant }).state.growthAnimationPending)
    }

    func testPrototypeSchemaAndStorageKeyRemainCompatible() throws {
        let storage = MemoryPersistence()
        // Exact v1 JSON field names emitted by the previous native prototype.
        storage.data = Data("""
        {"phase":"paused","pausedRemaining":37.25,"completedSessions":3,"growthAnimationPending":true,"schemaVersion":1}
        """.utf8)
        let store = RestSessionStore(storage: storage)
        XCTAssertEqual(UserDefaultsRestSessionPersistence.defaultKey, "notchIsland.restSession.v1")
        XCTAssertEqual(store.state.phase, .paused)
        XCTAssertEqual(store.remainingSeconds, 38)
        XCTAssertEqual(store.state.completedSessions, 3)
        XCTAssertTrue(store.state.hasTree)
        XCTAssertTrue(store.state.growthAnimationPending)
        XCTAssertEqual(storage.writes, 0, "Valid old data should not be migrated or reset")
        XCTAssertTrue(store.consumeGrowthAnimation(when: RestPresentationState(notchOpen: true, pageMounted: true)))
        let snapshot = try XCTUnwrap(storage.data)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["completedSessions"] as? Int, 3)
        XCTAssertEqual(json["growthAnimationPending"] as? Bool, false)
    }

    func testClosedSecondDisplayCannotOverrideVisibleIsland() throws {
        var registry = RestPresentationRegistry()
        let internalDisplay = UUID()
        let externalDisplay = UUID()
        registry.mountPage(internalDisplay)
        registry.update(sourceID: internalDisplay, notchOpen: true, isIslandPage: true, hidden: false, locked: false)
        registry.update(sourceID: externalDisplay, notchOpen: false, isIslandPage: true, hidden: false, locked: false)
        XCTAssertEqual(registry.visibleSources, [internalDisplay])

        let storage = MemoryPersistence()
        var instant = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = RestSessionStore(storage: storage, now: { instant })
        store.start()
        instant.addTimeInterval(60)
        store.reconcile()
        XCTAssertFalse(store.consumeGrowthAnimation(when: try XCTUnwrap(registry[externalDisplay])))
        XCTAssertTrue(store.state.growthAnimationPending)
        XCTAssertTrue(store.consumeGrowthAnimation(when: try XCTUnwrap(registry[internalDisplay])))

        registry.mountPage(externalDisplay)
        registry.update(sourceID: externalDisplay, notchOpen: true, isIslandPage: true, hidden: false, locked: false)
        XCTAssertFalse(store.consumeGrowthAnimation(when: try XCTUnwrap(registry[externalDisplay])), "A second window cannot redeliver already consumed growth")
    }

    func testVisibilityNeverCombinesConditionsFromDifferentWindowsAndRemovalResetsMount() {
        var registry = RestPresentationRegistry()
        let first = UUID()
        let second = UUID()
        registry.mountPage(first)
        registry.update(sourceID: first, notchOpen: false, isIslandPage: true, hidden: false, locked: false)
        registry.update(sourceID: second, notchOpen: true, isIslandPage: true, hidden: false, locked: false)
        XCTAssertTrue(registry.visibleSources.isEmpty, "An open window without a mounted island cannot borrow another window's mount")

        registry.mountPage(second)
        XCTAssertEqual(registry.visibleSources, [second])
        registry.update(sourceID: second, notchOpen: true, isIslandPage: false, hidden: false, locked: false)
        XCTAssertTrue(registry.visibleSources.isEmpty, "Switching to mirror or another tool immediately blocks island delivery")
        registry.update(sourceID: second, notchOpen: true, isIslandPage: true, hidden: true, locked: false)
        XCTAssertTrue(registry.visibleSources.isEmpty)
        registry.remove(sourceID: second)
        XCTAssertNil(registry[second])
        registry.update(sourceID: second, notchOpen: true, isIslandPage: true, hidden: false, locked: false)
        XCTAssertTrue(registry.visibleSources.isEmpty, "A rebuilt window must actually mount its page again")
        registry.mountPage(second)
        XCTAssertEqual(registry.visibleSources, [second])
        registry.unmountPage(second)
        XCTAssertTrue(registry.visibleSources.isEmpty)
    }

    func testApplicationGateBlocksStaleViewStateWithoutPausingDeadline() throws {
        let sourceID = UUID()
        var registry = RestPresentationRegistry()
        registry.mountPage(sourceID)
        registry.update(sourceID: sourceID, notchOpen: true, isIslandPage: true, hidden: false, locked: false)
        XCTAssertEqual(registry.visibleSources, [sourceID])

        let storage = MemoryPersistence()
        var instant = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let store = RestSessionStore(storage: storage, now: { instant })
        store.start()
        // No per-window callback has run yet; the app gate must block its stale visible flags.
        registry.applicationAvailable = false
        XCTAssertTrue(registry.visibleSources.isEmpty)
        instant.addTimeInterval(61)
        store.reconcile()
        XCTAssertEqual(store.state.phase, .completed)
        XCTAssertTrue(store.state.growthAnimationPending)
        registry.applicationAvailable = true
        let visibleSource = try XCTUnwrap(registry.visibleSources.first)
        XCTAssertTrue(store.consumeGrowthAnimation(when: try XCTUnwrap(registry[visibleSource])))
        XCTAssertFalse(store.state.growthAnimationPending)
        XCTAssertEqual(store.state.completedSessions, 1)
    }

    func testRebuildingWindowsClearsStaleVisibilityAndRequiresNewMount() throws {
        let oldSource = UUID()
        let newSource = UUID()
        var registry = RestPresentationRegistry()
        registry.mountPage(oldSource)
        registry.update(sourceID: oldSource, notchOpen: true, isIslandPage: true, hidden: false, locked: false)
        XCTAssertEqual(registry.visibleSources, [oldSource])

        registry.clearForWindowRebuild()
        XCTAssertFalse(registry.applicationAvailable)
        XCTAssertNil(registry[oldSource])
        XCTAssertTrue(registry.visibleSources.isEmpty)

        // Queued view-state updates cannot borrow a removed page's mount.
        registry.update(sourceID: oldSource, notchOpen: true, isIslandPage: true, hidden: false, locked: false)
        registry.update(sourceID: newSource, notchOpen: true, isIslandPage: true, hidden: false, locked: false)
        registry.applicationAvailable = true
        XCTAssertTrue(registry.visibleSources.isEmpty)
        registry.mountPage(newSource)
        XCTAssertEqual(registry.visibleSources, [newSource])

        // The removed hosting view may deliver its cleanup after the new view appears.
        registry.unmountPage(oldSource)
        registry.remove(sourceID: oldSource)
        XCTAssertEqual(registry.visibleSources, [newSource])
        XCTAssertTrue(try XCTUnwrap(registry[newSource]).canPresentGrowth)
    }
}
