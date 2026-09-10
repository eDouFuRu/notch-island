// Custom changes for 工位充电岛: physical-notch-only opening and transparent-window input.
import AppKit
import Combine
import Defaults

@MainActor
final class NotchPointerCoordinator: ObservableObject {
    private weak var window: NSWindow?
    private var screen: NSScreen
    private let isExpanded: () -> Bool
    private let keepsOpen: () -> Bool
    private let open: () -> Void
    private let close: () -> Void
    private var machine = NotchHoverStateMachine(closeDelay: Defaults[.notchCloseDelay])
    private var closeTrigger = Defaults[.notchCloseTriggerMode].machineTrigger
    private var observations: Set<AnyCancellable> = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var trackedMenus = Set<ObjectIdentifier>()
    private var pendingTask: Task<Void, Never>?
    private var commandGraceTask: Task<Void, Never>?
    private var scheduledDeadline: TimeInterval?
    private var commandGraceUntil: TimeInterval = 0
    private var enabled = false
    private var briefRowTop: CGFloat?
    private var briefRowInteractive = false
    private var briefRowInset: CGFloat = 6
    private var briefHoverCallback: ((Bool) -> Void)?
    private var lastBriefHovered = false

    /// Brief rows never contribute to the physical trigger rectangle.
    func configureBriefRow(topInset: CGFloat?, interactive: Bool, horizontalInset: CGFloat,
                           onHover: @escaping (Bool) -> Void) {
        briefRowTop = topInset
        briefRowInteractive = interactive
        briefRowInset = horizontalInset
        briefHoverCallback = onHover
        reevaluate()
    }

    private func isInBriefRow(_ point: CGPoint, region: NotchHitRegion) -> Bool {
        guard let briefRowTop, region.containsVisible(point) else { return false }
        let row = BriefInteractionRegion.rowRect(visibleRect: region.visibleFrame, rowTopInset: briefRowTop)
            .insetBy(dx: briefRowInset, dy: 0)
        return row.contains(point)
    }

    private func captures(_ point: CGPoint, region: NotchHitRegion, active: Bool) -> Bool {
        guard active else { return false }
        // The floating control sits outside the painted shape, so it is checked separately
        // or the window would stay click-through exactly where it is drawn.
        if region.containsAccessory(point) { return isExpanded() }
        guard region.containsVisible(point) else { return false }
        if isInBriefRow(point, region: region) { return briefRowInteractive }
        return isExpanded()
    }

    /// Whether a control is currently floating beside the island. Set by the view that
    /// draws it, so the hit region only grows while it is actually on screen.
    private var accessoryVisible = false

    func setAccessoryControlVisible(_ visible: Bool) {
        guard accessoryVisible != visible else { return }
        accessoryVisible = visible
        reevaluate()
    }
    private var presentationSize: CGSize = .zero
    private var topRadius: CGFloat = 6
    private var bottomRadius: CGFloat = 14
    private var queuedPresentation: (CGSize, CGFloat, CGFloat)?
    private var presentationFlushScheduled = false
    #if DEBUG
    private var automaticHoverSuspendedForDiagnostics = false
    #endif

    init(window: NSWindow, screen: NSScreen, isExpanded: @escaping () -> Bool,
         keepsOpen: @escaping () -> Bool = { false }, open: @escaping () -> Void,
         close: @escaping () -> Void) {
        self.window = window
        self.screen = screen
        self.isExpanded = isExpanded
        self.keepsOpen = keepsOpen
        self.open = open
        self.close = close
        self.presentationSize = Self.triggerRect(for: screen).size
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = true
    }

    deinit {
        pendingTask?.cancel()
        commandGraceTask?.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The owner combines persistent hidden state and screen/session lock state here.
    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { if enabled { reevaluate() }; return }
        self.enabled = enabled
        if enabled {
            installObservers()
            reevaluate()
        } else {
            stopObservers()
            window?.ignoresMouseEvents = true
        }
    }

    func updateScreen(_ screen: NSScreen) {
        self.screen = screen
        reevaluate()
    }

    /// Dimensions and radii must be the current animated presentation, not its final target.
    /// Coordinates are top-center anchored inside the fixed transparent carrier window.
    func updatePresentation(size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat) {
        guard size.width.isFinite, size.height.isFinite, topRadius.isFinite, bottomRadius.isFinite else { return }
        self.presentationSize = CGSize(width: max(0, size.width), height: max(0, size.height))
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        reevaluate()
    }

