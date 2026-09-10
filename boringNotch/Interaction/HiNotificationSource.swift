import AppKit
import Combine
import Defaults
@preconcurrency import ApplicationServices

enum HiNotificationSourceStatus: String, Equatable {
    case disabled, notInstalled, paused, accessibilityRequired, waitingForNotificationCenter, waitingForBanner, receivedBanner, mirrorOnly, unsupportedStructure

    var labelKey: String {
        switch self {
        case .disabled: return "Notifications are off for this app."
        case .notInstalled: return "This app is not installed on this Mac."
        case .waitingForBanner: return "Waiting for a real desktop banner; delivery is not yet verified."
        case .receivedBanner: return "A real desktop banner was received in this session. Original banners remain visible."
        case .paused: return "App notifications are paused while the island is unavailable."
        case .accessibilityRequired: return "Accessibility access is required to observe app banners."
        case .waitingForNotificationCenter: return "Waiting for Notification Center."
        case .mirrorOnly: return "Observer running; mirrors recognized app banners only. Original banners remain visible."
        case .unsupportedStructure: return "This notification layout is not supported. Original banners remain visible."
        }
    }
}

/// Experimental UI observer, not a notification delivery interceptor. No database, private
/// window APIs, notification dismissal, text logging, or automatic permissions prompt.
@MainActor
final class HiNotificationManager: ObservableObject {
    static let shared = HiNotificationManager()
    static let bundleID = HiNotificationSourceEvidence.hiBundleID
    @Published private(set) var current: HiNotificationNotice?
    @Published private(set) var status: HiNotificationSourceStatus = .disabled
    @Published private(set) var diagnosticsSummary = "AX: false · Observer: false · Host: 0 · Windows: 0 · Cards: 0 · Matched: 0 · Delivered: 0 · Result: not_started · Position: unverified"
    @Published private(set) var structureDiagnosticsSummary = "Structure-only diagnostic has not run."
    @Published private(set) var isSamplingStructure = false
    @Published private(set) var structureSamplesSummary = ""
    /// Deliberately false until a separate native verification establishes safe move/restore.
    let originalBannerHidingSupported = false
    @Published private(set) var sources: [AppNotificationSourceInfo] = []
    private var deliveredSources = Set<String>()
    private var configuredPolicy = AppNotificationPolicy(allowsUnconfiguredSources: false)
    private let catalog = InstalledApplicationCatalog.shared
    var enabled: Bool { AppNotificationSourcePreferences.enabledPolicy().allowsAnySource }

