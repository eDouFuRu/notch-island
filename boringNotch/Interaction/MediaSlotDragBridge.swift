import AppKit
import SwiftUI

/// The media control layout's typed face onto `LocalReorderRuntime`.
///
/// The layout preview lives in a `Form` with `.formStyle(.grouped)`, where SwiftUI's
/// `.onDrag`/`.onDrop` never fire on macOS — the same reason the tool grid uses this
/// runtime. Unlike the tool grid there is no separate grab handle: the tile itself is the
/// drag source, so the click, the context menu and the close button it covers all have to
/// be reinstated explicitly.
struct NativeMediaSlotDragHandle: NSViewRepresentable {
    /// `nil` for an empty slot: nothing to drag, but the tile still takes clicks.
    let payload: MediaControlDragPayload?
    let symbolName: String
    let prefersLargeScale: Bool
    let accessibilityHint: String
    let onClick: () -> Void
    /// `nil` where there is no close button to keep clickable.
    let removeTitle: String?
    let onRemove: (() -> Void)?
    /// Matches the visible part of the close button, which is drawn half outside the tile.
    let closeButtonCorner: CGSize

    func makeNSView(context: Context) -> LocalReorderHandleView {
        let view = LocalReorderHandleView()
        view.drawsChrome = false
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: LocalReorderHandleView, context: Context) {
        view.payload = payload
        view.onClick = onClick
        view.excludedTopTrailingCorner = onRemove == nil ? .zero : closeButtonCorner
        view.toolTip = accessibilityHint
        // The SwiftUI tile underneath already publishes the accessible element; a second one
        // for the handle would just duplicate every slot in the accessibility tree.
        view.setAccessibilityElement(false)
        let symbolName = self.symbolName
        let prefersLargeScale = self.prefersLargeScale
        view.previewProvider = { Self.ghost(symbolName: symbolName, prefersLargeScale: prefersLargeScale) }
        if let onRemove, let removeTitle {
            view.contextMenuProvider = {
                let menu = NSMenu()
                let item = NSMenuItem(title: removeTitle, action: nil, keyEquivalent: "")
                item.target = MediaSlotMenuAction.shared
                item.action = #selector(MediaSlotMenuAction.invoke(_:))
                item.representedObject = MediaSlotMenuAction.Box(handler: onRemove)
                menu.addItem(item)
                return menu
            }
        } else {
            view.contextMenuProvider = nil
        }
        view.window?.invalidateCursorRects(for: view)
    }

    static func dismantleNSView(_ view: LocalReorderHandleView, coordinator: ()) {
        LocalReorderRuntime.shared.cancel(ifSource: view)
    }

    /// The tile is a 44pt icon square, so the ghost is one too rather than the tool grid's
    /// icon-and-title row.
    private static func ghost(symbolName: String, prefersLargeScale: Bool) -> NSImage {
        let side: CGFloat = 44
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: prefersLargeScale ? 18 : 15, weight: .medium))
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).stroke()
            if let symbol {
                let size = symbol.size
                symbol.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                       width: size.width, height: size.height))
            }
            return true
        }
    }
}

/// `NSMenuItem` needs an ObjC target; a Swift closure cannot be one directly.
@MainActor private final class MediaSlotMenuAction: NSObject {
    static let shared = MediaSlotMenuAction()
    final class Box { let handler: () -> Void; init(handler: @escaping () -> Void) { self.handler = handler } }
    @objc func invoke(_ sender: NSMenuItem) {
        (sender.representedObject as? Box)?.handler()
    }
}

struct NativeMediaSlotDropTarget: NSViewRepresentable {
    let cornerRadius: CGFloat
    let canDrop: (MediaControlDragPayload) -> Bool
    let performDrop: (MediaControlDragPayload) -> Bool

    func makeNSView(context: Context) -> LocalReorderDropView {
        let view = LocalReorderDropView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: LocalReorderDropView, context: Context) {
        view.cornerRadius = cornerRadius
        let canDrop = self.canDrop
        let performDrop = self.performDrop
        // A tool-grid payload fails this downcast and is declined, which is what keeps
        // erasing the payload to `Any` inside the runtime safe.
        view.canDrop = { ($0 as? MediaControlDragPayload).map(canDrop) ?? false }
        view.performDrop = { ($0 as? MediaControlDragPayload).map(performDrop) ?? false }
    }
    static func dismantleNSView(_ view: LocalReorderDropView, coordinator: ()) {
        view.deactivate()
    }
}
