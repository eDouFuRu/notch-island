import XCTest
@testable import NotchInteractionCore

final class ToolReorderDiagnosticsTests: XCTestCase {
    func testUnclippedVisibleRectCannotTurnEveryRowIntoTheSameDropTarget() {
        let parentDrawingArea = CGRect(x: 0, y: 0, width: 480, height: 700)
        let pointerInParent = CGPoint(x: 88, y: 65)
        var hits = 0
        for row in 0..<14 {
            let rowOriginY = CGFloat(row * 40)
            // AppKit's visibleRect can cover the whole ancestor in each view's
            // own coordinates even when the view itself is only 28 points tall.
            let unclipped = parentDrawingArea.offsetBy(dx: 0, dy: -rowOriginY)
            let pointer = CGPoint(x: pointerInParent.x, y: pointerInParent.y - rowOriginY)
            XCTAssertTrue(unclipped.contains(pointer))
            let target = ToolReorderTargetGeometry.visibleTarget(
                bounds: CGRect(x: 0, y: 0, width: 440, height: 28), visibleRect: unclipped)
            if target.contains(pointer) { hits += 1 }
        }
        XCTAssertEqual(hits, 1)
    }

    func testTargetGeometryPreservesScrollClippingAndRejectsZeroBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 440, height: 28)
        let clipped = CGRect(x: 0, y: 10, width: 440, height: 18)
        let target = ToolReorderTargetGeometry.visibleTarget(bounds: bounds, visibleRect: clipped)
        XCTAssertFalse(target.contains(CGPoint(x: 100, y: 5)))
        XCTAssertTrue(target.contains(CGPoint(x: 100, y: 15)))
        XCTAssertFalse(target.contains(CGPoint(x: 500, y: 15)))
        XCTAssertTrue(ToolReorderTargetGeometry.visibleTarget(bounds: .zero, visibleRect: bounds).isNull)
    }

    func testNativeEncodingRoundTripAndMalformedPasteboardRejection() throws {
        let payload = ToolGridDragPayload(toolID: "capture", sourceID: UUID().uuidString)
        let encoded = try XCTUnwrap(ToolReorderPayloadCodec.encode(payload))
        XCTAssertEqual(ToolReorderPayloadCodec.decode(encoded), payload)
        XCTAssertNil(ToolReorderPayloadCodec.decode(Data("not JSON".utf8)))
        XCTAssertNil(ToolReorderPayloadCodec.decode(Data("{\"toolID\":\"capture\"}".utf8)))
        XCTAssertNil(ToolReorderPayloadCodec.decode(Data(repeating: 32, count: ToolReorderPayloadCodec.maximumBytes + 1)))
        for invalid in [
            ToolGridDragPayload(toolID: "capture", sourceID: "local", version: 2),
            .init(toolID: "", sourceID: "local"),
            .init(toolID: "capture", sourceID: ""),
            .init(toolID: String(repeating: "x", count: 129), sourceID: "local")
        ] {
            XCTAssertNil(ToolReorderPayloadCodec.encode(invalid))
            XCTAssertNil(ToolReorderPayloadCodec.decode(try JSONEncoder().encode(invalid)))
        }
    }

    func testRepeatedHoverAndCancelledSessionNeverMutateConfiguration() {
        let state = ToolGridConfiguration(allIDs: ["a", "hidden", "b", "c"], defaultVisible: ["a", "b", "c"])
        let before = state
        let payload = ToolGridDragPayload(toolID: "a", sourceID: "local")
        for _ in 0..<100 {
            XCTAssertTrue(state.canDrop(payload, on: "b", sourceID: "local"))
            XCTAssertFalse(state.canDrop(payload, on: "a", sourceID: "local"))
            XCTAssertFalse(state.canDrop(payload, on: "hidden", sourceID: "local"))
        }
        XCTAssertEqual(state, before)
    }

    func testAcceptedHoverIsRevalidatedAfterConfigurationChangesBeforeDrop() {
        var state = ToolGridConfiguration(allIDs: ["a", "b", "c"], defaultVisible: ["a", "b", "c"])
        let payload = ToolGridDragPayload(toolID: "a", sourceID: "local")
        XCTAssertTrue(state.canDrop(payload, on: "c", sourceID: "local"))
        state.setVisible(false, id: "a")
        let afterChange = state
        XCTAssertFalse(state.drop(payload, on: "c", sourceID: "local"))
        XCTAssertEqual(state, afterChange)
    }

    func testSourceTokenMustRemainCurrentThroughDrop() throws {
        var state = ToolGridConfiguration(allIDs: ["a", "b"], defaultVisible: ["a", "b"])
        let payload = ToolGridDragPayload(toolID: "a", sourceID: "previous-session")
        let encoded = try XCTUnwrap(ToolReorderPayloadCodec.encode(payload))
        let decoded = try XCTUnwrap(ToolReorderPayloadCodec.decode(encoded))
        XCTAssertFalse(state.canDrop(decoded, on: "b", sourceID: "current-session"))
        XCTAssertFalse(state.drop(decoded, on: "b", sourceID: "current-session"))
        XCTAssertEqual(state.selectedIDs, ["a", "b"])
    }

    func testDiagnosticsOnlyContainFixedStagesAndBoundedCounters() {
        var counters = ToolReorderEventCounters()
        XCTAssertEqual(counters.summary, "last=none")
        for event in [ToolReorderEvent.mouseDown, .mouseDragged, .sessionRequested, .sessionBegan,
                      .targetEntered, .targetAccepted, .dropPrepared, .dropAttempted,
                      .dropCommitted, .sessionFinished] {
            counters.record(event)
        }
        XCTAssertEqual(counters.lastEvent, .sessionFinished)
        XCTAssertEqual(counters.counts[.dropCommitted], 1)
        XCTAssertFalse(counters.summary.contains("UUID"))
        XCTAssertFalse(counters.summary.contains("capture"))
        for _ in 0...ToolReorderEventCounters.maximumCount { counters.record(.targetUpdated) }
        XCTAssertEqual(counters.counts[.targetUpdated], ToolReorderEventCounters.maximumCount)
        XCTAssertLessThan(counters.summary.count, 2_000)
    }

    func testTargetProbesRetainBoundedStageSnapshotsWithoutPositionsOrIdentity() {
        var probes = ToolReorderTargetProbes()
        var visible = ToolReorderTargetMetrics()
        visible.total = 8; visible.inspected = 8; visible.registered = 8
        visible.attached = 8; visible.nonempty = 8; visible.visible = 8
        visible.sessionActive = 8; visible.sourceWindow = 8
        visible.containsPoint = 1; visible.acceptsAtPoint = 1; visible.rootHitTarget = true
        probes.record(visible, at: .requested)
        for _ in 0..<100 {
            probes.record(visible, at: .moved)
        }
        var afterSession = visible
        afterSession.sessionActive = 0
        afterSession.rootHitTarget = nil
        probes.record(afterSession, at: .current)
        XCTAssertEqual(probes.snapshots.count, 3)
        XCTAssertEqual(probes.snapshots[.moved]?.rootHitTarget, true)
        XCTAssertTrue(probes.summary.contains("targets.requested:"))
        XCTAssertTrue(probes.summary.contains("rootHitTarget=notSampled"))
        XCTAssertFalse(probes.summary.contains("toolID"))
        XCTAssertFalse(probes.summary.contains("sourceID"))
        XCTAssertFalse(probes.summary.contains("screenPoint"))
        var huge = visible
        huge.total = .max; huge.registered = .max; huge.containsPoint = -1
        XCTAssertTrue(huge.summary.contains("total=128"))
        XCTAssertTrue(huge.summary.contains("registered=128"))
        XCTAssertTrue(huge.summary.contains("containsPoint=0"))
        XCTAssertTrue(huge.summary.contains("truncated=true"))
        XCTAssertLessThan(probes.summary.count, 2_000)
    }
}
