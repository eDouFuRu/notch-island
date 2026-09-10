import AppKit
import Combine
import SwiftUI

/// Shared geometry for the quick-tool grid.
///
/// Every tile paints at `cardHeight`, and the grid pins each cell's measured
/// frame to the same value so the reorder handle lands on the real card corner
/// even for tiles whose control reports a smaller intrinsic size. Painted and
/// measured heights must stay equal, so they read from here rather than from
/// literals scattered across the tile views.
@MainActor final class SystemToolConfigurationStore: ObservableObject {
    static let shared = SystemToolConfigurationStore()
    private static let key = "island.quickTools.v1"
    let dragSourceID = UUID().uuidString
    @Published private(set) var configuration: ToolGridConfiguration
    private init() {
        let all = SystemToolCatalog.defaultOrderedIDs + SystemToolCatalog.all.map { $0.id.rawValue }
        if let data = UserDefaults.standard.data(forKey: Self.key),
           var saved = try? JSONDecoder().decode(ToolGridConfiguration.self, from: data) {
            saved.reconcile(allIDs: all); configuration = saved
        } else {
            configuration = ToolGridConfiguration(allIDs: all, defaultVisible: SystemToolCatalog.defaultVisible.map(\.rawValue))
        }
    }
    var selectedTools: [SystemToolDefinition] {
        configuration.selectedIDs.compactMap(SystemToolID.init(rawValue:)).map(SystemToolCatalog.tool)
    }
    func setVisible(_ value: Bool, id: SystemToolID) { configuration.setVisible(value, id: id.rawValue); save() }
    func move(_ id: SystemToolID, by offset: Int) { configuration.move(id.rawValue, by: offset); save() }
    @discardableResult
    func drop(_ payload: ToolGridDragPayload, on id: SystemToolID) -> Bool {
        guard configuration.drop(payload, on: id.rawValue, sourceID: dragSourceID) else { return false }
        save()
        return true
    }
    func reset() {
        configuration = ToolGridConfiguration(allIDs: SystemToolCatalog.defaultOrderedIDs + SystemToolCatalog.all.map { $0.id.rawValue },
            defaultVisible: SystemToolCatalog.defaultVisible.map(\.rawValue))
        save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

struct SystemToolsPage: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var configuration = SystemToolConfigurationStore.shared
    @ObservedObject private var capture = CaptureTools.shared
    @State private var message = ""
    private let columns = Array(repeating: GridItem(.flexible(), spacing: SystemToolGridMetrics.spacing), count: 4)
    var body: some View {
        VStack(alignment: .leading, spacing: SystemToolGridMetrics.spacing) {
            HStack {
                Label(L("Quick tools"), systemImage: "square.grid.2x2.fill").font(.system(size: 12, weight: .semibold))
                Label(L("Drag handles to reorder"), systemImage: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.62))
                    .help(L("Hold a handle and drag to reorder. Changes are saved immediately."))
                Spacer()
                Button { capture.importClipboardFiles() } label: { Label(L("Save clipboard files"), systemImage: "doc.on.clipboard") }
                    .help(L("Save whatever was copied by hi, WeChat, Finder or another app to the shelf, keeping the original file format."))
                Button { SettingsWindowController.shared.showToolsSettings() } label: { Label(L("Customize"), systemImage: "slider.horizontal.3") }
            }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                .frame(height: SystemToolGridMetrics.pageHeaderHeight)
            ScrollView {
                if configuration.selectedTools.isEmpty {
                    VStack(spacing: 8) {
                        Text(L("No tools selected"))
                        Button(L("Choose tools")) { SettingsWindowController.shared.showToolsSettings() }
                    }.frame(maxWidth: .infinity).padding(24)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(configuration.selectedTools) { tool in
                            Group {
                                if case .slider(let kind) = tool.behavior { SystemToolSliderTile(tool: tool, kind: kind) }
                                else if tool.behavior == .wifiPower { SystemToolWifiTile() }
                                else if tool.behavior == .bluetoothPower { SystemToolBluetoothTile() }
                                else if tool.behavior == .nightShiftToggle { SystemToolNightShiftTile() }
                                else if tool.behavior == .trueToneToggle { SystemToolTrueToneTile() }
                                else if tool.behavior == .inputSourcePicker { SystemToolInputSourceTile() }
                                else if tool.behavior == .audioOutputPicker { SystemToolAudioOutputTile() }
                                else if tool.behavior == .displayModePicker { SystemToolDisplayModeTile() }
                                else if tool.behavior == .vpnConnectionPicker { SystemToolVPNTile() }
                                else if case let .accessibilityDisplayToggle(feature) = tool.behavior {
                                    SystemToolAccessibilityDisplayTile(feature: feature)
                                }
                                else if tool.behavior == .appearanceToggle { SystemToolAppearanceTile() }
                                else if tool.behavior == .timeMachineBackup { SystemToolTimeMachineTile() }
                                else { toolButton(tool) }
                            }
                            // Some tiles report a smaller layout frame than the card they paint,
                            // which would centre the handle overlay inside the grid row. Pinning
                            // the measured size to the painted size keeps the handle and the drop
                            // highlight on the real card edges for every tile kind.
                            .frame(maxWidth: .infinity, minHeight: SystemToolGridMetrics.cardHeight)
                            .overlay(alignment: .topTrailing) {
                                ToolReorderHandle(tool: tool).padding(3)
                            }
                            .modifier(ToolReorderDropTarget(tool: tool, cornerRadius: 12))
                        }
                    }
                }
            }.scrollIndicators(.visible)
                // Pinned to a whole number of rows so a partially clipped card can never
                // appear at the bottom edge, whatever the tool count.
                .frame(height: SystemToolGridMetrics.gridViewportHeight)
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
                Text(message.isEmpty ? capture.statusText : L(message)).lineLimit(1).help(message.isEmpty ? capture.statusText : L(message))
                Spacer(minLength: 0)
                Button(L("Open shelf")) { BoringViewCoordinator.shared.currentView = .shelf }
            }.font(.system(size: 10)).foregroundStyle(.secondary).buttonStyle(.plain)
                .frame(height: SystemToolGridMetrics.pageFooterHeight)
        }.padding(.horizontal, 1)
    }
    private func toolButton(_ tool: SystemToolDefinition) -> some View {
        let installed = SystemToolActions.shared.isApplicationInstalled(for: tool.id)
        let actionLabel = tool.id == .recordCustom ? "Screen or Window" : tool.behavior.labelKey
        let helpLabel = tool.id == .recordCustom ? "Choose a screen or window. Video only; no system audio or microphone." : tool.behavior.labelKey
        return Button { activate(tool) } label: {
            VStack(spacing: 4) {
                SystemToolGlyph(tool: tool).font(.system(size: 18, weight: .medium)).frame(height: 22)
                Text(L(tool.titleKey)).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                Text(L(installed ? actionLabel : "Not installed")).font(.system(size: 8)).foregroundStyle(.white.opacity(0.5))
            }.foregroundStyle(.white.opacity(0.92)).frame(maxWidth: .infinity).frame(height: SystemToolGridMetrics.cardHeight)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).help(L(tool.titleKey) + " · " + L(helpLabel))
            .accessibilityLabel(L(tool.titleKey)).accessibilityHint(L(tool.id == .recordCustom ? "Choose a screen or window. Video only; no system audio or microphone." : tool.behavior.labelKey))
            .disabled(capture.isBusy || !installed)
    }
    private func activate(_ tool: SystemToolDefinition) {
        message = ""
        switch tool.behavior {
        case .capture:
            let kind: CaptureToolKind
            switch tool.id {
            case .captureScreen: kind = .fullScreenshot
            case .captureRegion: kind = .areaScreenshot
            case .captureWindow: kind = .windowScreenshot
            case .captureCustom: kind = .customScreenshot
            case .recordScreen: kind = .fullRecording
            case .recordRegion: kind = .areaRecording
            default: kind = .customRecording
            }
            capture.start(kind)
        case .utility(let kind):
            guard let page = UtilityWindowPage(rawValue: kind.rawValue) else { return }
            vm.close(force: true); UtilityClockWindow.shared.show(page)
        case .slider: break
        case .mediaHome: BoringViewCoordinator.shared.currentView = .home
        default:
            Task { @MainActor in
                let result = await SystemToolActions.shared.perform(tool.id)
                message = result.messageKey ?? ""
            }
        }
    }
}

