import AppKit

/// A window-local drag runtime for reordering inside a `Form`.
///
/// macOS swallows SwiftUI's `.onDrag`/`.onDrop` inside `Form { }` with `.formStyle(.grouped)`,
/// so anything that needs dragging in the settings window has to run its own down/drag/up
/// sequence in AppKit. No OS drag session, pasteboard or cross-app operation is involved.
///
/// The runtime is deliberately **not** generic: Swift forbids static stored properties in
/// generic types, so a `LocalReorderRuntime<Payload>.shared` cannot exist, and generic
/// `NSView` subclasses are hazardous in the ObjC runtime. Instead the payload is erased to
/// `Any` here and re-typed by the thin `NSViewRepresentable` wrappers that sit on top; a
/// stale target from another domain simply fails its downcast and declines the drop.
@MainActor final class LocalReorderRuntime {
    static let shared = LocalReorderRuntime()

    private let destinations = NSHashTable<LocalReorderDropView>.weakObjects()
    private weak var source: LocalReorderHandleView?
    private weak var sourceWindow: NSWindow?
    private var payload: Any?
    private weak var highlighted: LocalReorderDropView?
    private var evaluatedTarget = false
    private var preview: LocalReorderPreviewView?
    private var escapeMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    var isActive: Bool { source != nil && sourceWindow != nil && payload != nil }

    func register(_ view: LocalReorderDropView) { destinations.add(view) }

    func begin(source: LocalReorderHandleView, payload: Any, at point: NSPoint) {
        guard let window = source.window, window.isVisible, source.superview != nil else {
            source.cancelPress()
            return
        }
        if isActive { cancel() }
        self.source = source
        sourceWindow = window
        self.payload = payload
        source.emit(.localBegan)
        let ghost = LocalReorderPreviewView()
        ghost.image = source.makePreview()
        ghost.imageScaling = .scaleNone
        ghost.alphaValue = 0.94
        window.contentView?.addSubview(ghost)
        preview = ghost
        // Local events only. Escape is consumed only while this local drag is
        // active. No global keyboard/mouse monitor or focus change is installed.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.isActive == true else { return event }
            self?.cancel()
            return nil
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                            object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
        update(from: source, at: point)
    }

    func update(from source: LocalReorderHandleView, at point: NSPoint) {
        guard self.source === source, let window = sourceWindow,
              source.window === window, source.superview != nil,
              window.isVisible, insideContent(point, window: window) else {
            cancel(ifSource: source)
            return
        }
        source.emit(.localMoved)
        let candidates = candidates(at: point, window: window)
        let target = candidates.count == 1 ? candidates.first : nil
        if !evaluatedTarget || highlighted !== target {
            evaluatedTarget = true
            highlighted?.setTargeted(false)
            highlighted = target
            target?.setTargeted(true)
            source.emit(target == nil ? .targetRejected : .targetAccepted)
        }
        if let preview, let image = preview.image, let host = window.contentView {
            let local = host.convert(point, from: nil)
            // The ghost stays inside this window and never participates in hit
            // testing. These coordinates are transient rendering state only.
            let x = min(max(host.bounds.minX, local.x + 14), max(host.bounds.minX, host.bounds.maxX - image.size.width))
            let y = min(max(host.bounds.minY, local.y + 18), max(host.bounds.minY, host.bounds.maxY - image.size.height))
            preview.frame = NSRect(origin: NSPoint(x: x, y: y), size: image.size)
        }
    }

    func finish(from source: LocalReorderHandleView, at point: NSPoint) {
        guard self.source === source else { source.finishPress(acceptedTargets: 0); return }
        let candidates: [LocalReorderDropView]
        if let window = sourceWindow, source.window === window, source.superview != nil,
           window.isVisible, insideContent(point, window: window) {
            candidates = self.candidates(at: point, window: window)
        } else { candidates = [] }
        // Mark the gesture terminal BEFORE the drop handler can reorder/remove its
        // source view. Then clear observers/highlight before publishing data: a
        // `@Published`/`@Default` write mid-drag makes the enclosing Form re-lay-out
        // and tears the drag apart.
        let accepted = source.finishPress(acceptedTargets: candidates.count)
        let action = candidates.count == 1 ? candidates.first?.performDrop : nil
        let payload = self.payload
        let emit = source.onEvent
        cleanup()
        if accepted, let action, let payload {
            emit(.dropAttempted)
            let committed = action(payload) // the store revalidates against current configuration
            emit(committed ? .dropCommitted : .dropRejected)
            emit(.localFinished)
        } else { emit(.localCancelled) }
    }

    func cancel(ifSource source: LocalReorderHandleView) {
        guard self.source === source else { return }
        cancel()
    }

    func cancel() {
        let wasActive = isActive
        let emit = source?.onEvent
        source?.cancelPress()
        cleanup()
        if wasActive { emit?(.localCancelled) }
    }

    private func cleanup() {
        highlighted?.setTargeted(false)
        highlighted = nil
        evaluatedTarget = false
        preview?.removeFromSuperview()
        preview = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        source?.onIdle()
        source = nil
        sourceWindow = nil
        payload = nil
    }

    private func insideContent(_ point: NSPoint, window: NSWindow) -> Bool {
        guard let host = window.contentView else { return false }
        return host.bounds.contains(host.convert(point, from: nil))
    }

    private func candidates(at point: NSPoint, window: NSWindow) -> [LocalReorderDropView] {
        guard let payload else { return [] }
        return destinations.allObjects.filter { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor && view.alphaValue > 0 &&
                ToolReorderTargetGeometry.visibleTarget(bounds: view.bounds, visibleRect: view.visibleRect)
                    .contains(view.convert(point, from: nil)) && view.canDrop(payload)
        }
    }
}

