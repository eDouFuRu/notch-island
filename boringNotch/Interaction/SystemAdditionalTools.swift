import SwiftUI

/// The card shows a confirmed system reading. No toggle is run by appearing,
/// refreshing, opening Settings, or adding the card to the user's layout.
struct SystemToolBluetoothTile: View {
    @ObservedObject private var control = SystemBluetoothControl.shared

    private var authorizationText: String {
        if control.isRequestingAccess { return L("Waiting for a Bluetooth permission decision in macOS.") }
        let key: String
        switch control.authorization {
        case .notDetermined: key = "Bluetooth access has not been requested for this app."
        case .denied: key = "Bluetooth access is denied for this app."
        case .restricted: key = "Bluetooth access is restricted for this app."
        case .allowed: key = "Bluetooth access is allowed for this app."
        case .unknown: key = "Bluetooth access status is not available."
        }
        return L(key)
    }

    var body: some View {
        // Clicking opens the macOS pane rather than toggling the radio: switching
        // Bluetooth off from a card under the pointer is easy to hit by accident and
        // disconnects every paired device, including the keyboard and trackpad needed
        // to undo it. The card still reports the real radio state.
        SystemToggleTile(tool: .bluetooth, enabled: control.enabled,
            isBusy: control.isBusy, unsupported: control.availability == .unsupported,
            errorKey: control.errorKey,
            helpKey: "Opens Bluetooth settings. The card shows the current radio state.",
            blocksWhileBusy: false) {
                Task { @MainActor in
                    _ = await SystemToolActions.shared.openControlSettings(.bluetooth)
                }
            }
            .contextMenu {
                Text(verbatim: authorizationText)
                if let error = control.errorKey { Text(L(error)) }
                if control.authorization == .notDetermined {
                    Button(L("Request Bluetooth access")) { control.requestAccess() }
                        .disabled(control.isRequestingAccess)
                }
                Button(L("Refresh")) { Task { @MainActor in await control.refresh() } }
                    .disabled(control.isBusy)
                Button(L("Open Bluetooth settings")) {
                    Task { @MainActor in _ = await SystemToolActions.shared.openControlSettings(.bluetooth) }
                }
            }
            .task { await control.refresh() }
    }
}

struct SystemToolNightShiftTile: View {
    @ObservedObject private var control = SystemNightShiftControl.shared
    private var unsupported: Bool {
        control.availability == .unsupportedABI || control.availability == .unsupportedHardware
    }

    var body: some View {
        SystemToggleTile(tool: .nightShift, enabled: control.enabled,
            isBusy: control.isBusy, unsupported: unsupported, errorKey: control.errorKey,
            helpKey: "Toggles Night Shift without changing its schedule or color temperature.") {
                Task { @MainActor in
                    if unsupported {
                        _ = await SystemToolActions.shared.openControlSettings(.displays)
                    } else if control.errorKey != nil || control.enabled == nil {
                        await control.refresh()
                    } else { await control.toggle() }
                }
            }
            .task { await control.refresh() }
    }
}

struct SystemToolTrueToneTile: View {
    @ObservedObject private var control = SystemTrueToneControl.shared

    var body: some View {
        SystemToggleTile(tool: .trueTone, enabled: control.enabled,
            isBusy: control.isBusy, unsupported: control.availability == .unsupportedABI,
            errorKey: control.errorKey,
            helpKey: "Available only when macOS confirms support.") {
                Task { @MainActor in
                    if control.availability == .unsupportedABI {
                        _ = await SystemToolActions.shared.openControlSettings(.displays)
                    } else if control.errorKey != nil || control.enabled == nil {
                        await control.refresh()
                    } else { await control.toggle() }
                }
            }
            .task { await control.refresh() }
    }
}

private struct SystemToggleTile: View {
    let tool: SystemToolID
    let enabled: Bool?
    let isBusy: Bool
    let unsupported: Bool
    let errorKey: String?
    let helpKey: String
    /// Toggling tiles block input while a change is in flight so the state cannot be
    /// flipped twice. A tile that only opens System Settings has nothing to serialise, and
    /// blocking it would make the card dead during a routine status refresh.
    var blocksWhileBusy = true
    let action: () -> Void

    private var status: String {
        if isBusy { return L("Reading hardware…") }
        if unsupported { return L("Unsupported · Open Settings") }
        if errorKey != nil { return L("Unavailable · Retry") }
        guard let enabled else { return L("Reading hardware…") }
        return L(enabled ? "On" : "Off")
    }