private struct SystemToolTimeMachineTile: View {
    @ObservedObject private var backup = SystemTimeMachineControl.shared
    private var status: String {
        if backup.isBusy { return L("Checking backup status…") }
        if backup.errorKey != nil { return L("Unavailable · Retry") }
        if backup.running == true { return L("Stop Backup") }
        if backup.configAvailable == false { return L("Configure Backup") }
        return L(backup.running == nil ? "Checking backup status…" : "Start Backup")
    }
    var body: some View {
        Button {
            Task { @MainActor in
                if backup.errorKey != nil || backup.running == nil { await backup.refresh() }
                else if backup.running == true { await backup.stopBackup() }
                else if backup.configAvailable == false { _ = await SystemToolActions.shared.openTimeMachineSettings() }
                else { await backup.startBackup() }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 18, weight: .medium)).frame(height: 22)
                Text(L("Time Machine")).font(.system(size: 11, weight: .medium))
                Text(status).font(.system(size: 8))
                    .foregroundStyle(backup.errorKey == nil ? Color.white.opacity(0.5) : .orange)
            }.foregroundStyle(.white.opacity(0.92)).frame(maxWidth: .infinity).frame(height: SystemToolGridMetrics.cardHeight)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(backup.isBusy)
            .help(L(backup.errorKey ?? "Starts or stops the configured backup. Controls are unavailable when macOS backup status cannot be read."))
            .accessibilityLabel(L("Time Machine")).accessibilityValue(status)
            .task { await backup.refresh() }
    }
}

