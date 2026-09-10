// Derived from boring.notch v2.7.3, GPL-3.0. Custom lifecycle for 工位充电岛.
import AppKit
import Combine
import CoreGraphics
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var visibility = IslandVisibility.shared
    @ObservedObject private var language = AppLanguage.shared
    @ObservedObject private var capture = CaptureTools.shared
    @Default(.menubarIcon) private var showMenuBarIcon

    var body: some Scene {
        // Temporary capture controls must not write back to the user's saved visibility.
        MenuBarExtra(isInserted: .constant(showMenuBarIcon || capture.isBusy)) {
            islandCommands
        } label: {
            Image(nsImage: PotatoStatusIcon.image)
                .renderingMode(.template)
                .accessibilityLabel("工位充电岛")
        }
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(L("Settings…")) { SettingsWindowController.shared.showWindow() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandMenu(L("Island")) { islandCommands }
            }
    }

    @ViewBuilder private var islandCommands: some View {
        if capture.isRecording {
            Button(L("Stop recording")) { capture.stopRecording() }
            Divider()
        } else if capture.isBusy {
            Button(L("Cancel capture")) { capture.cancelCapture() }
            Divider()
        }
        Button(L("Open island")) { appDelegate.expandIsland() }
        Button(visibility.isHidden ? L("Show island") : L("Hide island")) { visibility.isHidden.toggle() }
        Divider()
        Button(L("Settings…")) { SettingsWindowController.shared.showWindow() }
        #if DEBUG
        Button(L("Animation diagnostics (20 + 10 cycles)")) { appDelegate.runInteractionCheck() }
            .disabled(visibility.isChecking)
        #endif
        Divider()
        Button(L("Quit Recharge Island")) { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct Entry {
        let window: NSWindow
        let model: BoringViewModel
        let pointer: NotchPointerCoordinator
    }
    private var entries: [String: Entry] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private let coordinator = BoringViewCoordinator.shared
    private let visibility = IslandVisibility.shared
    private var guiSession = GUISessionAvailability()
    private var focusReminderTask: Task<Void, Never>?
    private var waitsForCaptureBeforeQuitting = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CaptureTools.shared.isBusy else { return .terminateNow }
        waitsForCaptureBeforeQuitting = true
        DispatchQueue.main.async { CaptureTools.shared.cancelCapture() }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showSettingsOnLaunch = !Defaults[.menubarIcon] && !LaunchAtLogin.wasLaunchedAtLogin
        // Tools request their own permissions when opened, not during the island's first launch.
        coordinator.firstLaunch = false
        coordinator.currentView = .home
        Defaults[.showOnLockScreen] = false
        IslandIconManager.shared.apply()
        setupLifecycleObservers()
        // Observe first, then seed current state before creating any windows.
        // Future-only notifications miss an app launched while already locked.
        refreshCurrentGUISession()
        visibility.screenUnavailable = guiSession.isUnavailable
        HUDStateManager.shared.start()
        _ = BriefPresentationCoordinator.shared
        _ = LyricsStore.shared
        HiNotificationManager.shared.start()
        _ = UtilityClockStore.shared
        ClipboardShelfBridge.shared.importImage = { image in
            CaptureTools.shared.saveToShelf(image: image)
        }
        ClipboardShelfBridge.shared.start()
        ShelfRetentionSweeper.shared.start()
        CaptureTools.shared.prepareForCapture = { [weak self] in
            self?.visibility.captureInProgress = true
            self?.applyVisibility()
            SettingsWindowController.shared.window?.orderOut(nil)
        }
        CaptureTools.shared.onCaptureFinished = { [weak self] in
            self?.visibility.captureInProgress = false
            self?.applyVisibility()
            if self?.waitsForCaptureBeforeQuitting == true {
                self?.waitsForCaptureBeforeQuitting = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        rebuildWindows()
        // A manually launched app must remain reachable even with both the
        // island and its menu icon hidden. Login launches stay quiet.
        if showSettingsOnLaunch && !visibility.screenUnavailable {
            DispatchQueue.main.async { SettingsWindowController.shared.showWindow() }
        }
        Publishers.CombineLatest3(visibility.$isHidden, visibility.$screenUnavailable, visibility.$captureInProgress)
            .sink { [weak self] hidden, unavailable, capturing in
                // Close the delivery gate synchronously, before queued timer work can run.
                if hidden || unavailable || capturing {
                    IslandRestModel.shared.setApplicationAvailable(false)
                    HUDStateManager.shared.setApplicationAvailable(false)
                    LyricsStore.shared.setApplicationAvailable(false)
                    HiNotificationManager.shared.setApplicationAvailable(false)
                    BriefPresentationCoordinator.shared.setApplicationAvailable(false)
                }
                // @Published emits before setting; defer to read the committed values.
                DispatchQueue.main.async { self?.applyVisibility() }
            }.store(in: &subscriptions)
        IslandRestModel.shared.$pendingFocusReminder
            .sink { [weak self] pending in
                guard pending else { return }
                DispatchQueue.main.async { self?.presentFocusReminderIfPossible() }
            }.store(in: &subscriptions)
        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            self?.toggleIsland()
        }
        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard self?.visibility.isAvailable == true else { return }
            self?.coordinator.toggleSneakPeek(status: true, type: .music, duration: 3)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        IslandRestModel.shared.refresh()
        HUDStateManager.shared.refresh()
        HiNotificationManager.shared.refresh()
        presentFocusReminderIfPossible()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        visibility.isHidden = false
        applyVisibility()
        if !Defaults[.menubarIcon] { SettingsWindowController.shared.showWindow() }
        return true
    }

    func expandIsland() {
        guard !visibility.screenUnavailable else { return }
        visibility.isHidden = false
        applyVisibility()
        guard visibility.isAvailable, let entry = preferredEntry else { return }
        coordinator.currentView = .home
        entry.pointer.keepExpandedForUserCommand()
        entry.model.open(preferredPage: .home)
    }

    private func toggleIsland() {
        guard visibility.isAvailable, let entry = preferredEntry,
              entry.model.notchState == .open else {
            // A deliberate shortcut, like the menu's Show command, may restore
            // a manually hidden island. Background events never call this path.
            expandIsland()
            return
        }
        entry.pointer.keepExpandedForUserCommand(duration: 0)
        entry.model.close(force: true)
    }

    private var preferredEntry: Entry? {
        if let screen = preferredScreen, let id = screen.displayUUID { return entries[id] }
        return entries.values.first
    }
    private var preferredScreen: NSScreen? {
        if let id = coordinator.preferredScreenUUID, let selected = NSScreen.screen(withUUID: id) { return selected }
        guard Defaults[.automaticallySwitchDisplay] else { return nil }
        return NSScreen.main ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
    }

    private func setupLifecycleObservers() {
        let center = NotificationCenter.default
        let changes: [Notification.Name] = [NSApplication.didChangeScreenParametersNotification,
            .selectedScreenChanged, .notchHeightChanged, .showOnAllDisplaysChanged,
            .automaticallySwitchDisplayChanged]
        for name in changes {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rebuildWindows() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.guiSession.setScreenSleeping(true); self?.updateScreenAvailability() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.guiSession.setScreenSleeping(false)
                    self?.refreshCurrentGUISession()
                    self?.updateScreenAvailability()
                }
            })
        }
        for (name, active) in [(NSWorkspace.sessionDidResignActiveNotification, false),
                               (NSWorkspace.sessionDidBecomeActiveNotification, true)] {
            workspaceTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.guiSession.setSessionActive(active)
                    if active { self?.refreshCurrentGUISession() }
                    self?.updateScreenAvailability()
                }
            })
        }
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedTokens.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        if !locked { self?.refreshCurrentGUISession() }
                        self?.guiSession.setScreenLocked(locked)
                        self?.updateScreenAvailability()
                    }
                })
        }
    }

    private func refreshCurrentGUISession() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        // These two keys are public CGSession API; missing data fails closed.
        let onConsole = session?[kCGSessionOnConsoleKey as String] as? Bool
        let loginDone = session?[kCGSessionLoginDoneKey as String] as? Bool
        // CGSSessionScreenIsLocked is an undocumented/private optional field,
        // not a public CoreGraphics guarantee. Lock/unlock notifications remain
        // authoritative if it is absent; never use absence to clear a known lock.
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool
        guiSession.refreshSession(onConsole: onConsole, loginDone: loginDone, locked: locked)
    }

    private func updateScreenAvailability() {
        visibility.screenUnavailable = guiSession.isUnavailable
        applyVisibility()
        if visibility.isAvailable { rebuildWindows() }
        IslandRestModel.shared.refresh()
        HUDStateManager.shared.refresh()
        HiNotificationManager.shared.refresh()
    }

    private func rebuildWindows() {
        cleanupWindows()
        let screens = Defaults[.showOnAllDisplays] ? NSScreen.screens : preferredScreen.map { [$0] } ?? []
        for screen in screens {
            guard let id = screen.displayUUID else { continue }
            let model = BoringViewModel(screenUUID: id)
            coordinator.selectedScreenUUID = id
            let frame = CGRect(x: screen.frame.midX - windowSize.width / 2,
                               y: screen.frame.maxY - windowSize.height,
                               width: windowSize.width, height: windowSize.height)
            let window = BoringNotchSkyLightWindow(contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "工位充电岛"
            window.identifier = NSUserInterfaceItemIdentifier("NotchIslandNextPanel-" + id)
            window.hidesOnDeactivate = false
            window.animationBehavior = .none
            let pointer = NotchPointerCoordinator(window: window, screen: screen,
                isExpanded: { [weak model] in model?.notchState == .open },
                keepsOpen: { [weak model] in
                    model?.isBatteryPopoverActive == true || SharingStateManager.shared.preventNotchClose
                },
                open: { [weak model] in
                    guard Defaults[.openNotchOnHover] else { return }
                    model?.open()
                }, close: { [weak model] in model?.close() })
            let host = IslandHostingView(rootView: ContentView().environmentObject(model).environmentObject(pointer))
            host.sizingOptions = []
            window.contentView = host
            entries[id] = Entry(window: window, model: model, pointer: pointer)
        }
        applyVisibility()
    }

    private func applyVisibility() {
        if !visibility.isAvailable {
            HUDStateManager.shared.setApplicationAvailable(false)
            IslandRestModel.shared.setApplicationAvailable(false)
            cancelFocusReminderPresentation()
        }
        for entry in entries.values {
            if visibility.isAvailable {
                entry.window.orderFrontRegardless()
                entry.pointer.setEnabled(true)
            } else {
                entry.pointer.setEnabled(false)
                entry.model.close(force: true)
                entry.model.isCameraExpanded = false
                entry.window.orderOut(nil)
            }
        }
        // Never swallow a hardware key unless a real panel can present its result.
        let hasVisiblePanel = visibility.isAvailable && entries.values.contains { $0.window.isVisible }
        HUDStateManager.shared.setApplicationAvailable(hasVisiblePanel)
        BriefPresentationCoordinator.shared.setApplicationAvailable(hasVisiblePanel)
        LyricsStore.shared.setApplicationAvailable(hasVisiblePanel)
        HiNotificationManager.shared.setApplicationAvailable(hasVisiblePanel)
        if !visibility.isAvailable {
            coordinator.sneakPeek.show = false
            coordinator.expandingView.show = false
            WebcamManager.shared.stopSession()
        } else {
            IslandRestModel.shared.setApplicationAvailable(hasVisiblePanel)
            DispatchQueue.main.async { [weak self] in self?.presentFocusReminderIfPossible() }
        }
    }

    private func presentFocusReminderIfPossible() {
        let rest = IslandRestModel.shared
        guard visibility.isAvailable, rest.pendingFocusReminder, focusReminderTask == nil,
              let entry = preferredEntry, entry.window.isVisible else { return }
        coordinator.currentView = .island
        entry.pointer.keepExpandedForUserCommand(duration: 10)
        entry.model.open(preferredPage: .island)
        guard entry.model.notchState == .open else { return }
        // Keep the persisted reminder pending until it has had a full presentation.
        // Hiding, locking, quitting or rebuilding the window during this interval
        // preserves it for the next available island, rather than losing it on open().
        focusReminderTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            guard let self else { return }
            self.focusReminderTask = nil
            if self.visibility.isAvailable, rest.mode == .focus, rest.phase == .completed {
                rest.consumeFocusReminder()
            }
        }
    }

    private func cancelFocusReminderPresentation() {
        focusReminderTask?.cancel()
        focusReminderTask = nil
    }

    private func cleanupWindows() {
        LyricsStore.shared.setApplicationAvailable(false)
        HiNotificationManager.shared.setApplicationAvailable(false)
        BriefPresentationCoordinator.shared.setApplicationAvailable(false)
        HUDStateManager.shared.setApplicationAvailable(false)
        IslandRestModel.shared.setApplicationAvailable(false)
        cancelFocusReminderPresentation()
        IslandRestModel.shared.clearPresentationsForWindowRebuild()
        for entry in entries.values {
            entry.pointer.setEnabled(false)
            entry.window.orderOut(nil)
            entry.window.contentView = nil
            entry.window.close()
            entry.model.destroy()
        }
        entries.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShelfStateViewModel.shared.finaliseUndoWindowBeforeTermination()
        HUDStateManager.shared.stop()
        IslandRestModel.shared.setApplicationAvailable(false)
        cleanupWindows()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for token in distributedTokens { DistributedNotificationCenter.default().removeObserver(token) }
        WebcamManager.shared.stopSession()
        MusicManager.shared.destroy()
    }

    #if DEBUG
    func runInteractionCheck() {
        guard !visibility.isChecking, !visibility.screenUnavailable else { return }
        visibility.isHidden = false
        applyVisibility()
        guard let entry = preferredEntry else { return }
        visibility.isChecking = true
        entry.pointer.setAutomaticHoverSuspendedForDiagnostics(true)
        let initialFrame = entry.window.frame
        let initialApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task { @MainActor in
            var samples: [NotchPointerCoordinator.DiagnosticSnapshot] = []
            @MainActor func sample(for duration: TimeInterval) async {
                let end = ProcessInfo.processInfo.systemUptime + duration
                while ProcessInfo.processInfo.systemUptime < end {
                    if let snapshot = entry.pointer.diagnosticSnapshot() { samples.append(snapshot) }
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            for _ in 0..<20 {
                entry.model.open(preferredPage: .island); await sample(for: 0.60)
                entry.model.close(force: true); await sample(for: 0.65)
            }
            for _ in 0..<10 {
                entry.model.open(preferredPage: .island); await sample(for: 0.14)
                entry.model.close(force: true); await sample(for: 0.12)
                entry.model.open(preferredPage: .island); await sample(for: 0.16)
                entry.model.close(force: true); await sample(for: 0.60)
            }
            var failures: [String] = []
            if entry.window.frame != initialFrame { failures.append(L("Carrier window position changed")) }
            if entry.window.isKeyWindow || entry.window.isMainWindow { failures.append(L("The panel became the keyboard window")) }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != initialApp {
                failures.append(L("Frontmost app changed (exclude manual switching)"))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.dongfengrui.NotchIsland", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("interaction-diagnostics.json")
            do { try encoder.encode(samples).write(to: url, options: .atomic) }
            catch { failures.append(String(format: L("Could not save diagnostics: %@"), error.localizedDescription)) }
            visibility.isChecking = false
            entry.pointer.setAutomaticHoverSuspendedForDiagnostics(false)
            let alert = NSAlert()
            alert.messageText = L("Animation and window diagnostics")
            alert.informativeText = String(format: L("Ran 20 open/close cycles and 10 mid-animation reversals.\nCaptured %lld geometry and mouse-routing samples.\n%@\nSamples: %@\nReview the samples and real hovering separately; this check does not synthesize mouse input."),
                samples.count, failures.isEmpty ? L("Window position and nonactivation checks passed.") : failures.joined(separator: "\n"), url.path)
            alert.addButton(withTitle: L("Done"))
            alert.runModal()
        }
    }
    #endif
}

private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension Notification.Name {
    static let islandOpenToolsSettings = Notification.Name("islandOpenToolsSettings")
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
        return lhs.origin == rhs.origin && lhs.size == rhs.size
    }
}
