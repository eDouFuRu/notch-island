import Foundation

enum ToolReorderTargetGeometry {
    /// NSView.visibleRect may exceed its own bounds when clipsToBounds is false
    /// (the default since macOS 14). A reorder target must stay inside its row.
    static func visibleTarget(bounds: CGRect, visibleRect: CGRect) -> CGRect {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .null }
        return bounds.intersection(visibleRect)
    }
}

/// The local reorder gesture has one mutation opportunity: a release after the
/// movement threshold over exactly one eligible target. Cancellation is terminal
/// until the next physical press, including if the pointer re-enters the window.
struct ToolReorderLocalGesture: Equatable {
    enum Phase: Equatable { case idle, pressed, dragging, cancelled, finished }
    private(set) var phase: Phase = .idle
    var isDragging: Bool { phase == .dragging }

    mutating func press() { phase = .pressed }
    @discardableResult
    mutating func move(distance: CGFloat) -> Bool {
        guard distance.isFinite else { return false }
        if phase == .pressed && distance > 3 { phase = .dragging }
        return phase == .dragging
    }
    mutating func cancel() {
        if phase == .pressed || phase == .dragging { phase = .cancelled }
    }
    mutating func finish(acceptedTargets: Int) -> Bool {
        let canCommit = phase == .dragging && acceptedTargets == 1
        if phase != .cancelled { phase = .finished }
        return canCommit
    }
}

/// Fixed vocabulary only: no tool names, pasteboard contents, source tokens or
/// pointer coordinates are retained by the diagnostic path.
enum ToolReorderEvent: String, CaseIterable, Sendable {
    case mouseDown = "source.mouseDown"
    case mouseDragged = "source.mouseDragged"
    case clickOnly = "source.clickOnly"
    case mouseUpAfterSession = "source.mouseUpAfterSession"
    case localBegan = "local.began"
    case localMoved = "local.moved"
    case localCancelled = "local.cancelled"
    case localFinished = "local.finished"
    case encodingRejected = "source.encodingRejected"
    case sessionRequested = "source.sessionRequested"
    case sessionBegan = "source.sessionBegan"
    case sessionMoved = "source.sessionMoved"
    case sessionFinished = "source.sessionFinished"
    case sessionCancelled = "source.sessionCancelled"
    case targetEntered = "target.entered"
    case targetUpdated = "target.updated"
    case targetAccepted = "target.accepted"
    case targetRejected = "target.rejected"
    case targetExited = "target.exited"
    case dropPrepared = "drop.prepared"
    case dropAttempted = "drop.attempted"
    case dropCommitted = "drop.committed"
    case dropRejected = "drop.rejected"
    case targetEnded = "target.ended"
}

enum ToolReorderProbeStage: String, CaseIterable, Sendable {
    case current, requested, began, moved, ended
}

/// Anonymous geometry counts. A point may be checked transiently by AppKit,
/// but only these booleans/counts survive; coordinates and view identities do not.
struct ToolReorderTargetMetrics: Equatable, Sendable {
    static let maximumViews = 128
    var total = 0
    var inspected = 0
    var attached = 0
    var registered = 0
    var nonempty = 0
    var visible = 0
    var sessionActive = 0
    var sourceWindow = 0
    var containsPoint = 0
    var acceptsAtPoint = 0
    var rootHitTarget: Bool?
    var truncated = false

    var summary: String {
        func bounded(_ value: Int) -> Int { max(0, min(Self.maximumViews, value)) }
        return "total=\(bounded(total)),inspected=\(bounded(inspected)),attached=\(bounded(attached)),registered=\(bounded(registered)),nonempty=\(bounded(nonempty)),visible=\(bounded(visible)),active=\(bounded(sessionActive)),sourceWindow=\(bounded(sourceWindow)),containsPoint=\(bounded(containsPoint)),acceptsAtPoint=\(bounded(acceptsAtPoint)),rootHitTarget=\(rootHitTarget.map(String.init) ?? "notSampled"),truncated=\(truncated || total > Self.maximumViews)"
    }
}

struct ToolReorderTargetProbes: Equatable, Sendable {
    private(set) var snapshots: [ToolReorderProbeStage: ToolReorderTargetMetrics] = [:]
    mutating func record(_ metrics: ToolReorderTargetMetrics, at stage: ToolReorderProbeStage) {
        snapshots[stage] = metrics
    }
    var summary: String {
        ToolReorderProbeStage.allCases.compactMap { stage in
            snapshots[stage].map { "targets.\(stage.rawValue): \($0.summary)" }
        }.joined(separator: "\n")
    }
}

struct ToolReorderEventCounters: Equatable, Sendable {
    static let maximumCount = 1_000_000
    private(set) var counts: [ToolReorderEvent: Int] = [:]
    private(set) var lastEvent: ToolReorderEvent?

    mutating func record(_ event: ToolReorderEvent) {
        counts[event] = min(Self.maximumCount, counts[event, default: 0] + 1)
        lastEvent = event
    }

    var summary: String {
        let rows = ToolReorderEvent.allCases.compactMap { event -> String? in
            guard let count = counts[event] else { return nil }
            return "\(event.rawValue)=\(count)"
        }
        return (["last=\(lastEvent?.rawValue ?? "none")"] + rows).joined(separator: "\n")
    }
}

/// Native source and destination use one explicit bounded serialization format.
/// Do not depend on the opaque encoding chosen by SwiftUI's Transferable bridge.
enum ToolReorderPayloadCodec {
    static let pasteboardType = "com.dongfengrui.NotchIsland.tool-reorder"
    static let maximumBytes = 2_048

    static func encode(_ payload: ToolGridDragPayload) -> Data? {
        guard isWellFormed(payload), let data = try? JSONEncoder().encode(payload),
              data.count <= maximumBytes else { return nil }
        return data
    }

    static func decode(_ data: Data) -> ToolGridDragPayload? {
        guard data.count <= maximumBytes,
              let payload = try? JSONDecoder().decode(ToolGridDragPayload.self, from: data),
              isWellFormed(payload) else { return nil }
        return payload
    }

    private static func isWellFormed(_ payload: ToolGridDragPayload) -> Bool {
        payload.version == 1 && !payload.toolID.isEmpty && payload.toolID.utf8.count <= 128 &&
            !payload.sourceID.isEmpty && payload.sourceID.utf8.count <= 128
    }
}