private struct SystemToolAppearanceTile: View {
    @ObservedObject private var appearance = SystemAppearanceControl.shared
    private var status: String {
        if appearance.isBusy { return L("Changing appearance…") }
        if appearance.errorKey != nil { return L("Unavailable · Retry") }
        guard let enabled = appearance.enabled else { return L("Toggle Dark Mode") }
        return L(enabled ? "Last change: Dark" : "Last change: Light")
    }
    var body: some View {
        Button { Task { @MainActor in await appearance.toggle() } } label: {
            VStack(spacing: 4) {
                Image(systemName: "moon").font(.system(size: 18, weight: .medium)).frame(height: 22)
                Text(L("Dark Mode")).font(.system(size: 11, weight: .medium))
                Text(status).font(.system(size: 8)).foregroundStyle(appearance.errorKey == nil ? Color.white.opacity(0.5) : .orange)
            }.foregroundStyle(.white.opacity(0.92)).frame(maxWidth: .infinity).frame(height: SystemToolGridMetrics.cardHeight)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(appearance.isBusy)
            .help(L(appearance.errorKey ?? "Toggle Dark Mode"))
            .accessibilityLabel(L("Dark Mode")).accessibilityValue(status)
            .accessibilityHint(L(appearance.errorKey ?? "Toggle Dark Mode"))
    }
}

private struct SystemToolWifiTile: View {
    @ObservedObject private var wifi = SystemWifiControl.shared
    private var status: String {
        if wifi.isBusy { return L("Reading hardware…") }
        if wifi.errorKey != nil { return L("Unavailable · Retry") }
        guard let enabled = wifi.enabled else { return L("Reading hardware…") }
        return L(enabled ? "Wi-Fi is on" : "Wi-Fi is off")
    }
    /// Clicking opens the macOS pane rather than toggling the radio: turning Wi-Fi off
    /// from a card that sits under the pointer is easy to trigger by accident and drops
    /// every network connection. The card keeps reporting the real radio state, and the
    /// context menu still offers a refresh.
    var body: some View {
        Button {
            Task { @MainActor in _ = await SystemToolActions.shared.openControlSettings(.wifi) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: wifi.enabled == false ? "wifi.slash" : "wifi")
                    .font(.system(size: 18, weight: .medium)).frame(height: 22)
                Text(L("Wi-Fi")).font(.system(size: 11, weight: .medium))
                Text(status).font(.system(size: 8)).foregroundStyle(wifi.errorKey == nil ? Color.white.opacity(0.5) : .orange)
            }.foregroundStyle(.white.opacity(0.92)).frame(maxWidth: .infinity).frame(height: SystemToolGridMetrics.cardHeight)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .help(L(wifi.errorKey ?? "Open Wi-Fi settings"))
            .accessibilityLabel(L("Wi-Fi")).accessibilityValue(status)
            .accessibilityHint(L("Open Wi-Fi settings"))
            .contextMenu {
                if let error = wifi.errorKey { Text(L(error)) }
                Button(L("Refresh")) { Task { @MainActor in await wifi.refresh() } }
                    .disabled(wifi.isBusy)
                Button(L("Open Wi-Fi settings")) {
                    Task { @MainActor in _ = await SystemToolActions.shared.openControlSettings(.wifi) }
                }
            }
            .task { await wifi.refresh() }
    }
}

private struct SystemToolSliderTile: View {
    let tool: SystemToolDefinition
    let kind: SystemToolSlider
    @ObservedObject private var volume = VolumeManager.shared
    @ObservedObject private var display = BrightnessManager.shared
    @ObservedObject private var keyboard = KeyboardBacklightManager.shared
    @State private var draft: Double?
    @State private var loaded = false
    private var actual: Double {
        switch kind {
        case .volume: Double(volume.rawVolume)
        case .displayBrightness: Double(display.rawBrightness)
        case .keyboardBrightness: Double(keyboard.rawBrightness)
        }
    }
    private var error: String? {
        switch kind { case .volume: volume.lastError; case .displayBrightness: display.lastError; case .keyboardBrightness: keyboard.lastError }
    }
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                SystemToolGlyph(tool: tool, lineWidth: 1.1, glyphHeight: 10)
                Text(L(tool.titleKey)).lineLimit(1).minimumScaleFactor(0.75)
            }.font(.system(size: 10, weight: .medium)).padding(.trailing, 10)
            Slider(value: Binding(get: { draft ?? actual }, set: { draft = $0; set($0) }), in: 0...1,
                   onEditingChanged: { editing in if !editing { draft = nil } })
                .controlSize(.mini).disabled(!loaded || error != nil)
                .accessibilityLabel(L(tool.titleKey))
            if !loaded {
                Text(L("Reading hardware…")).font(.system(size: 8)).foregroundStyle(.secondary)
            } else if let error {
                Button(L("Unavailable · Retry")) { refresh() }.font(.system(size: 8)).buttonStyle(.plain)
                    .help(L(error)).foregroundStyle(.orange)
            } else {
                Text("\(Int((actual * 100).rounded()))%").monospacedDigit().font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 9).frame(maxWidth: .infinity).frame(height: SystemToolGridMetrics.cardHeight)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
            .onAppear { refresh() }
    }
    private func refresh() {
        loaded = false
        Task { @MainActor in
            _ = await SystemToolActions.shared.readSlider(kind)
            loaded = true
        }
    }
    private func set(_ value: Double) {
        switch kind {
        case .volume: volume.setAbsolute(Float(value))
        case .displayBrightness: display.setAbsolute(value: Float(value))
        case .keyboardBrightness: keyboard.setAbsolute(value: Float(value))
        }
    }
}