    var body: some View {
        let definition = SystemToolCatalog.tool(tool)
        Button(action: action) {
            SystemToolStateLabel(tool: definition, status: status, hasError: errorKey != nil)
        }
        .buttonStyle(.plain).disabled(isBusy && blocksWhileBusy)
        .accessibilityLabel(L(definition.titleKey)).accessibilityValue(status)
        .help(L(errorKey ?? helpKey))
    }
}

struct SystemToolInputSourceTile: View {
    @ObservedObject private var control = SystemInputSourceControl.shared
    private func sourceLabel(_ item: InputSourceMenuItem) -> String {
        guard let parent = item.parentName, parent != item.displayName else { return item.displayName }
        return item.displayName + " · " + parent
    }
    private var status: String {
        if control.isBusy { return L("Reading input sources…") }
        if control.errorKey != nil { return L("Unavailable · Retry") }
        return control.currentName ?? L("Choose Input Source")
    }

    var body: some View {
        SystemToolPickerTile(tool: SystemToolCatalog.tool(.inputSources), status: status,
                             hasError: control.errorKey != nil, name: L("Input Sources"),
                             help: L(control.errorKey ?? "Choose an enabled keyboard input source.")) { dismiss in
            if let error = control.errorKey { SystemToolPickerNote(text: L(error), isError: true) }
            ForEach(control.sources) { item in
                SystemToolPickerRow(title: sourceLabel(item), isSelected: item.id == control.selectedID,
                                    isEnabled: !control.isBusy) {
                    dismiss()
                    Task { @MainActor in await control.select(id: item.id) }
                }
            }
            Divider()
            SystemToolPickerRow(title: L("Refresh"), isEnabled: !control.isBusy) {
                Task { @MainActor in await control.refresh() }
            }
            SystemToolPickerRow(title: L("Open keyboard settings")) {
                dismiss()
                Task { @MainActor in _ = await SystemToolActions.shared.openControlSettings(.keyboard) }
            }
        }
        .task { await control.refresh() }
    }
}

struct SystemToolAudioOutputTile: View {
    @ObservedObject private var control = SystemAudioOutputControl.shared

    private var status: String {
        if control.isBusy { return L("Reading audio outputs…") }
        if control.errorKey != nil { return L("Unavailable · Retry") }
        return control.currentName ?? L("Choose Audio Output")
    }

    var body: some View {
        SystemToolPickerTile(tool: SystemToolCatalog.tool(.sound), status: status,
                             hasError: control.errorKey != nil, name: L("Sound & Audio Output"),
                             help: L(control.errorKey ?? "Choose an available audio output. Each device keeps its own volume; system alert output stays unchanged.")) { dismiss in
            if let error = control.errorKey { SystemToolPickerNote(text: L(error), isError: true) }
            ForEach(control.devices) { device in
                SystemToolPickerRow(title: device.displayName, isSelected: device.id == control.selectedID,
                                    isEnabled: !control.isBusy && control.canSelect) {
                    dismiss()
                    Task { @MainActor in await control.select(id: device.id) }
                }
            }
            Divider()
            SystemToolPickerRow(title: L("Refresh"), isEnabled: !control.isBusy) {
                Task { @MainActor in await control.refresh() }
            }
            SystemToolPickerRow(title: L("Open sound settings")) {
                dismiss()
                Task { @MainActor in _ = await SystemToolActions.shared.openControlSettings(.sound) }
            }
        }
        .task { await control.refresh() }
    }
}

struct SystemToolDisplayModeTile: View {
    @ObservedObject private var control = SystemDisplayModeControl.shared

    private var status: String {
        if control.isBusy { return L("Reading display modes…") }
        if control.errorKey != nil { return L("Unavailable · Retry") }
        if control.displays.count == 1, let display = control.displays.first,
           let mode = display.modes.first(where: { $0.id == display.currentModeID }) {
            return mode.resolutionLabel
        }
        return String(format: L("%d displays"), control.displays.count)
    }

