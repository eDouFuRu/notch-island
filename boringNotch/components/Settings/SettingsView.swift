//
//  SettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import AppKit
import AVFoundation
import Defaults
import EventKit
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI
import SwiftUIIntrospect

struct SettingsView: View {
    @State private var selectedTab = "General"
    @ObservedObject private var language = AppLanguage.shared
    @State private var accentColorUpdateTrigger = UUID()

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink(value: "General") {
                    Label("General", systemImage: "gear")
                }
                NavigationLink(value: "PotatoTimer") {
                    Label("Sweet Potato Timer", systemImage: "timer")
                }
                NavigationLink(value: "SystemTools") {
                    Label("Quick tools", systemImage: "square.grid.2x2.fill")
                }
                NavigationLink(value: "Appearance") {
                    Label("Appearance", systemImage: "eye")
                }
                NavigationLink(value: "Media") {
                    Label("Media", systemImage: "play.laptopcomputer")
                }
                NavigationLink(value: "HiNotifications") {
                    Label("App notifications", systemImage: "bell.badge")
                }
                NavigationLink(value: "Calendar") {
                    Label("Calendar", systemImage: "calendar")
                }
                NavigationLink(value: "HUD") {
                    Label("HUDs", systemImage: "dial.medium.fill")
                }
                NavigationLink(value: "Battery") {
                    Label("Battery", systemImage: "battery.100.bolt")
                }
//                NavigationLink(value: "Downloads") {
//                    Label("Downloads", systemImage: "square.and.arrow.down")
//                }
                NavigationLink(value: "Shelf") {
                    Label("Shelf", systemImage: "books.vertical")
                }
                NavigationLink(value: "Shortcuts") {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                // NavigationLink(value: "Extensions") {
                //     Label("Extensions", systemImage: "puzzlepiece.extension")
                // }
                NavigationLink(value: "Advanced") {
                    Label("Advanced", systemImage: "gearshape.2")
                }
                NavigationLink(value: "About") {
                    Label("About", systemImage: "info.circle")
                }
            }
            .listStyle(SidebarListStyle())
            .tint(.effectiveAccent)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch selectedTab {
                case "General":
                    GeneralSettings()
                case "PotatoTimer":
                    PotatoTimerSettings()
                case "SystemTools":
                    SystemToolsSettings()
                case "Appearance":
                    Appearance()
                case "Media":
                    Media()
                case "HiNotifications":
                    HiNotificationSettings()
                case "Calendar":
                    CalendarSettings()
                case "HUD":
                    HUD()
                case "Battery":
                    Charge()
                case "Shelf":
                    Shelf()
                case "Shortcuts":
                    Shortcuts()
                case "Extensions":
                    GeneralSettings()
                case "Advanced":
                    Advanced()
                case "About":
                    About()
                default:
                    GeneralSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Native navigation chrome can resolve LocalizedStringKey using the
            // system language. Page titles use L() + verbatim Text below, and
            // this identity change reevaluates them for the current app language.
            .id(language.selection)
        }
        .environment(\.locale, language.locale)
        .onReceive(NotificationCenter.default.publisher(for: .islandOpenTimerSettings)) { _ in selectedTab = "PotatoTimer" }
        .onReceive(NotificationCenter.default.publisher(for: .islandOpenToolsSettings)) { _ in selectedTab = "SystemTools" }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("")
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 700)
        .background(Color(NSColor.windowBackgroundColor))
        .tint(.effectiveAccent)
        .id(accentColorUpdateTrigger)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AccentColorChanged"))) { _ in
            accentColorUpdateTrigger = UUID()
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject private var language = AppLanguage.shared
    @State private var screens: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
        guard let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }
    @ObservedObject var coordinator = BoringViewCoordinator.shared

    @Default(.mirrorShape) var mirrorShape
    @Default(.showEmojis) var showEmojis
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.notchHeight) var notchHeight
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.automaticallySwitchDisplay) var automaticallySwitchDisplay
    @Default(.openNotchOnHover) var openNotchOnHover
    @Default(.notchCloseTriggerMode) var closeTriggerMode
    @Default(.notchCloseDelay) var closeDelay
    @Default(.tabSwitchOnHover) var switchOnHover
    @Default(.tabHoverSwitchDelay) var tabHoverDelay


    var body: some View {
        Form {
            Section("Language") {
                Picker("App language", selection: $language.selection) {
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
            }

            Section {
                Defaults.Toggle(key: .menubarIcon) {
                    Text("Show menu bar icon")
                }
                Text("Hiding the menu bar icon keeps the island running. Reopen the app to access Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                LaunchAtLogin.Toggle {
                    Text("Launch at login")
                }
                Defaults.Toggle(key: .showOnAllDisplays) {
                    Text("Show on all displays")
                }
                .onChange(of: showOnAllDisplays) {
                    NotificationCenter.default.post(
                        name: Notification.Name.showOnAllDisplaysChanged, object: nil)
                }
                Picker("Preferred display", selection: $coordinator.preferredScreenUUID) {
                    ForEach(screens, id: \.uuid) { screen in
                        Text(screen.name).tag(screen.uuid as String?)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                    screens = NSScreen.screens.compactMap { screen in
                        guard let uuid = screen.displayUUID else { return nil }
                        return (uuid, screen.localizedName)
                    }
                }
                .disabled(showOnAllDisplays)
                
                Defaults.Toggle(key: .automaticallySwitchDisplay) {
                    Text("Automatically switch displays")
                }
                    .onChange(of: automaticallySwitchDisplay) {
                        NotificationCenter.default.post(
                            name: Notification.Name.automaticallySwitchDisplayChanged, object: nil)
                    }
                    .disabled(showOnAllDisplays)
            } header: {
                Text("System features")
            }

            Section {
                Picker(
                    selection: $notchHeightMode,
                    label:
                        Text("Notch height on notch displays")
                ) {
                    Text("Match real notch height")
                        .tag(WindowHeightMode.matchRealNotchSize)
                    Text("Match menu bar height")
                        .tag(WindowHeightMode.matchMenuBar)
                    Text("Custom height")
                        .tag(WindowHeightMode.custom)
                }
                .onChange(of: notchHeightMode) {
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
                if notchHeightMode == .custom {
                    Slider(value: $notchHeight, in: 24...45, step: 1) {
                        Text("Custom notch size - \(notchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: notchHeight) {
                        NotificationCenter.default.post(
                            name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
                Picker("Notch height on non-notch displays", selection: $nonNotchHeightMode) {
                    Text("Match menubar height")
                        .tag(WindowHeightMode.matchMenuBar)
                    Text("Simulated notch (32 pt)")
                        .tag(WindowHeightMode.matchRealNotchSize)
                    Text("Custom height")
                        .tag(WindowHeightMode.custom)
                }
                .onChange(of: nonNotchHeightMode) {
                    NotificationCenter.default.post(
                        name: Notification.Name.notchHeightChanged, object: nil)
                }
                if nonNotchHeightMode == .custom {
                    Slider(value: $nonNotchHeight, in: 24...45, step: 1) {
                        Text("Custom notch size - \(nonNotchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: nonNotchHeight) {
                        NotificationCenter.default.post(
                            name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
            } header: {
                Text("Notch sizing")
            }

            NotchBehaviour()

        }
        .toolbar {
            Button("Quit app") {
                NSApp.terminate(self)
            }
            .controlSize(.extraLarge)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle(Text(verbatim: L("General")))
        .onAppear {
            if notchHeightMode == .custom { notchHeight = min(45, max(24, notchHeight)) }
            if nonNotchHeightMode == .custom { nonNotchHeight = min(45, max(24, nonNotchHeight)) }
        }
    }

    @ViewBuilder
    func NotchBehaviour() -> some View {
        Section {
            Defaults.Toggle(key: .openNotchOnHover) {
                Text("Open notch on hover")
            }
            Defaults.Toggle(key: .enableHaptics) {
                    Text("Enable haptic feedback")
            }
            Toggle("Remember last tab", isOn: $coordinator.openLastTabByDefault)
            if openNotchOnHover {
                Text("鼠标在摄像头所占用的刘海区域停留 150 毫秒后展开，两侧的状态展示不触发展开。无刘海屏幕使用顶部模拟胶囊。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker(selection: $closeTriggerMode) {
                ForEach(NotchCloseTriggerMode.allCases, id: \.self) { mode in
                    Text(L(mode.labelKey)).tag(mode)
                }
            } label: {
                Text("Collapse the island")
            }
            if closeTriggerMode == .hoverOut {
                LabeledContent {
                    HStack {
                        Slider(value: $closeDelay, in: 0.15...0.6, step: 0.01)
                        Text(verbatim: String(format: L("%.2f s"), closeDelay))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Collapse delay")
                }
                Text("提高延迟可以避免鼠标划过边缘就误收起。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Defaults.Toggle(key: .tabSwitchOnHover) {
                Text("Switch tabs on hover")
            }
            if switchOnHover {
                LabeledContent {
                    HStack {
                        Slider(value: $tabHoverDelay, in: 0.05...0.4, step: 0.01)
                        Text(verbatim: String(format: L("%.2f s"), tabHoverDelay))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Tab hover delay")
                }
            }
        } header: {
            Text("Notch behavior")
        }
    }
}

struct Charge: View {
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showBatteryIndicator) {
                    Text("Show battery indicator")
                }
                Defaults.Toggle(key: .showPowerStatusNotifications) {
                    Text("Show power status notifications")
                }
            } header: {
                Text("General")
            }
            Section {
                Defaults.Toggle(key: .showBatteryPercentage) {
                    Text("Show battery percentage")
                }
                Defaults.Toggle(key: .showPowerStatusIcons) {
                    Text("Show power status icons")
                }
            } header: {
                Text("Battery Information")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle(Text(verbatim: L("Battery")))
    }
}

//struct Downloads: View {
//    @Default(.selectedDownloadIndicatorStyle) var selectedDownloadIndicatorStyle
//    @Default(.selectedDownloadIconStyle) var selectedDownloadIconStyle
//    var body: some View {
//        Form {
//            warningBadge("We don't support downloads yet", "It will be supported later on.")
//            Section {
//                Defaults.Toggle(key: .enableDownloadListener) {
//                    Text("Show download progress")
//                }
//                    .disabled(true)
//                Defaults.Toggle(key: .enableSafariDownloads) {
//                    Text("Enable Safari Downloads")
//                }
//                    .disabled(!Defaults[.enableDownloadListener])
//                Picker("Download indicator style", selection: $selectedDownloadIndicatorStyle) {
//                    Text("Progress bar")
//                        .tag(DownloadIndicatorStyle.progress)
//                    Text("Percentage")
//                        .tag(DownloadIndicatorStyle.percentage)
//                }
//                Picker("Download icon style", selection: $selectedDownloadIconStyle) {
//                    Text("Only app icon")
//                        .tag(DownloadIconStyle.onlyAppIcon)
//                    Text("Only download icon")
//                        .tag(DownloadIconStyle.onlyIcon)
//                    Text("Both")
//                        .tag(DownloadIconStyle.iconAndAppIcon)
//                }
//
//            } header: {
//                HStack {
//                    Text("Download indicators")
//                    comingSoonTag()
//                }
//            }
//            Section {
//                List {
//                    ForEach([].indices, id: \.self) { index in
//                        Text("\(index)")
//                    }
//                }
//                .frame(minHeight: 96)
//                .overlay {
//                    if true {
//                        Text("No excluded apps")
//                            .foregroundStyle(Color(.secondaryLabelColor))
//                    }
//                }
//                .actionBar(padding: 0) {
//                    Group {
//                        Button {
//                        } label: {
//                            Image(systemName: "plus")
//                                .frame(width: 25, height: 16, alignment: .center)
//                                .contentShape(Rectangle())
//                                .foregroundStyle(.secondary)
//                        }
//
//                        Divider()
//                        Button {
//                        } label: {
//                            Image(systemName: "minus")
//                                .frame(width: 20, height: 16, alignment: .center)
//                                .contentShape(Rectangle())
//                                .foregroundStyle(.secondary)
//                        }
//                    }
//                }
//            } header: {
//                HStack(spacing: 4) {
//                    Text("Exclude apps")
//                    comingSoonTag()
//                }
//            }
//        }
//        .navigationTitle("Downloads")
//    }
//}

struct HUD: View {
    @Default(.inlineHUD) var inlineHUD
    @Default(.enableGradient) var enableGradient
    @Default(.optionKeyAction) var optionKeyAction
    @ObservedObject private var hud = HUDStateManager.shared
    @State private var diagnosticsExpanded = false
    var body: some View {
        Form {
            Section("General") {
                Defaults.Toggle(key: .hudReplacement) {
                    Text("Replace system HUD")
                }
                Label(L(statusTitle), systemImage: hud.isRunning ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(hud.isRunning ? Color.green : Color.secondary)
                if !hud.accessibilityAuthorized {
                    Text("Accessibility access is required to replace the system HUD.").foregroundStyle(.secondary)
                    Button("Request Accessibility") { hud.requestPermission() }.buttonStyle(.borderedProminent)
                }
                if let error = hud.errorMessage { Text(L(error)).foregroundStyle(.orange) }
                Button("Refresh permission status") { hud.refresh() }
                Picker("Option key behaviour", selection: $optionKeyAction) {
                    ForEach(OptionKeyAction.allCases) { option in Text(L(option.rawValue)).tag(option) }
                }.pickerStyle(.radioGroup)
            }
            Section("Appearance") {
                Picker("HUD style", selection: $inlineHUD) {
                    Text("Default").tag(false)
                    Text("Inline").tag(true)
                }
                Picker("Progressbar style", selection: $enableGradient) {
                    Text("Hierarchical").tag(false)
                    Text("Gradient").tag(true)
                }.disabled(inlineHUD)
                Defaults.Toggle(key: .systemEventIndicatorShadow) {
                    Text("Enable glowing effect")
                }.disabled(inlineHUD)
                if inlineHUD { Text("Gradient and glow are available in the default HUD style.").font(.caption).foregroundStyle(.secondary) }
                Defaults.Toggle(key: .systemEventIndicatorUseAccent) {
                    Text("Tint progress bar with accent color")
                }
            }
            Section {
                DisclosureGroup("HUD diagnostics", isExpanded: $diagnosticsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Read-only technical details about this application, its permissions, and the most recent media key event.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView([.horizontal, .vertical]) {
                            Text(verbatim: hud.diagnosticsSummary)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 180)
                        Button("Copy diagnostics") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(hud.diagnosticsSummary, forType: .string)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle(Text(verbatim: L("HUDs")))
        .onAppear { hud.refresh() }
    }
    private var statusTitle: String {
        switch hud.status {
        case .disabled: return "System HUD is active"
        case .permissionRequired: return "Permission required for this application"
        case .running: return "Island HUD is active"
        case .temporarilySuspended: return "System HUD is active while the island is hidden"
        case .failed: return "Unable to start HUD replacement"
        }
    }
}

struct Media: View {
    @Default(.waitInterval) var waitInterval
    @Default(.mediaController) var mediaController
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.hideNotchOption) var hideNotchOption
    @Default(.enableSneakPeek) private var enableSneakPeek
    @Default(.sneakPeekStyles) var sneakPeekStyles

    @Default(.lyricsDisplayLocation) var lyricsDisplayLocation
    @Default(.lyricsColorMode) private var lyricsColorMode
    @Default(.customLyricsColor) private var customLyricsColor
    @ObservedObject private var lyricState = LyricsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("Music Source", selection: $mediaController) {
                    ForEach(availableMediaControllers) { controller in
                        Text(L(controller.rawValue)).tag(controller)
                    }
                }
                .onChange(of: mediaController) { _, _ in
                    NotificationCenter.default.post(
                        name: Notification.Name.mediaControllerChanged,
                        object: nil
                    )
                }
            } header: {
                Text("Media Source")
            } footer: {
                if MusicManager.shared.isNowPlayingDeprecated {
                    HStack {
                        Text("YouTube Music requires this third-party app to be installed: ")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Link(
                            "https://github.com/pear-devs/pear-desktop",
                            destination: URL(string: "https://github.com/pear-devs/pear-desktop")!
                        )
                        .font(.caption)
                        .foregroundColor(.blue)  // Ensures it's visibly a link
                    }
                } else {
                    Text(
                        "'Now Playing' was the only option on previous versions and works with all media apps."
                    )
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }
            
            Section {
                Toggle(
                    "Show music live activity",
                    isOn: $coordinator.musicLiveActivityEnabled.animation()
                )
                Toggle("Show sneak peek on playback changes", isOn: $enableSneakPeek)
                Picker("Sneak Peek Style", selection: $sneakPeekStyles) {
                    ForEach(SneakPeekStyle.allCases) { style in
                        Text(L(style.rawValue)).tag(style)
                    }
                }
                HStack {
                    Stepper(value: $waitInterval, in: 0...10, step: 1) {
                        HStack {
                            Text("Media inactivity timeout")
                            Spacer()
                            Text("\(Defaults[.waitInterval], specifier: "%.0f") seconds")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Picker(
                    selection: $hideNotchOption,
                    label:
                        HStack {
                            Text("Full screen behavior")
                            customBadge(text: "Beta")
                        }
                ) {
                    Text("Hide for all apps").tag(HideNotchOption.always)
                    Text("Hide for media app only").tag(
                        HideNotchOption.nowPlayingOnly)
                    Text("Never hide").tag(HideNotchOption.never)
                }
            } header: {
                Text("Media playback live activity")
            }
            
            Section {
                MusicSlotConfigurationView()
                Picker("Lyrics location", selection: $lyricsDisplayLocation) {
                    Text("Off").tag(LyricsDisplayLocation.off)
                    Text("Inside the player").tag(LyricsDisplayLocation.player)
                    Text("Below the notch").tag(LyricsDisplayLocation.notch)
                }
                Picker("Lyrics color", selection: $lyricsColorMode) {
                    Text("Default (white)").tag(LyricsColorMode.white)
                    Text("Match album art").tag(LyricsColorMode.albumArt)
                    Text("Custom color").tag(LyricsColorMode.custom)
                }
                if lyricsColorMode == .custom {
                    ExplicitColorPicker(selection: $customLyricsColor)
                }
                Text("Applies to lyrics in the player and below the notch. Match album art follows the current song's cover.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry current song lyrics") { lyricState.retryCurrentTrack() }
                    .disabled(lyricsDisplayLocation == .off || lyricState.isLoading)
                Text("Online synced lyrics are matched by track and playback position. They may differ from your music app. Pausing hides the notch lyric row.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Media controls")
            }  footer: {
                Text("Customize which controls appear in the music player. Volume expands when active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle(Text(verbatim: L("Media")))
    }

    // Only show controller options that are available on this macOS version
    private var availableMediaControllers: [MediaControllerType] {
        if MusicManager.shared.isNowPlayingDeprecated {
            return MediaControllerType.allCases.filter { $0 != .nowPlaying }
        } else {
            return MediaControllerType.allCases
        }
    }
}

/// A button owns the panel explicitly instead of relying on a color well to
/// activate it from our accessory application's settings window.
private struct ExplicitColorPicker: View {
    @Binding var selection: Color
    @StateObject private var presenter = SettingsColorPanelPresenter()

    var body: some View {
        HStack {
            Text("Custom lyrics color")
            Spacer()
            Button {
                presenter.show(selection: $selection)
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selection)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.primary.opacity(0.3), lineWidth: 1)
                        }
                        .frame(width: 26, height: 18)
                    Text("Choose any color")
                }
            }
            .accessibilityLabel(Text("Custom lyrics color"))
        }
        .onDisappear { presenter.dismiss() }
    }
}

@MainActor
private final class SettingsColorPanelPresenter: NSObject, ObservableObject {
    private var selection: Binding<Color>?
    private weak var panel: NSColorPanel?
    private weak var ownerWindow: NSWindow?

    func show(selection: Binding<Color>) {
        dismiss()
        let panel = NSColorPanel.shared
        ownerWindow = NSApp.keyWindow
        self.selection = selection
        self.panel = panel
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(selection.wrappedValue).withAlphaComponent(1)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Activation can finish after the button action returns.
        DispatchQueue.main.async { [weak self] in
            self?.panel?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard sender === panel else { return }
        selection?.wrappedValue = Color(nsColor: sender.color.withAlphaComponent(1))
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === panel || window === ownerWindow { dismiss() }
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        selection = nil
        ownerWindow = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        // Release the shared panel before another settings page's color well
        // takes ownership, so its changes cannot alter the lyric preference.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

struct CalendarSettings: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.showCalendar) var showCalendar: Bool
    @Default(.hideCompletedReminders) var hideCompletedReminders
    @Default(.hideAllDayEvents) var hideAllDayEvents
    @Default(.autoScrollToNextEvent) var autoScrollToNextEvent

    var body: some View {
        Form {
            Defaults.Toggle(key: .showCalendar) {
                Text("Show calendar")
            }
            Defaults.Toggle(key: .hideCompletedReminders) {
                Text("Hide completed reminders")
            }
            Defaults.Toggle(key: .hideAllDayEvents) {
                Text("Hide all-day events")
            }
            Defaults.Toggle(key: .autoScrollToNextEvent) {
                Text("Auto-scroll to next event")
            }
            Defaults.Toggle(key: .showFullEventTitles) {
                Text("Always show full event titles")
            }
            Section(header: Text("Calendars")) {
                if calendarManager.calendarAuthorizationStatus == .notDetermined || calendarManager.calendarAuthorizationStatus == .writeOnly {
                    Button("Allow calendar access") { Task { await calendarManager.requestCalendarAccess() } }
                        .disabled(calendarManager.isRequestingAccess)
                } else if calendarManager.calendarAuthorizationStatus != .fullAccess {
                    Text("Calendar access is denied. Please enable it in System Settings.")
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Open Calendar Settings") {
                        if let settingsURL = URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                        ) {
                            NSWorkspace.shared.open(settingsURL)
                        }
                    }
                } else {
                    List {
                        ForEach(calendarManager.eventCalendars, id: \.id) { calendar in
                            Toggle(
                                isOn: Binding(
                                    get: { calendarManager.getCalendarSelected(calendar) },
                                    set: { isSelected in
                                        Task {
                                            await calendarManager.setCalendarSelected(
                                                calendar, isSelected: isSelected)
                                        }
                                    }
                                )
                            ) {
                                Text(calendar.title)
                            }
                            .accentColor(lighterColor(from: calendar.color))
                            .disabled(!showCalendar)
                        }
                    }
                }
            }
            Section(header: Text("Reminders")) {
                if calendarManager.reminderAuthorizationStatus == .notDetermined {
                    Button("Allow reminder access") { Task { await calendarManager.requestReminderAccess() } }
                        .disabled(calendarManager.isRequestingAccess)
                } else if calendarManager.reminderAuthorizationStatus != .fullAccess {
                    Text("Reminder access is denied. Please enable it in System Settings.")
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Open Reminder Settings") {
                        if let settingsURL = URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
                        ) {
                            NSWorkspace.shared.open(settingsURL)
                        }
                    }
                } else {
                    List {
                        ForEach(calendarManager.reminderLists, id: \.id) { calendar in
                            Toggle(
                                isOn: Binding(
                                    get: { calendarManager.getCalendarSelected(calendar) },
                                    set: { isSelected in
                                        Task {
                                            await calendarManager.setCalendarSelected(
                                                calendar, isSelected: isSelected)
                                        }
                                    }
                                )
                            ) {
                                Text(calendar.title)
                            }
                            .accentColor(lighterColor(from: calendar.color))
                            .disabled(!showCalendar)
                        }
                    }
                }
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle(Text(verbatim: L("Calendar")))
        .onAppear {
            Task {
                await calendarManager.checkCalendarAuthorization()
                await calendarManager.checkReminderAuthorization()
            }
        }
    }
}

func lighterColor(from nsColor: NSColor, amount: CGFloat = 0.14) -> Color {
    let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
    var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0,0,0,0)
    srgb.getRed(&r, green: &g, blue: &b, alpha: &a)

    func lighten(_ c: CGFloat) -> CGFloat {
        let increased = c + (1.0 - c) * amount
        return min(max(increased, 0), 1)
    }

    let nr = lighten(r)
    let ng = lighten(g)
    let nb = lighten(b)

    return Color(red: Double(nr), green: Double(ng), blue: Double(nb), opacity: Double(a))
}

struct About: View {
    @ObservedObject private var icons = IslandIconManager.shared
    var body: some View {
        Form {
            Section("工位充电岛") {
                HStack(spacing: 16) {
                    Image(icons.selected.assetName).resizable().frame(width: 76, height: 76)
                        .accessibilityLabel(icons.selected.title)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("工位充电岛").font(.title2.bold())
                        Text("Sweet Potato Timer").foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
                LabeledContent("版本", value: "\(Bundle.main.releaseVersionNumber ?? L("未知")) · \(L("定制版"))")
                LabeledContent("构建", value: Bundle.main.buildVersionNumber ?? L("未知"))
                Text("鼠标停留在物理刘海区域，展开薯队长与日常工具。红薯钟、休息进度和红薯库存保存在本机。")
                    .foregroundStyle(.secondary)
            }

            Section("开源来源") {
                LabeledContent("上游", value: "boring.notch v2.7.3")
                Text("固定提交 16b0f11f51c79d42e27c10d77fd9e53c11410fdb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("本应用基于 TheBoredTeam 的 boring.notch 定制，保留上游及第三方作者的版权声明，并遵循 GPL-3.0 许可。")
                    .foregroundStyle(.secondary)
                Link("查看上游项目", destination: URL(string: "https://github.com/TheBoredTeam/boring.notch/tree/v2.7.3")!)
                Link("查看 GPL-3.0 许可证", destination: URL(string: "https://github.com/TheBoredTeam/boring.notch/blob/v2.7.3/LICENSE")!)
            }

            Section {
                Text("定制版不连接上游更新服务。后续版本通过本项目重新构建。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text(verbatim: L("关于工位充电岛")))
    }
}

struct Shelf: View {
    
    @Default(.shelfTapToOpen) var shelfTapToOpen: Bool
    @Default(.quickShareProvider) var quickShareProvider
    @Default(.shelfDragRemovalTrigger) var dragRemovalTrigger
    @Default(.autoRemoveShelfItems) var autoRemoveShelfItems
    @Default(.shelfRetention) var shelfRetention
    @StateObject private var quickShareService = QuickShareService.shared

    private var selectedProvider: QuickShareProvider? {
        quickShareService.availableProviders.first(where: { $0.id == quickShareProvider })
    }

    /// Read once per settings render rather than observed: accessibility trust changes
    /// require the user to leave and come back anyway.
    private var shelfChordHint: LocalizedStringKey {
        ShelfKeyboardChords.shared.isAvailable
            ? "指针停在暂存区上时可用 ⌘C 复制、⌘X 剪切、⌘V 粘贴；右键菜单里也有同样的命令。"
            : "右键菜单可复制 / 剪切 / 粘贴。⌘C / ⌘X / ⌘V 需要辅助功能权限（小岛不抢键盘焦点，只能靠事件监听读到组合键），未授权时快捷键不生效，右键菜单不受影响。"
    }
    
    init() {
        Task { await QuickShareService.shared.discoverAvailableProviders() }
    }
    
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .boringShelf) {
                    Text("Enable shelf")
                }
                Defaults.Toggle(key: .openShelfByDefault) {
                    Text("Open shelf by default if items are present")
                }
                Defaults.Toggle(key: .autoRemoveShelfItems) {
                    Text("Remove from shelf after dragging")
                }
                Picker(selection: $dragRemovalTrigger) {
                    ForEach(ShelfDragRemovalTriggerMode.allCases, id: \.self) { mode in
                        Text(L(mode.labelKey)).tag(mode)
                    }
                } label: {
                    Text("Move out of the shelf while holding")
                }
                .disabled(autoRemoveShelfItems)
                if autoRemoveShelfItems {
                    Text("已设为拖出后一律移除，组合键不再起作用。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("拖出前或拖动途中按住该组合键即可，放手时松没松开都算。拖回小岛不会移除；移除后 10 秒内可撤销。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker(selection: $shelfRetention) {
                    ForEach(ShelfRetentionMode.allCases, id: \.self) { mode in
                        Text(L(mode.labelKey)).tag(mode)
                    }
                } label: {
                    Text("Clear staged files")
                }
                Text("每个文件从进入暂存区起单独计时。截图、录屏、剪贴板图片，以及去背景、转格式、合成 PDF、压缩生成的文件都会被真正删除；只有从访达拖进来、仍能定位到原文件的条目才是到期只移除条目，磁盘上的原件不动。")
                    .font(.caption).foregroundStyle(.secondary)
                Defaults.Toggle(key: .copyCaptureToClipboard) {
                    Text("Copy captures to the clipboard")
                }
                Defaults.Toggle(key: .importClipboardImagesToShelf) {
                    Text("Add copied images to the shelf")
                }
                Text("开启后会定期检查剪贴板类型，仅在其中确有图片时才读取内容，用于接住其它截图工具的图片。复制文件时剪贴板里也会有该文件的图标位图，这种情况交给「暂存剪贴板文件」按钮按原格式复制，自动接收不会把图标当成图片存进来。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(shelfChordHint)
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("General")
                }
            }
            
            Section {
                Picker("Quick Share Service", selection: $quickShareProvider) {
                    ForEach(quickShareService.availableProviders, id: \.id) { provider in
                        HStack {
                            Group {
                                if let imgData = provider.imageData, let nsImg = NSImage(data: imgData) {
                                    Image(nsImage: nsImg)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            .frame(width: 16, height: 16)
                            .foregroundColor(.accentColor)
                            Text(provider.id)
                        }
                        .tag(provider.id)
                    }
                }
                .pickerStyle(.menu)
                
                if let selectedProvider = selectedProvider {
                    HStack {
                        Group {
                            if let imgData = selectedProvider.imageData, let nsImg = NSImage(data: imgData) {
                                Image(nsImage: nsImg)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .frame(width: 16, height: 16)
                        .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Currently selected: \(selectedProvider.id)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Files dropped on the shelf will be shared via this service")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Providers are always enabled; user can pick default service above.
                
            } header: {
                HStack {
                    Text("Quick Share")
                }
            } footer: {
                Text("Choose which service to use when sharing files from the shelf. Click the shelf button to select files, or drag files onto it to share immediately.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle(Text(verbatim: L("Shelf")))
    }
}

//struct Extensions: View {
//    @State private var effectTrigger: Bool = false
//    var body: some View {
//        Form {
//            Section {
//                List {
//                    ForEach(extensionManager.installedExtensions.indices, id: \.self) { index in
//                        let item = extensionManager.installedExtensions[index]
//                        HStack {
//                            AppIcon(for: item.bundleIdentifier)
//                                .resizable()
//                                .frame(width: 24, height: 24)
//                            Text(item.name)
//                            ListItemPopover {
//                                Text("Description")
//                            }
//                            Spacer(minLength: 0)
//                            HStack(spacing: 6) {
//                                Circle()
//                                    .frame(width: 6, height: 6)
//                                    .foregroundColor(
//                                        isExtensionRunning(item.bundleIdentifier)
//                                            ? .green : item.status == .disabled ? .gray : .red
//                                    )
//                                    .conditionalModifier(isExtensionRunning(item.bundleIdentifier))
//                                { view in
//                                    view
//                                        .shadow(color: .green, radius: 3)
//                                }
//                                Text(
//                                    isExtensionRunning(item.bundleIdentifier)
//                                        ? "Running"
//                                        : item.status == .disabled ? "Disabled" : "Stopped"
//                                )
//                                .contentTransition(.numericText())
//                                .foregroundStyle(.secondary)
//                                .font(.footnote)
//                            }
//                            .frame(width: 60, alignment: .leading)
//
//                            Menu(
//                                content: {
//                                    Button("Restart") {
//                                        let ws = NSWorkspace.shared
//
//                                        if let ext = ws.runningApplications.first(where: {
//                                            $0.bundleIdentifier == item.bundleIdentifier
//                                        }) {
//                                            ext.terminate()
//                                        }
//
//                                        if let appURL = ws.urlForApplication(
//                                            withBundleIdentifier: item.bundleIdentifier)
//                                        {
//                                            ws.openApplication(
//                                                at: appURL, configuration: .init(),
//                                                completionHandler: nil)
//                                        }
//                                    }
//                                    .keyboardShortcut("R", modifiers: .command)
//                                    Button("Disable") {
//                                        if let ext = NSWorkspace.shared.runningApplications.first(
//                                            where: { $0.bundleIdentifier == item.bundleIdentifier })
//                                        {
//                                            ext.terminate()
//                                        }
//                                        extensionManager.installedExtensions[index].status =
//                                            .disabled
//                                    }
//                                    .keyboardShortcut("D", modifiers: .command)
//                                    Divider()
//                                    Button("Uninstall", role: .destructive) {
//                                        //
//                                    }
//                                },
//                                label: {
//                                    Image(systemName: "ellipsis.circle")
//                                        .foregroundStyle(.secondary)
//                                }
//                            )
//                            .controlSize(.regular)
//                        }
//                        .buttonStyle(PlainButtonStyle())
//                        .padding(.vertical, 5)
//                    }
//                }
//                .frame(minHeight: 120)
//                .actionBar {
//                    Button {
//                    } label: {
//                        HStack(spacing: 3) {
//                            Image(systemName: "plus")
//                            Text("Add manually")
//                        }
//                        .foregroundStyle(.secondary)
//                    }
//                    .disabled(true)
//                    Spacer()
//                    Button {
//                        withAnimation(.linear(duration: 1)) {
//                            effectTrigger.toggle()
//                        } completion: {
//                            effectTrigger.toggle()
//                        }
//                        extensionManager.checkIfExtensionsAreInstalled()
//                    } label: {
//                        HStack(spacing: 3) {
//                            Image(systemName: "arrow.triangle.2.circlepath")
//                                .rotationEffect(effectTrigger ? .degrees(360) : .zero)
//                        }
//                        .foregroundStyle(.secondary)
//                    }
//                }
//                .controlSize(.small)
//                .buttonStyle(PlainButtonStyle())
//                .overlay {
//                    if extensionManager.installedExtensions.isEmpty {
//                        Text("No extension installed")
//                            .foregroundStyle(Color(.secondaryLabelColor))
//                            .padding(.bottom, 22)
//                    }
//                }
//            } header: {
//                HStack(spacing: 0) {
//                    Text("Installed extensions")
//                    if !extensionManager.installedExtensions.isEmpty {
//                        Text(" – \(extensionManager.installedExtensions.count)")
//                            .foregroundStyle(.secondary)
//                    }
//                }
//            }
//        }
//        .accentColor(.effectiveAccent)
//        .navigationTitle("Extensions")
//        // TipsView()
//        // .padding(.horizontal, 19)
//    }
//}

struct Appearance: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.mirrorShape) var mirrorShape
    @Default(.sliderColor) var sliderColor
    var body: some View {
        Form {
            Section {
                Toggle("Always show tabs", isOn: $coordinator.alwaysShowTabs)
                Defaults.Toggle(key: .settingsIconInNotch) {
                    Text("Show settings icon in notch")
                }

            } header: {
                Text("General")
            }

            Section {
                Defaults.Toggle(key: .coloredSpectrogram) {
                    Text("Colored spectrogram")
                }
                Defaults.Toggle(key: .playerColorTinting) {
                    Text("Player tinting")
                }
                Defaults.Toggle(key: .lightingEffect) {
                    Text("Album art glow")
                }
                Text("播放时在专辑封面周围叠一层随封面取色的柔光。此前叫「封面背后模糊」，但那个效果从未被绘制，名字与实际不符。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Slider color", selection: $sliderColor) {
                    ForEach(SliderColorEnum.allCases, id: \.self) { option in
                        Text(L(option.rawValue))
                    }
                }
            } header: {
                Text("Media")
            }

            Section {
                Defaults.Toggle(key: .showMirror) {
                    Text("Enable boring mirror")
                }
                    .disabled(!checkVideoInput())
                if !checkVideoInput() {
                    Text("No compatible camera is connected.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Mirror shape", selection: $mirrorShape) {
                    Text("Circle")
                        .tag(MirrorShapeEnum.circle)
                    Text("Square")
                        .tag(MirrorShapeEnum.rectangle)
                }
                Defaults.Toggle(key: .showNotHumanFace) {
                    Text("Show cool face animation while inactive")
                }
            } header: {
                HStack {
                    Text("Additional features")
                }
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle(Text(verbatim: L("Appearance")))
    }

    func checkVideoInput() -> Bool {
        if AVCaptureDevice.default(for: .video) != nil {
            return true
        }

        return false
    }
}

struct Advanced: View {
    @Default(.useCustomAccentColor) var useCustomAccentColor
    @Default(.customAccentColorData) var customAccentColorData
    @Default(.hideFromScreenRecording) var hideFromScreenRecording
    
    @State private var customAccentColor: Color = .accentColor
    @State private var selectedPresetColor: PresetAccentColor? = nil
    
    // macOS accent colors
    enum PresetAccentColor: String, CaseIterable, Identifiable {
        case blue = "Blue"
        case purple = "Purple"
        case pink = "Pink"
        case red = "Red"
        case orange = "Orange"
        case yellow = "Yellow"
        case green = "Green"
        case graphite = "Graphite"
        
        var id: String { self.rawValue }
        
        var color: Color {
            switch self {
            case .blue: return Color(red: 0.0, green: 0.478, blue: 1.0)
            case .purple: return Color(red: 0.686, green: 0.322, blue: 0.871)
            case .pink: return Color(red: 1.0, green: 0.176, blue: 0.333)
            case .red: return Color(red: 1.0, green: 0.271, blue: 0.227)
            case .orange: return Color(red: 1.0, green: 0.584, blue: 0.0)
            case .yellow: return Color(red: 1.0, green: 0.8, blue: 0.0)
            case .green: return Color(red: 0.4, green: 0.824, blue: 0.176)
            case .graphite: return Color(red: 0.557, green: 0.557, blue: 0.576)
            }
        }
    }
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    // Toggle between system and custom
                    Picker("Accent color", selection: $useCustomAccentColor) {
                        Text("System").tag(false)
                        Text("Custom").tag(true)
                    }
                    .pickerStyle(.segmented)
                    
                    if !useCustomAccentColor {
                        // System accent info
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                AccentCircleButton(
                                    isSelected: true,
                                    color: .accentColor,
                                    isSystemDefault: true
                                ) {}
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Using System Accent")
                                        .font(.body)
                                    Text("Your macOS system accent color")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    } else {
                        // Custom color options
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Color Presets")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            
                            HStack(spacing: 12) {
                                ForEach(PresetAccentColor.allCases) { preset in
                                    AccentCircleButton(
                                        isSelected: selectedPresetColor == preset,
                                        color: preset.color,
                                        isMulticolor: false
                                    ) {
                                        selectedPresetColor = preset
                                        customAccentColor = preset.color
                                        saveCustomColor(preset.color)
                                        forceUiUpdate()
                                    }
                                }
                                Spacer()
                            }
                            
                            Divider()
                                .padding(.vertical, 4)
                            
                            // Custom color picker
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Pick a Color")
                                        .font(.body)
                                    Text("Choose any color")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                ColorPicker(selection: Binding(
                                    get: { customAccentColor },
                                    set: { newColor in
                                        customAccentColor = newColor
                                        selectedPresetColor = nil
                                        saveCustomColor(newColor)
                                        forceUiUpdate()
                                    }
                                ), supportsOpacity: false) {
                                    ZStack {
                                        Circle()
                                            .fill(customAccentColor)
                                            .frame(width: 32, height: 32)
                                        
                                        if selectedPresetColor == nil {
                                            Circle()
                                                .strokeBorder(.primary.opacity(0.3), lineWidth: 2)
                                                .frame(width: 32, height: 32)
                                        }
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Accent color")
            } footer: {
                Text("Choose between your system accent color or customize it with your own selection.")
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .onAppear {
                initializeAccentColorState()
            }
            
            Section {
                Defaults.Toggle(key: .enableShadow) {
                    Text("Enable window shadow")
                }
                Defaults.Toggle(key: .cornerRadiusScaling) {
                    Text("Corner radius scaling")
                }
            } header: {
                Text("Window Appearance")
            }
            
            Section("App icon") {
                IslandIconPicker()
            }
            
            Section {
                Text("锁屏时小岛自动隐藏，解锁后恢复原来的显示状态。")
                    .foregroundStyle(.secondary)
                Toggle("Hide from screen recording", isOn: .constant(false)).disabled(true)
                Text("macOS cannot reliably exclude this panel from screen recording. Hide the island before sharing your screen.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Window Behavior")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle(Text(verbatim: L("Advanced")))
        .onAppear {
            loadCustomColor()
        }
    }
    
    private func forceUiUpdate() {
        // Force refresh the UI
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("AccentColorChanged"), object: nil)
        }
    }
    
    private func saveCustomColor(_ color: Color) {
        let nsColor = NSColor(color)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
            Defaults[.customAccentColorData] = colorData
            forceUiUpdate()
        }
    }
    
    private func loadCustomColor() {
        if let colorData = Defaults[.customAccentColorData],
           let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            customAccentColor = Color(nsColor: nsColor)
            
            // Check if loaded color matches a preset
            selectedPresetColor = nil
            for preset in PresetAccentColor.allCases {
                if colorsAreEqual(Color(nsColor: nsColor), preset.color) {
                    selectedPresetColor = preset
                    break
                }
            }
        }
    }
    
    private func colorsAreEqual(_ color1: Color, _ color2: Color) -> Bool {
        let nsColor1 = NSColor(color1).usingColorSpace(.sRGB) ?? NSColor(color1)
        let nsColor2 = NSColor(color2).usingColorSpace(.sRGB) ?? NSColor(color2)
        
        return abs(nsColor1.redComponent - nsColor2.redComponent) < 0.01 &&
               abs(nsColor1.greenComponent - nsColor2.greenComponent) < 0.01 &&
               abs(nsColor1.blueComponent - nsColor2.blueComponent) < 0.01
    }
    
    private func initializeAccentColorState() {
        if !useCustomAccentColor {
            selectedPresetColor = nil // Multicolor is selected when useCustomAccentColor is false
        } else {
            loadCustomColor()
        }
    }
}

// MARK: - Accent Circle Button Component
struct AccentCircleButton: View {
    let isSelected: Bool
    let color: Color
    var isSystemDefault: Bool = false
    var isMulticolor: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                // Color circle
                Circle()
                    .fill(color)
                    .frame(width: 32, height: 32)
                
                // Subtle border
                Circle()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    .frame(width: 32, height: 32)
                
                // Apple-style highlight ring around the middle when selected
                if isSelected {
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(0.5),
                            lineWidth: 2
                        )
                        .frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isSystemDefault ? L("Use your macOS system accent color") : "")
    }
}

struct Shortcuts: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder(for: .toggleSneakPeek) {
                    Text("Toggle Sneak Peek:")
                }
            } header: {
                Text("Media")
            } footer: {
                Text(
                    "Sneak Peek shows the media title and artist under the notch for a few seconds."
                )
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            Section {
                KeyboardShortcuts.Recorder(for: .toggleNotchOpen) {
                    Text("Toggle Notch Open:")
                }
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle(Text(verbatim: L("Shortcuts")))
    }
}

func proFeatureBadge() -> some View {
    Text("Upgrade to Pro")
        .foregroundStyle(Color(red: 0.545, green: 0.196, blue: 0.98))
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4).stroke(
                Color(red: 0.545, green: 0.196, blue: 0.98), lineWidth: 1))
}

func comingSoonTag() -> some View {
    Text("Coming soon")
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func customBadge(text: String) -> some View {
    Text(L(text))
        .foregroundStyle(.secondary)
        .font(.footnote.bold())
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color(nsColor: .secondarySystemFill))
        .clipShape(.capsule)
}

func warningBadge(_ text: String, _ description: String) -> some View {
    Section {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading) {
                Text(L(text))
                    .font(.headline)
                Text(L(description))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

#Preview {
    HUD()
}
