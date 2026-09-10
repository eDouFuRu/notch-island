import AppKit
import CoreGraphics

/// A user-operated region selector; it draws a translucent overlay, never a
/// screenshot. The selected overlay disappears before the recorder starts.
@MainActor
final class CaptureRegionSelector {
    private var panels: [NSPanel] = []
    private var completion: ((CaptureRegion?) -> Void)?

    func select(completion: @escaping (CaptureRegion?) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        for screen in NSScreen.screens {
            guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let view = CaptureRegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                                  screenFrame: screen.frame,
                                                  quartzFrame: CGDisplayBounds(displayNumber.uint32Value))
            view.onFinish = { [weak self] in self?.finish($0) }
            let panel = CaptureSelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                              backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        guard !panels.isEmpty else { finish(nil); return }
        let active = panels.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? panels[0]
        active.makeKey()
        active.makeFirstResponder(active.contentView)
    }

    func cancel() { finish(nil) }

    private func finish(_ region: CaptureRegion?) {
        guard let callback = completion else { return }
        completion = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        callback(region)
    }
}

private final class CaptureSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CaptureRegionSelectionView: NSView {
    var onFinish: ((CaptureRegion?) -> Void)?
    private let screenFrame: CGRect
    private let quartzFrame: CGRect
    private var anchor: CGPoint?
    private var selection: CGRect?

    init(frame: CGRect, screenFrame: CGRect, quartzFrame: CGRect) {
        self.screenFrame = screenFrame
        self.quartzFrame = quartzFrame
        super.init(frame: frame)
        setAccessibilityLabel(L("Select an area to record"))
        setAccessibilityHelp(L("Drag to select an area. Release to start recording. Press Escape to cancel."))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        anchor = point(for: event)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let current = point(for: event)
        selection = CGRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                           width: abs(anchor.x - current.x), height: abs(anchor.y - current.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        anchor = nil
        guard let selection,
              let region = CaptureRegionPolicy.region(from: selection, appKitScreen: screenFrame,
                                                      quartzScreen: quartzFrame) else { return }
        onFinish?(region)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }
    }

    private func point(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, local.x), bounds.width), y: min(max(0, local.y), bounds.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.24).setFill()
        bounds.fill()
        if let selection, selection.width > 0, selection.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            selection.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
        let text = L("Drag to select an area. Release to start recording. Press Escape to cancel.")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGRect(x: (bounds.width - size.width) / 2 - 14, y: bounds.height - 92,
                         width: size.width + 28, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 14, y: box.minY + 10), withAttributes: attributes)
    }
}