    private func modeLabel(_ mode: DisplayModeOption) -> String {
        [mode.resolutionLabel, mode.isHiDPI ? "HiDPI" : nil,
         mode.refreshRateLabel ?? L("System Default")]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        SystemToolPickerTile(tool: SystemToolCatalog.tool(.display), status: status,
                             hasError: control.errorKey != nil, name: L("Display"),
                             help: L(control.errorKey ?? "Display changes last while the island is running. macOS restores the previous mode when the app quits.")) { dismiss in
            SystemToolPickerNote(text: L("Display changes last while the island is running. macOS restores the previous mode when the app quits."))
            if let error = control.errorKey { SystemToolPickerNote(text: L(error), isError: true) }
            ForEach(control.displays) { display in
                SystemToolPickerDisclosure(title: display.isBuiltIn ? L("Built-in Display")
                                                                    : String(format: L("Display %d"), display.ordinal),
                                           startsExpanded: control.displays.count == 1) {
                    if display.isMirrored {
                        SystemToolPickerNote(text: L("Changing this mirrored display may also change the other displays in its mirror group."))
                    }
                    ForEach(display.modes) { mode in
                        SystemToolPickerRow(title: modeLabel(mode), isSelected: mode.id == display.currentModeID,
                                            isEnabled: !control.isBusy) {
                            dismiss()
                            Task { @MainActor in await control.select(displayID: display.id, mode: mode) }
                        }
                    }
                }
            }
            Divider()
            SystemToolPickerRow(title: L("Refresh"), isEnabled: !control.isBusy) {
                Task { @MainActor in await control.refresh() }
            }
            SystemToolPickerRow(title: L("Open display settings")) {
                dismiss()
                Task { @MainActor in _ = await SystemToolActions.shared.openControlSettings(.displays) }
            }
        }
        .task { await control.refresh() }
    }
}

struct SystemToolVPNTile: View {
    @ObservedObject private var control = SystemVPNControl.shared

    private var status: String {
        if control.isBusy { return L("Updating VPN connections…") }
        if control.errorKey != nil { return L("Unavailable · Retry") }
        if control.services.count == 1, let service = control.services.first { return L(service.status.labelKey) }
        if control.services.isEmpty { return L("No controllable VPN found") }
        return String(format: L("%d VPN connections"), control.services.count)
    }

    var body: some View {
        SystemToolPickerTile(tool: SystemToolCatalog.tool(.vpn), status: status,
                             hasError: control.errorKey != nil, name: L("VPN"),
                             help: L(control.errorKey ?? "Controls configured VPNs listed by macOS. Some third-party clients must be operated in their own apps.")) { dismiss in
            SystemToolPickerNote(text: L("Controls configured VPNs listed by macOS. Some third-party clients must be operated in their own apps."))
            if let error = control.errorKey { SystemToolPickerNote(text: L(error), isError: true) }
            if control.services.isEmpty { SystemToolPickerNote(text: L("No controllable VPN found")) }
            ForEach(control.services) { service in
                SystemToolPickerDisclosure(title: service.displayName + " · " + L(service.status.labelKey),
                                           startsExpanded: control.services.count == 1) {
                    SystemToolPickerRow(title: L(service.status == .connected ? "Disconnect VPN" : "Connect VPN"),
                                        isEnabled: !control.isBusy && service.canToggle) {
                        dismiss()
                        Task { @MainActor in
                            await control.setConnected(id: service.id, connected: service.status != .connected)
                        }
                    }
                }
            }
            Divider()
            SystemToolPickerRow(title: L("Refresh"), isEnabled: !control.isBusy) {
                Task { @MainActor in await control.refresh() }
            }
            SystemToolPickerRow(title: L("Open VPN settings")) {
                dismiss()
                Task { @MainActor in _ = await SystemToolActions.shared.openControlSettings(.vpn) }
            }
        }
        .task { await control.monitorWhileVisible() }
    }
}

struct SystemToolAccessibilityDisplayTile: View {
    let feature: AccessibilityDisplayFeature
    @ObservedObject private var control = SystemAccessibilityDisplayControl.shared

    private var tool: SystemToolID { feature == .increaseContrast ? .increaseContrast : .reduceTransparency }
    private var enabled: Bool? { control.states[feature] }
    private var lockedByContrast: Bool {
        feature == .reduceTransparency && enabled == true && control.states[.increaseContrast] == true
    }
    private var status: String {
        if control.isBusy { return L("Reading display accessibility…") }
        if !control.supportedFeatures.contains(feature) { return L("Unsupported · Open Settings") }
        if control.errorKey != nil || enabled == nil { return L("Unavailable · Retry") }
        if lockedByContrast { return L("Required by Increase Contrast") }
        return L(enabled == true ? "On" : "Off")
    }
    private var explanation: String {
        "Increase Contrast also reduces transparency; turn it off first to change transparency."
    }