    /// Coalesce render callbacks so an earlier queued frame cannot be applied after a newer one.
    /// This entry point can be called from an AnimatableModifier setter during rendering.
    nonisolated func enqueuePresentation(size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queuedPresentation = (size, topRadius, bottomRadius)
            guard !self.presentationFlushScheduled else { return }
            self.presentationFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentationFlushScheduled = false
                guard let presentation = self.queuedPresentation else { return }
                self.queuedPresentation = nil
                self.updatePresentation(size: presentation.0, topRadius: presentation.1,
                                        bottomRadius: presentation.2)
            }
        }
    }

    /// Call after an explicit menu/keyboard open, allowing time to reach the island.
    func keepExpandedForUserCommand(duration: TimeInterval = 3) {
        guard enabled else { return }
        commandGraceTask?.cancel()
        commandGraceUntil = ProcessInfo.processInfo.systemUptime + duration
        commandGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.commandGraceTask = nil
            self?.reevaluate()
        }
        reevaluate()
    }

    /// Also call when a SwiftUI popover or sharing interaction changes its keep-open state.
    func reevaluate() {
        guard let window else { return }
        let active = enabled && window.isVisible
        let point = NSEvent.mouseLocation
        let region = currentRegion
        let expanded = isExpanded()
        let now = ProcessInfo.processInfo.systemUptime
        refreshInputRouting(point: point, region: region, active: active)
        #if DEBUG
        let automaticHoverEnabled = active && !automaticHoverSuspendedForDiagnostics
        #else
        let automaticHoverEnabled = active
        #endif
        let action = machine.update(
            enabled: automaticHoverEnabled, expanded: expanded, inTrigger: region.containsTrigger(point),
            // Reaching for the floating control means leaving the painted shape. Counting it
            // as content keeps the island up long enough to actually press it, while staying
            // out of `inTrigger` so it can never open the island by itself.
            inVisibleContent: region.containsInteractiveContent(point),
            holdsOpen: currentHoldsOpen(now: now),
            now: now,
            closeTrigger: closeTrigger
        )
        updatePendingTask()
        switch action {
        case .open:
            open()
        case .close:
            close()
        case nil: break
        }
        // The action can synchronously hide the window or decline a state transition.
        // Refresh routing without recursively running the state machine or scheduling retries.
        if action != nil {
            refreshInputRouting(point: point, region: currentRegion, active: enabled && window.isVisible)
        }
    }

    /// Every reason the island must stay expanded while the pointer is away, in one place:
    /// a tracked `NSMenu`, the owner's own keep-open state, a recent explicit command, and
    /// the popover/pinned-page registry.
    private func currentHoldsOpen(now: TimeInterval) -> Bool {
        !trackedMenus.isEmpty || keepsOpen() || now < commandGraceUntil
            || NotchOpenHoldCenter.shared.isHoldingAgainstPointerExit
    }

    /// A click that lands away from the island collapses it, which is the only way out
    /// when the pointer alone cannot close it — either because the user chose
    /// `externalClickOnly`, or because a page is pinned open.
    ///
    /// Deliberately narrower than `currentHoldsOpen`: a pinned page must not survive an
    /// explicit dismissal, or the island would be stuck. A popover still wins, since its
    /// own frame sits outside the island and clicking it is not a dismissal.
    private func handlePotentialOutsideClick() {
        guard enabled, isExpanded(), let window, window.isVisible else { return }
        guard !NotchOpenHoldCenter.shared.isHoldingAgainstExplicitDismissal else { return }
        guard trackedMenus.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= commandGraceUntil, !keepsOpen() else { return }
        // The same region used for input routing, so a click the window actually swallowed
        // can never be judged to be outside it. `containsExpandedHover` rather than
        // `containsVisible` keeps the physical notch strip counted as inside.
        guard !currentRegion.containsExpandedHover(NSEvent.mouseLocation) else { return }
        // Never activates the window: closing must not steal key or main status.
        close()
        refreshInputRouting(point: NSEvent.mouseLocation, region: currentRegion,
                            active: enabled && window.isVisible)
    }

    private func refreshInputRouting(point: CGPoint, region: NotchHitRegion, active: Bool) {
        guard let window else { return }
        let acceptsInput = captures(point, region: region, active: active)
        let hovered = active && briefRowInteractive && isInBriefRow(point, region: region)
        if hovered != lastBriefHovered {
            lastBriefHovered = hovered
            briefHoverCallback?(hovered)
        }
        if window.ignoresMouseEvents == acceptsInput { window.ignoresMouseEvents = !acceptsInput }
    }

    private var currentRegion: NotchHitRegion {
        let frame = window?.frame ?? screen.frame
        let visibleFrame = CGRect(x: frame.midX - presentationSize.width / 2,
                                  y: frame.maxY - presentationSize.height,
                                  width: presentationSize.width, height: presentationSize.height)
        return NotchHitRegion(triggerRect: Self.triggerRect(for: screen), visibleFrame: visibleFrame,
                              topRadius: topRadius, bottomRadius: bottomRadius,
                              accessoryRects: accessoryVisible
                                  ? NotchAccessorySlot.allCases.map {
                                      NotchAccessoryControl.rect(visibleFrame: visibleFrame, slot: $0)
                                  } : [])
    }

    private static func triggerRect(for screen: NSScreen) -> CGRect {
        NotchHitRegion.triggerRect(screenFrame: screen.frame, safeTop: screen.safeAreaInsets.top,
                                  leftAuxiliaryWidth: screen.auxiliaryTopLeftArea?.width,
                                  rightAuxiliaryWidth: screen.auxiliaryTopRightArea?.width)
    }

    private func updatePendingTask() {
        let deadline = machine.pending?.deadline
        guard deadline != scheduledDeadline else { return }
        pendingTask?.cancel()
        pendingTask = nil
        scheduledDeadline = deadline
        guard let deadline else { return }
        let wait = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.pendingTask = nil
            self?.scheduledDeadline = nil
            self?.reevaluate()
        }
    }

    private func installObservers() {
        // Mouse observation does not request Accessibility/Input Monitoring permission.
        // In particular, no global key events are monitored or intercepted.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                           .otherMouseDragged, .leftMouseDown, .rightMouseDown,
                                           .otherMouseDown, .scrollWheel]
        func isMouseDown(_ type: NSEvent.EventType) -> Bool {
            type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.reevaluate()
            if isMouseDown(event.type) { self?.handlePotentialOutsideClick() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.reevaluate()
            if isMouseDown(event.type) { self?.handlePotentialOutsideClick() }
        }
        // No mouse event follows a hold being taken or released, so the state machine has
        // to be re-run explicitly or a released hold would leave the island open until the
        // pointer happens to move again. Each island subscribes for itself.
        NotchOpenHoldCenter.shared.changes
            .sink { [weak self] in MainActor.assumeIsolated { self?.reevaluate() } }
            .store(in: &observations)
        observeSettings()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                            queue: .main) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                self?.trackedMenus.insert(ObjectIdentifier(menu))
                self?.reevaluate()
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil,
                                            queue: .main) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                self?.trackedMenus.remove(ObjectIdentifier(menu))
                self?.reevaluate()
            }
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            })
        }
        observers.append(center.addObserver(forName: Notification.Name("com.boringNotch.sharingDidFinish"),
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        })
    }

    /// Debounced because dragging the delay slider republishes on every intermediate
    /// value, and each rebuild discards the dwell timer that is currently running.
    ///
    /// Shares `observations` with the hold subscription, so it must not clear the set;
    /// `stopObservers` owns tearing every subscription down together.
    private func observeSettings() {
        Defaults.publisher(keys: .notchCloseDelay, .notchCloseTriggerMode)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applySettings() }
            }
            .store(in: &observations)
    }

    private func applySettings() {
        let delay = Defaults[.notchCloseDelay]
        let trigger = Defaults[.notchCloseTriggerMode].machineTrigger
        closeTrigger = trigger
        if machine.closeDelay != delay {
            machine = NotchHoverStateMachine(openDelay: machine.openDelay, closeDelay: delay)
            scheduledDeadline = nil
            pendingTask?.cancel()
            pendingTask = nil
        }
        reevaluate()
    }

    private func stopObservers() {
        observations.removeAll()
        pendingTask?.cancel()
        pendingTask = nil
        commandGraceTask?.cancel()
        commandGraceTask = nil
        scheduledDeadline = nil
        commandGraceUntil = 0
        machine.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        trackedMenus.removeAll()
        if lastBriefHovered { lastBriefHovered = false; briefHoverCallback?(false) }
    }

    #if DEBUG
    struct DiagnosticSnapshot: Codable {
        let uptime: TimeInterval
        let windowFrame: CGRect
        let visibleFrame: CGRect
        let physicalTrigger: CGRect
        let pointer: CGPoint
        let topRadius: CGFloat
        let bottomRadius: CGFloat
        let expanded: Bool
        let visible: Bool
        let keyWindow: Bool
        let mainWindow: Bool
        let ignoresMouseEvents: Bool
        let expectedIgnoresMouseEvents: Bool
        let observersInstalled: Bool
        let automaticHoverSuspended: Bool
    }

    /// Pauses automatic state changes during an explicit open/close diagnostic sequence.
    /// No mouse input is created, and input routing continues to follow the actual pointer.
    func setAutomaticHoverSuspendedForDiagnostics(_ suspended: Bool) {
        automaticHoverSuspendedForDiagnostics = suspended
        reevaluate()
    }

    func diagnosticSnapshot() -> DiagnosticSnapshot? {
        guard let window else { return nil }
        let region = currentRegion
        let pointer = NSEvent.mouseLocation
        return DiagnosticSnapshot(
            uptime: ProcessInfo.processInfo.systemUptime,
            windowFrame: window.frame, visibleFrame: region.visibleFrame, physicalTrigger: region.triggerRect,
            pointer: pointer, topRadius: topRadius, bottomRadius: bottomRadius,
            expanded: isExpanded(), visible: window.isVisible,
            keyWindow: window.isKeyWindow, mainWindow: window.isMainWindow,
            ignoresMouseEvents: window.ignoresMouseEvents,
            expectedIgnoresMouseEvents: !captures(pointer, region: region, active: enabled && window.isVisible),
            observersInstalled: localMonitor != nil && globalMonitor != nil,
            automaticHoverSuspended: automaticHoverSuspendedForDiagnostics
        )
    }

    /// Pure hit query for diagnostic sample points; does not move or synthesize the cursor.
    func diagnosticCapturesPoint(_ point: CGPoint) -> Bool {
        captures(point, region: currentRegion, active: enabled && window?.isVisible == true)
    }
    #endif
}
