import AppKit
import Combine
import SwiftUI

/// Local, fixed-vocabulary counters. No pointer coordinates, tool names,
/// identifiers or clipboard content are retained. No publication during a drag
/// can invalidate the surrounding Form; the final result is published afterward.
@MainActor final class ToolReorderDiagnostics: ObservableObject {
    static let shared = ToolReorderDiagnostics()
    @Published private(set) var summary = ToolReorderEventCounters().summary
    private var counters = ToolReorderEventCounters()

    fileprivate func record(_ event: ToolReorderEvent) {
        counters.record(event)
        if !LocalReorderRuntime.shared.isActive { refresh() }
    }
    func refresh() { summary = "mode=local\n" + counters.summary }
    func reset() { counters = ToolReorderEventCounters(); refresh() }
}

/// The tool grid's typed face onto `LocalReorderRuntime`. The runtime carries the payload
/// as `Any`; this is the one place it is put back into `ToolGridDragPayload`.
struct NativeToolReorderHandle: NSViewRepresentable {
    let payload: ToolGridDragPayload
    let title: String
    let symbolName: String
    let hint: String

    func makeNSView(context: Context) -> LocalReorderHandleView {
        let view = LocalReorderHandleView()
        view.onEvent = { ToolReorderDiagnostics.shared.record($0) }
        view.onIdle = { ToolReorderDiagnostics.shared.refresh() }
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: LocalReorderHandleView, context: Context) {
        view.payload = payload
        view.previewTitle = title
        view.previewSymbol = symbolName
        view.toolTip = hint
        view.setAccessibilityLabel(hint)
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: LocalReorderHandleView, coordinator: ()) {
        LocalReorderRuntime.shared.cancel(ifSource: view)
    }
}

/// Pure visual marker for one row/card. Normal clicks always pass through;
/// local hit testing is performed explicitly against bounds AND visibleRect.
struct NativeToolReorderDropTarget: NSViewRepresentable {
    let cornerRadius: CGFloat
    let canDrop: (ToolGridDragPayload) -> Bool
    let performDrop: (ToolGridDragPayload) -> Bool

    func makeNSView(context: Context) -> LocalReorderDropView {
        let view = LocalReorderDropView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: LocalReorderDropView, context: Context) {
        view.cornerRadius = cornerRadius
        let canDrop = self.canDrop
        let performDrop = self.performDrop
        // A payload from the other local-reorder domain fails the downcast and is declined,
        // which is what keeps erasing to `Any` inside the runtime safe.
        view.canDrop = { ($0 as? ToolGridDragPayload).map(canDrop) ?? false }
        view.performDrop = { ($0 as? ToolGridDragPayload).map(performDrop) ?? false }
    }
    static func dismantleNSView(_ view: LocalReorderDropView, coordinator: ()) {
        view.deactivate()
    }
}