struct SystemToolsSettings: View {
    @ObservedObject private var store = SystemToolConfigurationStore.shared
    @ObservedObject private var capture = CaptureTools.shared
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var expandedCategories: Set<SystemToolCategory> = []
    @ObservedObject private var reorderDiagnostics = ToolReorderDiagnostics.shared
    var body: some View {
        Form {
            Section {
                Text(L("Hold a handle and drag to reorder. Changes are saved immediately."))
                    .foregroundStyle(.secondary)
                ForEach(Array(store.selectedTools.enumerated()), id: \.element.id) { index, tool in
                    HStack {
                        ToolReorderHandle(tool: tool)
                        Label { Text(L(tool.titleKey)) } icon: { SystemToolGlyph(tool: tool, lineWidth: 1.3, glyphHeight: 14) }
                        Spacer()
                        Button { store.move(tool.id, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help(L("Move up"))
                        Button { store.move(tool.id, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == store.selectedTools.count - 1).help(L("Move down"))
                        Button { store.setVisible(false, id: tool.id) } label: { Image(systemName: "minus.circle") }.help(L("Remove from tools"))
                    }.buttonStyle(.borderless)
                        .padding(.vertical, 2)
                        .modifier(ToolReorderDropTarget(tool: tool, cornerRadius: 8))
                }
                Button(L("Reset tools to defaults")) { store.reset() }
                DisclosureGroup(L("Reorder diagnostics")) {
                    Text(L("Only drag event counts are kept in memory; no tool names, pointer positions or clipboard contents are recorded."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: reorderDiagnostics.summary)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button(L("Refresh drag diagnostics")) { reorderDiagnostics.refresh() }
                }
            } header: { Text(L("Shown tools & order")) }
            Section {
                toolSearchField
                if !search.isEmpty && !SystemToolCatalog.all.contains(where: matchesSearch) {
                    Text(L("No matching tools found")).foregroundStyle(.secondary)
                }
                ForEach(SystemToolCategory.allCases, id: \.self) { category in
                    let matching = SystemToolCatalog.all.filter { $0.category == category && matchesSearch($0) }
                    if !matching.isEmpty {
                        DisclosureGroup(isExpanded: expansion(of: category)) {
                            ForEach(matching) { tool in
                                Toggle(isOn: Binding(get: { store.configuration.visibleIDs.contains(tool.id.rawValue) },
                                    set: { store.setVisible($0, id: tool.id) })) {
                                    HStack {
                                        Label { Text(L(tool.titleKey)) } icon: { SystemToolGlyph(tool: tool, lineWidth: 1.3, glyphHeight: 14) }
                                        Spacer()
                                        Text(L(tool.behavior.labelKey)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityLabel(L(tool.titleKey))
                                .accessibilityHint(L(tool.behavior.labelKey))
                            }
                        } label: { Text(L(category.titleKey)) }
                    }
                }
            } header: { Text(L("Tool library")) }
            Section {
                Toggle(L("Automatically save system screenshots to the shelf"), isOn: $capture.automaticallyImportSystemScreenshots)
                Text(L("Only new screenshots in the system screenshot folder are copied. Original files are kept; old files and private app folders are not scanned."))
                    .font(.caption).foregroundStyle(.secondary)
                if !capture.externalImportAvailable {
                    Text(L("The screenshot folder is not readable. Grant access or use capture buttons in the island.")).foregroundStyle(.orange)
                }
                Button(L("Save clipboard files")) { capture.importClipboardFiles() }
                Text(capture.statusText).font(.caption).foregroundStyle(.secondary)
                if capture.status == .permissionRequired {
                    Button(L("Open screen recording permission")) { capture.openScreenRecordingSettings() }
                }
                if capture.isRecording { Button(L("Stop recording")) { capture.stopRecording() } }
                Text(L("During capture the island is hidden temporarily. A menu bar entry remains available to stop recording, even if the icon is normally hidden."))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L("Capture diagnostics")) {
                    Text(verbatim: capture.diagnosticsSummary)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            } header: { Text(L("Capture & shelf")) }
            Section {
                Text(L("Controls marked Open Settings open Apple's configuration page. They are not direct switches. Available options depend on macOS, hardware, and connected devices."))
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text(L("System compatibility")) }
        }.navigationTitle(Text(verbatim: L("Quick tools")))
    }

    /// A `Form` row draws a `TextField`'s title as a leading label rather than as
    /// placeholder text, which would leave the hint permanently visible and shrink the
    /// editable area to whatever space is left at the trailing edge. `prompt` puts the
    /// hint inside the field so typing replaces it, and `labelsHidden` reclaims the
    /// label column the empty title would otherwise reserve.
    ///
    /// The rounded border is painted around the whole row, so the tap target is widened
    /// to match: taking `contentShape` after the padding lets a click anywhere in the
    /// box — including the magnifier and the surrounding inset — put the caret in the
    /// field, instead of only the text control's own narrow frame.
    private var toolSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("", text: $search, prompt: Text(L("Find a system tool")))
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("Clear search")).accessibilityLabel(L("Clear search"))
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onTapGesture { searchFocused = true }
    }

    private func matchesSearch(_ tool: SystemToolDefinition) -> Bool {
        search.isEmpty
            || L(tool.titleKey).localizedCaseInsensitiveContains(search)
            || tool.titleKey.localizedCaseInsensitiveContains(search)
    }

    /// While a query is active every rendered category opens, so a match is never
    /// hidden behind another click. Manual expansion is left untouched meanwhile and
    /// comes back exactly as it was once the field is cleared.
    private func expansion(of category: SystemToolCategory) -> Binding<Bool> {
        Binding(
            get: { !search.isEmpty || expandedCategories.contains(category) },
            set: { isExpanded in
                guard search.isEmpty else { return }
                if isExpanded { expandedCategories.insert(category) } else { expandedCategories.remove(category) }
            })
    }
}

/// A dedicated native handle keeps dragging separate from tool clicks and sliders.
private struct ToolReorderHandle: View {
    let tool: SystemToolDefinition
    @ObservedObject private var store = SystemToolConfigurationStore.shared

    var body: some View {
        NativeToolReorderHandle(
            payload: .init(toolID: tool.id.rawValue, sourceID: store.dragSourceID),
            title: L(tool.titleKey), symbolName: tool.symbol,
            hint: L("Drag to reorder") + " · " + L(tool.titleKey))
            .frame(width: 24, height: 24)
    }
}

private struct ToolReorderDropTarget: ViewModifier {
    let tool: SystemToolDefinition
    let cornerRadius: CGFloat
    @ObservedObject private var store = SystemToolConfigurationStore.shared

    func body(content: Content) -> some View {
        content.overlay {
            NativeToolReorderDropTarget(cornerRadius: cornerRadius,
                canDrop: { store.configuration.canDrop($0, on: tool.id.rawValue, sourceID: store.dragSourceID) },
                performDrop: { store.drop($0, on: tool.id) })
        }
    }
}
