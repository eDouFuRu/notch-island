import XCTest
@testable import NotchInteractionCore

final class ToolGridConfigurationTests: XCTestCase {
    func testReorderingSkipsHiddenTilesWithoutLosingThem() throws {
        var state = ToolGridConfiguration(allIDs: ["capture", "hidden", "clock", "notes"], defaultVisible: ["capture", "clock", "notes"])
        state.move("notes", by: -1)
        XCTAssertEqual(state.selectedIDs, ["capture", "notes", "clock"])
        state.setVisible(true, id: "hidden")
        XCTAssertEqual(state.selectedIDs, ["capture", "hidden", "notes", "clock"])
        let restored = try JSONDecoder().decode(ToolGridConfiguration.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
    }
    func testReconcileRemovesRetiredIDsAndAppendsNewToolsWithoutEnablingThem() {
        var state = ToolGridConfiguration(allIDs: ["a", "b", "a"], defaultVisible: ["a", "b", "invalid"])
        state.reconcile(allIDs: ["b", "c", "b"])
        XCTAssertEqual(state.orderedIDs, ["b", "c"])
        XCTAssertEqual(state.selectedIDs, ["b"])
    }
    func testEmptySelectionAndBoundaryMoveRemainStable() {
        var state = ToolGridConfiguration(allIDs: ["a"], defaultVisible: ["a"])
        state.move("a", by: -1); state.move("a", by: 1)
        XCTAssertEqual(state.selectedIDs, ["a"])
        state.setVisible(false, id: "a"); state.reconcile(allIDs: ["a", "b"])
        XCTAssertTrue(state.selectedIDs.isEmpty)
        state.setVisible(true, id: "unrecognized"); XCTAssertTrue(state.selectedIDs.isEmpty)
    }

    func testDragMovesAcrossMultipleVisibleToolsWhileHiddenSlotsStayPut() throws {
        var state = ToolGridConfiguration(allIDs: ["a", "hidden1", "b", "c", "hidden2", "d"],
                                          defaultVisible: ["a", "b", "c", "d"])
        XCTAssertTrue(state.drop(.init(toolID: "a", sourceID: "local"), on: "d", sourceID: "local"))
        XCTAssertEqual(state.selectedIDs, ["b", "c", "d", "a"])
        XCTAssertEqual(state.orderedIDs, ["b", "hidden1", "c", "d", "hidden2", "a"])
        XCTAssertTrue(state.drop(.init(toolID: "a", sourceID: "local"), on: "b", sourceID: "local"))
        XCTAssertEqual(state.selectedIDs, ["a", "b", "c", "d"])
        let restored = try JSONDecoder().decode(ToolGridConfiguration.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
    }

    func testDragPayloadRejectsExternalStaleHiddenUnknownAndSelfDropsWithoutMutation() {
        var state = ToolGridConfiguration(allIDs: ["a", "hidden", "b"], defaultVisible: ["a", "b"])
        let original = state
        for (payload, target) in [
            (ToolGridDragPayload(toolID: "a", sourceID: "other-app"), "b"),
            (.init(toolID: "a", sourceID: "local", version: 2), "b"),
            (.init(toolID: "hidden", sourceID: "local"), "b"),
            (.init(toolID: "unknown", sourceID: "local"), "b"),
            (.init(toolID: "a", sourceID: "local"), "hidden"),
            (.init(toolID: "a", sourceID: "local"), "unknown"),
            (.init(toolID: "a", sourceID: "local"), "a")
        ] {
            XCTAssertFalse(state.drop(payload, on: target, sourceID: "local"))
            XCTAssertEqual(state, original)
        }
    }

    func testCancelledDragOnlyCreatesPayloadAndChangesNoPreferences() throws {
        let state = ToolGridConfiguration(allIDs: ["a", "b", "c"], defaultVisible: ["a", "b", "c"])
        let before = state
        let payload = ToolGridDragPayload(toolID: "b", sourceID: "local")
        let decoded = try JSONDecoder().decode(ToolGridDragPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(state, before)
    }

    func testRepeatedValidDropsNeverDuplicateOrLoseTools() {
        var state = ToolGridConfiguration(allIDs: ["a", "hidden", "b", "c", "d"], defaultVisible: ["a", "b", "c", "d"])
        for source in ["a", "b", "c", "d"] {
            for target in ["a", "b", "c", "d"] {
                state.drop(.init(toolID: source, sourceID: "local"), on: target, sourceID: "local")
                XCTAssertEqual(Set(state.orderedIDs), ["a", "hidden", "b", "c", "d"])
                XCTAssertEqual(state.orderedIDs.count, 5)
                XCTAssertEqual(state.selectedIDs.count, 4)
                XCTAssertEqual(state.orderedIDs[1], "hidden")
            }
        }
    }
}