@MainActor final class LocalReorderPreviewView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// The handle owns an ordinary AppKit down/drag/up sequence.
///
/// Taking over `hitTest` means the SwiftUI gesture recognisers underneath stop receiving
/// events entirely — passive pass-through is not a thing in AppKit. Anything the covered
/// area still has to do (a plain click, a context menu) must be rebuilt here explicitly, or
/// carved out of the hit area via `excludedHotZone`.
@MainActor final class LocalReorderHandleView: NSView {
    var payload: Any?
    var previewTitle = ""
    var previewSymbol = "line.3.horizontal"
    var onEvent: (ToolReorderEvent) -> Void = { _ in }
    var onIdle: () -> Void = {}
    /// Draws the built-in grab-handle chrome. Off when the handle merely covers an
    /// already-drawn tile.
    var drawsChrome = true
    /// Custom ghost image. Falls back to the icon+title row used by the tool grid.
    var previewProvider: (() -> NSImage)?
    /// A release that never crossed the movement threshold.
    var onClick: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    /// Size of a corner the handle refuses to receive events in, so a control drawn
    /// underneath it stays clickable. Expressed as a size rather than a rectangle on
    /// purpose: the caller would otherwise have to flip a SwiftUI rect into AppKit's y-up
    /// space by hand, and getting that wrong yields a button that cannot be pressed.
    var excludedTopTrailingCorner: CGSize = .zero

    private var downPoint: NSPoint?
    private var gesture = ToolReorderLocalGesture()
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        drawsChrome ? NSSize(width: 24, height: 24) : NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    override func resetCursorRects() {
        guard payload != nil else { return }
        addCursorRect(bounds, cursor: .openHand)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let corner = excludedTopTrailingCorner
        if corner.width > 0, corner.height > 0 {
            let hole = CGRect(x: bounds.maxX - corner.width, y: bounds.maxY - corner.height,
                              width: corner.width, height: corner.height)
            if hole.contains(convert(point, from: superview)) { return nil }
        }
        return super.hitTest(point)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { LocalReorderRuntime.shared.cancel(ifSource: self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { LocalReorderRuntime.shared.cancel(ifSource: self) }
        super.viewWillMove(toSuperview: newSuperview)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard drawsChrome else { return }
        let background = pressed ? NSColor.controlAccentColor.withAlphaComponent(0.22)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.09)
        background.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        let icon = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
        icon?.draw(in: bounds.insetBy(dx: 6, dy: 6))
    }
    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        gesture.press()
        pressed = true
        needsDisplay = true
        emit(.mouseDown)
    }
    override func mouseDragged(with event: NSEvent) {
        emit(.mouseDragged)
        guard let downPoint, let payload else { return }
        let point = event.locationInWindow
        let wasDragging = gesture.isDragging
        guard gesture.move(distance: hypot(point.x - downPoint.x, point.y - downPoint.y)) else { return }
        if !wasDragging {
            LocalReorderRuntime.shared.begin(source: self, payload: payload, at: point)
        } else { LocalReorderRuntime.shared.update(from: self, at: point) }
    }
    override func mouseUp(with event: NSEvent) {
        if gesture.isDragging {
            LocalReorderRuntime.shared.finish(from: self, at: event.locationInWindow)
        } else {
            let wasPress = gesture.phase == .pressed
            if wasPress { emit(.clickOnly) }
            finishPress(acceptedTargets: 0)
            // Publishing happens after the gesture is terminal, never mid-drag.
            if wasPress { onClick?() }
        }
        downPoint = nil
        pressed = false
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { LocalReorderRuntime.shared.cancel(ifSource: self) }
        else { super.keyDown(with: event) }
    }

    func emit(_ event: ToolReorderEvent) { onEvent(event) }

    func cancelPress() {
        gesture.cancel()
        pressed = false
        needsDisplay = true
    }

    @discardableResult func finishPress(acceptedTargets: Int) -> Bool {
        let accepted = gesture.finish(acceptedTargets: acceptedTargets)
        pressed = false
        needsDisplay = true
        return accepted
    }

    func makePreview() -> NSImage {
        if let previewProvider { return previewProvider() }
        let title = String(previewTitle.prefix(80)) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor
        ]
        let size = NSSize(width: min(280, max(100, title.size(withAttributes: attributes).width + 46)), height: 34)
        let symbol = NSImage(systemSymbolName: previewSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
        return NSImage(size: size, flipped: false) { bounds in
            NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).stroke()
            symbol?.draw(in: NSRect(x: 10, y: 9, width: 16, height: 16))
            title.draw(in: NSRect(x: 34, y: 9, width: size.width - 44, height: 17), withAttributes: attributes)
            return true
        }
    }
}

/// Pure visual marker for one drop target. Normal clicks always pass through; local hit
/// testing is performed explicitly against bounds AND visibleRect by the runtime.
@MainActor final class LocalReorderDropView: NSView {
    var cornerRadius: CGFloat = 8
    var canDrop: (Any) -> Bool = { _ in false }
    var performDrop: (Any) -> Bool = { _ in false }
    private var targeted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        setAccessibilityElement(false)
        LocalReorderRuntime.shared.register(self)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func deactivate() {
        setTargeted(false)
        canDrop = { _ in false }
        performDrop = { _ in false }
    }

    func setTargeted(_ value: Bool) {
        guard targeted != value else { return }
        targeted = value
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard targeted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
    }
}