    var body: some View {
        Button {
            Task { @MainActor in
                if !control.supportedFeatures.contains(feature) {
                    _ = await SystemToolActions.shared.openControlSettings(.displayAccessibility)
                } else if control.errorKey != nil || enabled == nil {
                    await control.refresh()
                } else if let enabled {
                    await control.toggle(feature: feature, expectedEnabled: enabled)
                }
            }
        } label: {
            SystemToolStateLabel(tool: SystemToolCatalog.tool(tool), status: status,
                                 hasError: control.errorKey != nil)
        }
        .buttonStyle(.plain).disabled(control.isBusy || lockedByContrast)
        .accessibilityLabel(L(SystemToolCatalog.tool(tool).titleKey)).accessibilityValue(status)
        .help(L(control.errorKey ?? explanation))
        .contextMenu {
            Text(L(explanation))
            if let error = control.errorKey { Text(L(error)) }
            Button(L("Refresh")) { Task { @MainActor in await control.refresh() } }
                .disabled(control.isBusy)
            Button(L("Open display accessibility settings")) {
                Task { @MainActor in _ = await SystemToolActions.shared.openControlSettings(.displayAccessibility) }
            }
        }
        .task { await control.refresh() }
    }
}

/// macOS draws a `Menu` label through an `NSPopUpButton`, which flattens any custom
/// view down to a title plus image and reports a frame smaller than the card it
/// paints. Pickers therefore use a plain button and a popover so the tile keeps the
/// same stacked card as every other tool, and so the reorder handle stays pinned to
/// the real top-right corner.
struct SystemToolPickerTile<Content: View>: View {
    let tool: SystemToolDefinition
    let status: String
    let hasError: Bool
    let name: String
    let help: String
    @ViewBuilder let content: (_ dismiss: @escaping () -> Void) -> Content

    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            SystemToolStateLabel(tool: tool, status: status, hasError: hasError)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    content { isPresented = false }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 280)
            .frame(maxHeight: 340)
        }
        .notchHoldsOpenWhilePopoverPresented($isPresented)
        .accessibilityLabel(name).accessibilityValue(status)
        .accessibilityHint(L("Opens the list of options"))
        .help(help)
    }
}

/// A selectable line inside a picker popover.
struct SystemToolPickerRow: View {
    let title: String
    var isSelected: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").opacity(isSelected ? 1 : 0).font(.caption)
                Text(verbatim: title).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Explanatory or error text inside a picker popover.
struct SystemToolPickerNote: View {
    let text: String
    var isError = false

    var body: some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(isError ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A collapsible group inside a picker popover, used where menus previously
/// nested. One display can expose dozens of modes, so the groups fold to keep
/// the list scannable; `startsExpanded` lets a lone group stay open so the
/// common single-display / single-VPN case costs no extra click.
struct SystemToolPickerDisclosure<Content: View>: View {
    let title: String
    var startsExpanded = true
    @ViewBuilder let content: () -> Content

    /// `nil` until the user touches the group, so the default keeps tracking the
    /// data while an explicit choice always wins afterwards.
    @State private var isExpanded: Bool?

    var body: some View {
        let expanded = Binding(get: { isExpanded ?? startsExpanded }, set: { isExpanded = $0 })
        // `DisclosureGroup` only makes its chevron tappable, which is a small target in a
        // popover this narrow. The label stretches across the row and toggles the same
        // binding, so the title text opens the group too.
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 3) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(verbatim: title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { expanded.wrappedValue.toggle() }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SystemToolStateLabel: View {
    let tool: SystemToolDefinition
    let status: String
    let hasError: Bool

    var body: some View {
        VStack(spacing: 4) {
            SystemToolGlyph(tool: tool).font(.system(size: 18, weight: .medium)).frame(height: 22)
            Text(L(tool.titleKey)).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text(verbatim: status).font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(hasError ? Color.orange : Color.white.opacity(0.6))
        }
        .foregroundStyle(.white.opacity(0.92)).frame(maxWidth: .infinity).frame(height: SystemToolGridMetrics.cardHeight)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