    func isEnabled(_ bundleID: String) -> Bool { AppNotificationSourcePreferences.enabledPolicy().allows(bundleID) }
    func isDetailed(_ bundleID: String) -> Bool { AppNotificationSourcePreferences.detailPolicy().allows(bundleID) }
    func setEnabled(_ enabled: Bool, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        Defaults[.enabledAppNotificationSources][bundleID] = enabled
        refresh()
    }
    func setDetailed(_ detailed: Bool, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        Defaults[.detailedAppNotificationSources][bundleID] = detailed
        refresh()
    }
    func status(for source: AppNotificationSourceInfo) -> HiNotificationSourceStatus {
        guard source.isInstalled else { return .notInstalled }
        guard isEnabled(source.id) else { return .disabled }
        if status == .mirrorOnly {
            return deliveredSources.contains(source.id) ? .receivedBanner : .waitingForBanner
        }
        return status
    }
    func icon(for notice: HiNotificationNotice) -> NSImage? { icon(for: notice.sourceBundleID) }
    func icon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty else { return nil }
        return catalog.icon(for: bundleID)
    }
    func displayText(for notice: HiNotificationNotice) -> String {
        let name = notice.sourceName.isEmpty
            ? (Defaults[.seenAppNotificationSources][notice.sourceBundleID] ?? L("App"))
            : notice.sourceName
        let details = [notice.sender, notice.body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        // Never infer completion from an app being an AI tool. The actual notification may
        // instead ask for input, report an error, or carry an unrelated update.
        let prefix = notice.count > 1
            ? String(format: L("%@ · %d new notifications"), name, notice.count)
            : String(format: L("%@ has a new notification"), name)
        return details.isEmpty ? prefix : "\(name) · \(details)" + (notice.count > 1 ? " (\(notice.count))" : "")
    }
    var originalBannerHidingRequested: Bool { Defaults[.hideOriginalHiBanner] }

    private var state = HiNotificationState()
    private var subscriptions = Set<AnyCancellable>()
    private var observer: AXObserver?
    private var host: AXUIElement?
    private var hostPID: pid_t = 0
    private var generation = 0
    private var started = false
    private var scanTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var cardTracker = HiAXCardTracker()
    private var awaitingBaseline = true
    private var latestAction: ActionReference?
    private var lastWindowCount = 0
    private var lastCardCount = 0
    private var lastMatchedCount = 0
    private var deliveryCount = 0
    private var lastResult = "not_started"
    private var lastPositionSettable: Bool?
    private var lastKnownFields = Set<String>()
    private var readDeadline: TimeInterval?
    private var readHadFailure = false
    private var diagnosticStructure = HiAXDiagnosticStructure()
    private var diagnosticVisitedElements = Set<CFHashCode>()
    private var observerErrorCounts: [Int32: Int] = [:]
    private var observerEventCounts: [String: Int] = [:]
    private var lastObserverEventAt: TimeInterval?
    private var structureFingerprint = ""
    private var structureSamplingTask: Task<Void, Never>?
    private var structureSamplingGeneration: UUID?
    private var structureSamplingBuffer: StructureSamplingBuffer?

    private struct ActionReference {
        let card: AXUIElement
        let window: AXUIElement
        let identity: String
        let fingerprint: String
        let hostPID: pid_t
    }

    private struct Capture {
        let candidate: HiNotificationCandidate
        let fingerprint: String
        let hasPayload: Bool
        let card: AXUIElement
        let window: AXUIElement
        var content: HiAXCardContent {
            HiAXCardContent(cardID: candidate.identity, fingerprint: fingerprint, hasPayload: hasPayload)
        }
    }

    private struct CaptureSnapshot {
        let cards: [Capture]
        let visibleCardIDs: Set<String>
        let complete: Bool
    }

    private init() { start() }

    func start() {
        guard !started else { refresh(); return }
        started = true
        AppNotificationSourcePreferences.migrateLegacyHiKeysIfNeeded()
        catalog.start()
        Defaults.publisher(.enabledAppNotificationSources).sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &subscriptions)
        Defaults.publisher(.detailedAppNotificationSources).sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &subscriptions)
        Defaults.publisher(.appNotificationAllowsNewSources).sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &subscriptions)
        Defaults.publisher(.appNotificationDetailsNewSources).sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &subscriptions)
        Defaults.publisher(.seenAppNotificationSources).sink { [weak self] _ in
            Task { @MainActor in self?.rebuildSources() }
        }.store(in: &subscriptions)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }.store(in: &subscriptions)
        }
        refresh()
    }

    /// The settings list is whatever has actually notified this Mac, newest names included.
    private func rebuildSources() {
        let seen = Defaults[.seenAppNotificationSources]
        let rebuilt = seen.map { id, name in
            AppNotificationSourceInfo(id: id, name: name, applicationURL: catalog.bundleURL(for: id))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if sources != rebuilt { sources = rebuilt }
    }

    func setApplicationAvailable(_ available: Bool) {
        state.setApplicationAvailable(available)
        if !available { latestAction = nil; stopStructureSampling() }
        publish()
        refresh()
    }

    /// Passive permission check. The Settings permission button is owned by the app.
    func refresh() {
        defer { updateDiagnostics() }
        objectWillChange.send()
        rebuildSources()
        let enabled = AppNotificationSourcePreferences.enabledPolicy()
        state.configure(enabled: enabled, detailed: AppNotificationSourcePreferences.detailPolicy())
        if configuredPolicy != enabled {
            // Enabling another source must not replay its already-visible notification.
            configuredPolicy = enabled
            stopObserverOnly()
        }
        if state.current == nil { latestAction = nil }
        publish()
        guard enabled.allowsAnySource else { stopObserving(); status = .disabled; lastResult = "disabled"; return }
        guard state.applicationAvailable else { stopObserving(); status = .paused; lastResult = "unavailable"; return }
        ensureHealthCheck()
        guard AXIsProcessTrusted() else {
            stopStructureSampling()
            stopObserverOnly()
            state.dismiss(); latestAction = nil; publish()
            status = .accessibilityRequired
            lastResult = "accessibility_required"
            return
        }
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            stopObserverOnly()
            state.dismiss(); latestAction = nil; publish()
            status = .waitingForNotificationCenter
            lastResult = "notification_center_absent"
            return
        }
        if observer != nil, process.processIdentifier == hostPID { return }
        stopObserverOnly()
        state.dismiss(); latestAction = nil; publish()
        hostPID = process.processIdentifier
        let application = AXUIElementCreateApplication(hostPID)
        // Bound a wedged system AX server's individual calls; this is a read timeout.
        AXUIElementSetMessagingTimeout(application, 0.05)
        var result: AXObserver?
        let creationResult = AXObserverCreate(hostPID, hiNotificationAXCallback, &result)
        recordObserverError(creationResult)
        guard creationResult == .success, let result else {
            status = .unsupportedStructure
            lastResult = "observer_creation_failed"
            return
        }
        let registered = [kAXWindowCreatedNotification, kAXCreatedNotification].map {
            AXObserverAddNotification(result, application, $0 as CFString, nil)
        }
        registered.forEach(recordObserverError)
        guard registered.contains(.success) else {
            status = .unsupportedStructure; lastResult = "events_not_supported"; return
        }
        // Some OS versions support this app-level callback; a confirmed empty snapshot then
        // retires card identities before the system can reuse the window/element handles.
        recordObserverError(AXObserverAddNotification(result, application, kAXUIElementDestroyedNotification as CFString, nil))
        observer = result
        host = application
        // A newly enabled/restored observer must not replay banners already on the screen.
        let baseline = captures(includeDetails: false)
        cardTracker.beginBaseline(baseline.cards.map(\.content), now: ProcessInfo.processInfo.systemUptime)
        awaitingBaseline = !baseline.complete
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
        status = .mirrorOnly
    }

    /// Operational observer diagnostics. This path does read banner descriptions and payload
    /// values for recognition/fingerprinting, though it never publishes or logs their text.
    /// Use refreshStructureDiagnostics() when the diagnostic must not read notification text.
    func refreshDiagnostics() {
        refresh()
        if observer != nil { _ = captures(includeDetails: false) }
        updateDiagnostics()
    }

    /// Strict structural probe. This intentionally does not call refresh()/captures(), which
    /// can establish an observer baseline by reading notification descriptions and fields.
    /// It does not alter observation, actions, permissions, delivery, or any system window.
    func refreshStructureDiagnostics() {
        let trusted = AXIsProcessTrusted()
        var report = NotificationStructureDiagnostics()
        guard IslandVisibility.shared.isAvailable, trusted,
              let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            structureFingerprint = "AX: \(trusted) · Island available: \(IslandVisibility.shared.isAvailable) · Notification Center unavailable · \(observerStructureSignature)"
            structureDiagnosticsSummary = structureFingerprint + " · " + report.summary
            return
        }
        let application = AXUIElementCreateApplication(process.processIdentifier)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var visited = Set<CFHashCode>()

        // Never read identifier/description/title/value text. Position is used only for
        // the on-screen boolean and is never placed in diagnostic output.
        func read(_ element: AXUIElement, _ attribute: String) -> (CFTypeRef?, AXError) {
            guard [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute, kAXWindowsAttribute,
                   kAXSizeAttribute, kAXPositionAttribute, kAXFocusedWindowAttribute].contains(attribute) else { return (nil, .attributeUnsupported) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { report.truncated = true; return (nil, .cannotComplete) }
            AXUIElementSetMessagingTimeout(element, 0.025)
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
            report.recordError(Int(error.rawValue))
            return (error == .success ? result : nil, error)
        }
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? { read(element, attribute).0 }
        func size(_ element: AXUIElement) -> CGSize? {
            guard let raw = value(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            var result = CGSize.zero
            guard AXValueGetValue(raw as! AXValue, .cgSize, &result), result.width.isFinite, result.height.isFinite else { return nil }
            return result
        }
        func onScreen(_ element: AXUIElement, size: CGSize?) -> Bool? {
            guard let size, let raw = value(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero
            guard AXValueGetValue(raw as! AXValue, .cgPoint, &origin), origin.x.isFinite, origin.y.isFinite else { return nil }
            return isOnScreen(CGRect(origin: origin, size: size))
        }
        struct Node {
            let element: AXUIElement
            let number: Int
            let parent: Int?
            let depth: Int
            let role: String?
            let subrole: String?
            let attributes: [String]
        }
        func visit(_ element: AXUIElement, parent: Int?, depth: Int, nodes: inout [Node]) {
            guard depth <= 10, visited.count < 160, ProcessInfo.processInfo.systemUptime < deadline else {
                report.truncated = true; return
            }
            guard visited.insert(CFHash(element)).inserted else { return }
            let number = visited.count - 1
            let role = value(element, kAXRoleAttribute) as? String
            let subrole = value(element, kAXSubroleAttribute) as? String
            var names: CFArray?
            if ProcessInfo.processInfo.systemUptime < deadline {
                let error = AXUIElementCopyAttributeNames(element, &names)
                report.recordError(Int(error.rawValue))
            } else { report.truncated = true }
            let attributes = names as? [String] ?? []
            report.recordNode(role: role, subrole: subrole, attributeNames: attributes)
            nodes.append(Node(element: element, number: number, parent: parent, depth: depth,
                              role: role, subrole: subrole, attributes: attributes))
            for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                visit(child, parent: number, depth: depth + 1, nodes: &nodes)
            }
        }
        let (focusedWindow, focusedError) = read(application, kAXFocusedWindowAttribute)
        let windows = value(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if windows.count > 16 { report.truncated = true }
        for (index, window) in windows.prefix(16).enumerated() {
            let windowSize = size(window)
            if let windowSize { report.recordWindowSize(width: windowSize.width, height: windowSize.height) }
            var nodes: [Node] = []
            visit(window, parent: nil, depth: 0, nodes: &nodes)
            let cards = nodes.filter { Self.bannerSubroles.contains($0.subrole ?? "") }
            guard !cards.isEmpty, let windowNode = nodes.first else { continue }
            func details(_ node: Node, measured: CGSize?) -> NotificationStructureDiagnostics.BannerNode {
                NotificationStructureDiagnostics.BannerNode(number: node.number, parent: node.parent, depth: node.depth,
                    role: node.role, subrole: node.subrole, width: measured.map { Double($0.width) },
                    height: measured.map { Double($0.height) }, onScreen: onScreen(node.element, size: measured),
                    attributeNames: node.attributes)
            }
            let focused: Bool? = focusedError == .success || focusedError == .noValue
                ? focusedWindow.map { CFEqual($0, window) } ?? false : nil
            report.recordBannerWindow(number: index, window: details(windowNode, measured: windowSize), focused: focused,
                bannerCount: cards.count, stackCount: nodes.filter { Self.stackSubroles.contains($0.subrole ?? "") }.count,
                cards: cards.prefix(32).map { details($0, measured: size($0.element)) })
        }
        structureFingerprint = "AX: true · Windows: \(windows.count) · \(observerStructureSignature) · \(report.summary)"
        structureDiagnosticsSummary = "AX: true · Windows: \(windows.count) · \(observerStructureSummary) · \(report.summary)"
    }

    /// Explicit, bounded sampling of the strict structural probe only. Starting again
    /// replaces old in-memory evidence. No operational refresh or capture is triggered.
    func startStructureSampling() {
        stopStructureSampling()
        structureSamplesSummary = ""
        let startedAt = ProcessInfo.processInfo.systemUptime
        structureSamplingBuffer = StructureSamplingBuffer(startedAt: startedAt)
        guard IslandVisibility.shared.isAvailable, AXIsProcessTrusted() else {
            structureSamplesSummary = L("Structure sampling requires Accessibility access and a visible, unlocked island.")
            return
        }
        let generation = UUID()
        structureSamplingGeneration = generation
        isSamplingStructure = true
        structureSamplingTask = Task { @MainActor [weak self] in
            for index in 0..<StructureSamplingBuffer.sampleLimit {
                let target = startedAt + Double(index)
                let delay = target - ProcessInfo.processInfo.systemUptime
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                }
                guard let self, !Task.isCancelled, self.structureSamplingGeneration == generation else { break }
                let sampledAt = ProcessInfo.processInfo.systemUptime
                guard IslandVisibility.shared.isAvailable, AXIsProcessTrusted(),
                      self.structureSamplingBuffer?.isExpired(at: sampledAt) == false else { break }
                self.refreshStructureDiagnostics()
                // Time since the last callback is not a structural change; otherwise every
                // unchanged second would defeat deduplication. Callback counts still matter.
                if self.structureSamplingBuffer?.record(at: sampledAt, fingerprint: self.structureFingerprint,
                                                        summary: self.structureDiagnosticsSummary) == true {
                    self.structureSamplesSummary = self.structureSamplingBuffer?.summary ?? ""
                }
            }
            guard let self, self.structureSamplingGeneration == generation else { return }
            self.structureSamplingTask = nil
            self.structureSamplingGeneration = nil
            self.isSamplingStructure = false
        }
    }

    func stopStructureSampling() {
        structureSamplingGeneration = nil
        structureSamplingTask?.cancel()
        structureSamplingTask = nil
        isSamplingStructure = false
    }

    private func recordObserverError(_ error: AXError) {
        guard error != .success else { return }
        observerErrorCounts[error.rawValue] = min(999_999, (observerErrorCounts[error.rawValue] ?? 0) + 1)
    }

    private var observerStructureSignature: String {
        let events = observerEventCounts.keys.sorted().map { "\($0)=\(observerEventCounts[$0] ?? 0)" }.joined(separator: ",")
        let errors = observerErrorCounts.keys.sorted().map { "\($0)=\(observerErrorCounts[$0] ?? 0)" }.joined(separator: ",")
        return "Observer: \(observer != nil) · Callbacks: [\(events)] · Observer AX errors: [\(errors)]"
    }

    private var observerStructureSummary: String {
        let age = lastObserverEventAt.map { String(Int(max(0, ProcessInfo.processInfo.systemUptime - $0))) + "s" } ?? "never"
        return observerStructureSignature + " · Last callback: " + age
    }

    /// Called only by the shared presentation coordinator; never closes a system notification.
    func dismiss() {
        state.dismiss()
        latestAction = nil
        publish()
    }

    /// Original actions are attempted only while the same, unambiguous live card still exists.
    /// If it expired, opening the attributed application is the only fallback; no guessed deep links or UI automation.
    func clickLatest() {
        guard enabled, state.applicationAvailable, let notice = current, isEnabled(notice.sourceBundleID) else { return }
        var openedOriginal = false
        if AXIsProcessTrusted(), let action = latestAction, action.hostPID == hostPID,
           let live = captures(includeDetails: false).cards.first(where: {
               $0.candidate.identity == action.identity && $0.fingerprint == action.fingerprint
           }),
           CFEqual(live.card, action.card), CFEqual(live.window, action.window),
           actions(of: live.card).contains(kAXPressAction as String) {
            openedOriginal = AXUIElementPerformAction(live.card, kAXPressAction as CFString) == .success
        }
        dismiss()
        if !openedOriginal, let url = catalog.bundleURL(for: notice.sourceBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    fileprivate func notificationCenterChanged(_ element: AXUIElement, from sourceObserver: AXObserver, notification: String) {
        guard let observer, CFEqual(observer, sourceObserver), enabled, state.applicationAvailable else { return }
        // Only the fixed notification names registered above enter diagnostic output.
        if [kAXWindowCreatedNotification, kAXCreatedNotification, kAXUIElementDestroyedNotification].contains(notification) {
            observerEventCounts[notification] = min(999_999, (observerEventCounts[notification] ?? 0) + 1)
            lastObserverEventAt = ProcessInfo.processInfo.systemUptime
        }
        var pid: pid_t = 0
        if notification != kAXUIElementDestroyedNotification as String {
            guard AXUIElementGetPid(element, &pid) == .success, pid == hostPID else { return }
        }
        scanTask?.cancel()
        let expectedGeneration = generation
        scanTask = Task { @MainActor [weak self] in
            // AX window creation can precede the banner's attributed subtree.
            for delay in [0.1, 0.15, 0.35] {
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                guard let self, !Task.isCancelled, self.generation == expectedGeneration,
                      self.enabled, self.state.applicationAvailable else { return }
                self.scanNewBanners()
            }
        }
    }

    private func scanNewBanners() {
        guard AXIsProcessTrusted() else { refresh(); return }
        let snapshot = captures(includeDetails: true)
        let now = ProcessInfo.processInfo.systemUptime
        guard !awaitingBaseline else {
            cardTracker.beginBaseline(snapshot.cards.map(\.content), now: now)
            awaitingBaseline = !snapshot.complete
            return
        }
        cardTracker.reconcileVisibleCards(snapshot.visibleCardIDs, snapshotComplete: snapshot.complete)
        for capture in snapshot.cards {
            let change = cardTracker.observe(capture.content, now: now)
            let eventID: String
            switch change {
            case .ignored: continue
            case let .new(id):
                eventID = id
                let candidate = HiNotificationCandidate(identity: id, sender: capture.candidate.sender, body: capture.candidate.body, sourceBundleID: capture.candidate.sourceBundleID)
                guard state.receive(candidate, now: now) else { continue }
                deliveryCount += 1
                deliveredSources.insert(capture.candidate.sourceBundleID)
                status = .mirrorOnly
            case let .update(id):
                eventID = id
                guard state.current?.id == id else { continue }
                state.refreshCurrentContent(HiNotificationCandidate(identity: id, sender: capture.candidate.sender, body: capture.candidate.body, sourceBundleID: capture.candidate.sourceBundleID))
            }
            if state.current?.id == eventID {
                latestAction = ActionReference(card: capture.card, window: capture.window,
                                              identity: capture.candidate.identity,
                                              fingerprint: capture.fingerprint, hostPID: hostPID)
                publish()
            }
        }
        updateDiagnostics()
    }

    private func captures(includeDetails: Bool) -> CaptureSnapshot {
        guard let host else { return CaptureSnapshot(cards: [], visibleCardIDs: [], complete: false) }
        readDeadline = ProcessInfo.processInfo.systemUptime + 0.2
        readHadFailure = false
        defer { readDeadline = nil }
        let allWindows = elements(host, kAXWindowsAttribute)
        let windows = Array(allWindows.prefix(16))
        if allWindows.count > 16 { readHadFailure = true }
        lastWindowCount = windows.count
        lastCardCount = 0; lastMatchedCount = 0; lastPositionSettable = nil
        diagnosticStructure = HiAXDiagnosticStructure()
        diagnosticVisitedElements.removeAll(keepingCapacity: true)
        lastKnownFields.removeAll(keepingCapacity: true)
        lastResult = windows.isEmpty ? "no_visible_windows" : "no_recognized_app_card"
        defer { updateDiagnostics() }
        var focused: CFTypeRef?
        recordReadResult(AXUIElementCopyAttributeValue(host, kAXFocusedWindowAttribute as CFString, &focused))
        var visibleIDs = Set<String>()
        let captured: [Capture] = windows.compactMap { window in
            var nodes: [AXUIElement] = []
            guard collect(window, depth: 0, into: &nodes) else { readHadFailure = true; return nil }
            guard let windowFrame = frame(of: window) else { readHadFailure = true; return nil }
            guard isOnScreen(windowFrame) else { return nil }
            // Keep a baseline while its AX element still exists, even during transient
            // subrole/attribution changes. Never parse an opened Notification Center panel.
            visibleIDs.formUnion(nodes.map { cardIdentity(window: window, card: $0) })
            if let focused, CFEqual(focused, window) {
                lastResult = "focused_window_excluded"
                diagnosticStructure.recordSource(.unparsed)
                return nil
            }
            let allCards = nodes.filter { Self.bannerSubroles.contains(string($0, kAXSubroleAttribute) ?? "") }
            let grouped = nodes.contains { Self.stackSubroles.contains(string($0, kAXSubroleAttribute) ?? "") }
            lastCardCount += allCards.count
            if allCards.isEmpty { lastResult = "no_supported_banner_subrole" }
            if allCards.isEmpty { diagnosticStructure.recordSource(.unparsed) }
            // Several cards or a stack used to discard the whole window. Take the topmost card
            // instead: losing the ones underneath is far better than losing the newest message.
            if grouped || allCards.count > 1 { lastResult = "multiple_cards_took_topmost" }
            guard let card = Self.topmostCard(among: allCards, position: { frame(of: $0)?.origin }),
                  let frame = frame(of: card), frame.width >= 140, frame.width <= 700,
                  frame.height >= 35, frame.height <= 350, isOnScreen(frame),
                  let description = attributedDescription(card),
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if !allCards.isEmpty { diagnosticStructure.recordSource(.unparsed) }
                return nil
            }
            let resolved = catalog.index.resolve(bannerDescription: description)
            if resolved == nil { catalog.refreshIfStale() }
            let bundleID = resolved?.bundleID ?? ""
            let sourceName = resolved?.displayName ?? description
            guard isEnabled(bundleID) else {
                diagnosticStructure.recordSource(.other)
                return nil
            }
            if let resolved { AppNotificationSourcePreferences.remember(bundleID: resolved.bundleID, displayName: resolved.displayName) }
            diagnosticStructure.recordSource(bundleID == Self.bundleID ? .hi : .other)
            lastMatchedCount += 1
            lastResult = "recognized_app_card"
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success {
                lastPositionSettable = settable.boolValue
            }
            var cardNodes: [AXUIElement] = []
            guard collect(card, depth: 0, into: &cardNodes) else { return nil }
            // Hasher is randomized per process. Neither this token nor raw text is logged/saved.
            let identity = cardIdentity(window: window, card: card)
            var digest = Hasher()
            digest.combine(identity); digest.combine(bundleID)
            var sender: String?
            var bodyParts: [String] = []
            var hasPayload = false
            var seenFields = Set<String>()
            for node in cardNodes where string(node, kAXRoleAttribute) == kAXStaticTextRole as String {
                guard let value = string(node, kAXValueAttribute), !value.isEmpty else { continue }
                let field = (string(node, kAXIdentifierAttribute) ?? "").lowercased()
                guard ["title", "subtitle", "body"].contains(field) else { continue }
                lastKnownFields.insert(field)
                digest.combine(field); digest.combine(value)
                if field == "body", !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasPayload = true }
                guard includeDetails, isDetailed(bundleID), seenFields.insert(field + "\u{0}" + value).inserted else { continue }
                // No heuristic slicing of arbitrary localized accessibility descriptions.
                // Unknown layouts retain a useful private notice instead of inventing a sender.
                if field == "title" { sender = value }
                else if field == "body" || field == "subtitle" { bodyParts.append(value) }
            }
            return Capture(candidate: HiNotificationCandidate(identity: identity, sender: sender,
                           body: bodyParts.isEmpty ? nil : bodyParts.joined(separator: " "),
                           sourceBundleID: bundleID, sourceName: sourceName),
                           fingerprint: String(digest.finalize(), radix: 16),
                           hasPayload: hasPayload,
                           card: card, window: window)
        }
        let complete = !readHadFailure && withinReadBudget
        // Partial AX payloads cannot drive fingerprint changes or original-action validation.
        return CaptureSnapshot(cards: complete ? captured : [], visibleCardIDs: visibleIDs, complete: complete)
    }

    private static func topmostCard(among cards: [AXUIElement],
                                    position: (AXUIElement) -> CGPoint?) -> AXUIElement? {
        guard let index = BannerCardSelection.topmostIndex(positions: cards.map(position)) else { return nil }
        return cards[index]
    }

    private static let bannerSubroles: Set<String> = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]
    private static let stackSubroles: Set<String> = ["AXNotificationCenterBannerStack", "AXNotificationCenterAlertStack"]

    private func publish() { if current != state.current { current = state.current } }

    private func updateDiagnostics() {
        let position = lastPositionSettable.map { String($0) } ?? "unverified"
        let fields = lastKnownFields.sorted().joined(separator: ",")
        let summary = "AX: \(AXIsProcessTrusted()) · Observer: \(observer != nil) · Host: \(hostPID) · Windows: \(lastWindowCount) · Cards: \(lastCardCount) · Matched: \(lastMatchedCount) · Delivered: \(deliveryCount) · Result: \(lastResult) · Fields: \(fields) · Position: \(position) (hide unverified) · \(diagnosticStructure.summary)"
        if diagnosticsSummary != summary { diagnosticsSummary = summary }
    }

    private func ensureHealthCheck() {
        guard healthTask == nil else { return }
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, self.enabled, self.state.applicationAvailable else { return }
                self.refresh()
            }
        }
    }

    private func stopObserving() {
        healthTask?.cancel(); healthTask = nil
        stopObserverOnly()
        latestAction = nil
    }

    private func stopObserverOnly() {
        generation &+= 1
        scanTask?.cancel(); scanTask = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; host = nil; hostPID = 0
        cardTracker.clear()
        awaitingBaseline = true
    }

    private func collect(_ element: AXUIElement, depth: Int, into nodes: inout [AXUIElement]) -> Bool {
        guard depth <= 10, nodes.count < 160, withinReadBudget else { return false }
        nodes.append(element)
        if diagnosticVisitedElements.count < 2560, diagnosticVisitedElements.insert(CFHash(element)).inserted {
            diagnosticStructure.record(role: string(element, kAXRoleAttribute), subrole: string(element, kAXSubroleAttribute))
        }
        for child in elements(element, kAXChildrenAttribute) {
            guard collect(child, depth: depth + 1, into: &nodes) else { return false }
        }
        return true
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard prepareRead(element) else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        recordReadResult(result)
        guard result == .success else { return nil }
        return value as? String
    }

    private func attributedDescription(_ element: AXUIElement) -> String? {
        guard prepareRead(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXAttributedDescription" as CFString, &value) == .success,
              let value else { return nil }
        if let text = value as? NSAttributedString { return text.string }
        return value as? String
    }

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard prepareRead(element) else { return [] }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        recordReadResult(result)
        if attribute == kAXWindowsAttribute, result != .success { readHadFailure = true }
        guard result == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func actions(of element: AXUIElement) -> [String] {
        guard prepareRead(element) else { return [] }
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard prepareRead(element) else { return nil }
        var originValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &originValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let originValue, let sizeValue,
              CFGetTypeID(originValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(originValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func isOnScreen(_ frame: CGRect) -> Bool {
        // AX uses global top-left coordinates, unlike AppKit's bottom-left screen frames.
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.contains { screen in
            let axFrame = CGRect(x: screen.frame.minX, y: desktopTop - screen.frame.maxY,
                                 width: screen.frame.width, height: screen.frame.height)
            return axFrame.intersection(frame).width >= frame.width * 0.5 &&
                   axFrame.intersection(frame).height >= frame.height * 0.5
        }
    }

    private var withinReadBudget: Bool {
        guard let readDeadline else { return true }
        return ProcessInfo.processInfo.systemUptime < readDeadline
    }

    private func prepareRead(_ element: AXUIElement) -> Bool {
        guard withinReadBudget else {
            lastResult = "ax_read_budget_exceeded"; readHadFailure = true; return false
        }
        AXUIElementSetMessagingTimeout(element, 0.05)
        return true
    }

    private func recordReadResult(_ result: AXError) {
        if result == .cannotComplete || result == .invalidUIElement || result == .apiDisabled {
            readHadFailure = true
        }
    }

    /// Real banner cards expose a per-notification UUID in AXIdentifier. Every banner shares one
    /// full-screen Notification Center window, so CFHash(window)/CFHash(card) get reused and can
    /// alias a new notification onto a retired card. Prefer the system's own identity when present.
    private func cardIdentity(window: AXUIElement, card: AXUIElement) -> String {
        if let identifier = string(card, kAXIdentifierAttribute as String), UUID(uuidString: identifier) != nil {
            return identifier
        }
        var hasher = Hasher()
        hasher.combine(hostPID); hasher.combine(CFHash(window)); hasher.combine(CFHash(card))
        return String(hasher.finalize(), radix: 16)
    }
}

private func hiNotificationAXCallback(_ observer: AXObserver, _ element: AXUIElement,
                                      _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    Task { @MainActor in
        HiNotificationManager.shared.notificationCenterChanged(element, from: observer, notification: notification as String)
    }
}
