import AppKit
import ApplicationServices

enum SystemToolActionResult: Equatable {
    /// macOS accepted the launch. This is not an assertion that a setting was toggled.
    case launched
    case adjusted
    case needsInIslandControl
    case unavailable(String)
    case failed(String)

    var messageKey: String? {
        switch self {
        case .unavailable(let message), .failed(let message): message
        case .launched, .adjusted, .needsInIslandControl: nil
        }
    }
}

struct SystemToolSliderState: Equatable {
    let value: Double?
    let errorKey: String?
    var isAvailable: Bool { value != nil && errorKey == nil }
}

/// Production actions only use checked app/settings launches or the existing hardware
/// managers. Capturing and the island's utility windows are handled by the Tools view.
@MainActor
final class SystemToolActions {
    static let shared = SystemToolActions()

    func perform(_ id: SystemToolID) async -> SystemToolActionResult {
        switch SystemToolCatalog.tool(id).behavior {
        case .capture, .utility, .slider, .mediaHome, .wifiPower, .timeMachineBackup,
             .bluetoothPower, .nightShiftToggle, .trueToneToggle, .inputSourcePicker, .audioOutputPicker,
             .displayModePicker, .vpnConnectionPicker, .accessibilityDisplayToggle:
            return .needsInIslandControl
        case .appearanceToggle:
            let result = await SystemAppearanceControl.shared.toggle()
            if let failure = result.failure { return .failed(failure.messageKey) }
            return .adjusted
        case .mute:
            VolumeManager.shared.toggleMuteAction()
            if let error = VolumeManager.shared.lastError { return .failed(error) }
            return .adjusted
        case .nativeApp(let identifier, let path):
            return await openApplication(identifier: identifier, fallbackPath: path)
        case .systemSettings(let pane):
            return await openSettings(pane)
        case .systemShortcut(let shortcut):
            return performShortcut(shortcut)
        }
    }

    func openTimeMachineSettings() async -> SystemToolActionResult {
        await openSettings(.timeMachine)
    }

    func openControlSettings(_ pane: SystemToolSettingsPane) async -> SystemToolActionResult {
        await openSettings(pane)
    }

    /// Refreshes from actual hardware before showing a slider. In particular, a Mac
    /// without a readable keyboard backlight must not present a fake enabled slider.
    func readSlider(_ kind: SystemToolSlider) async -> SystemToolSliderState {
        switch kind {
        case .volume:
            let manager = VolumeManager.shared
            manager.refresh()
            return .init(value: manager.lastError == nil ? Double(manager.rawVolume) : nil,
                         errorKey: manager.lastError)
        case .displayBrightness:
            return await readBrightness(BrightnessManager.shared)
        case .keyboardBrightness:
            return await readBrightness(KeyboardBacklightManager.shared)
        }
    }

    func setSlider(_ kind: SystemToolSlider, value: Double) async -> SystemToolSliderState {
        guard value.isFinite, (0...1).contains(value) else {
            return .init(value: nil, errorKey: "Invalid control value.")
        }
        switch kind {
        case .volume:
            let manager = VolumeManager.shared
            manager.setAbsolute(Float(value))
            return .init(value: manager.lastError == nil ? Double(manager.rawVolume) : nil,
                         errorKey: manager.lastError)
        case .displayBrightness:
            return await setBrightness(BrightnessManager.shared, value: value)
        case .keyboardBrightness:
            return await setBrightness(KeyboardBacklightManager.shared, value: value)
        }
    }

    func isApplicationInstalled(for id: SystemToolID) -> Bool {
        guard case let .nativeApp(identifier, path) = SystemToolCatalog.tool(id).behavior else { return true }
        return applicationURL(identifier: identifier, fallbackPath: path) != nil
    }

    private func readBrightness(_ manager: HardwareBrightnessManager) async -> SystemToolSliderState {
        manager.refresh()
        await manager.waitUntilIdle()
        return .init(value: manager.lastError == nil ? Double(manager.rawBrightness) : nil,
                     errorKey: manager.lastError)
    }

    private func setBrightness(_ manager: HardwareBrightnessManager, value: Double) async -> SystemToolSliderState {
        manager.setAbsolute(value: Float(value))
        await manager.waitUntilIdle()
        return .init(value: manager.lastError == nil ? Double(manager.rawBrightness) : nil,
                     errorKey: manager.lastError)
    }

    private func applicationURL(identifier: String, fallbackPath: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        let url = URL(fileURLWithPath: fallbackPath)
        guard FileManager.default.fileExists(atPath: fallbackPath),
              Bundle(url: url)?.bundleIdentifier == identifier else { return nil }
        return url
    }

    private func openApplication(identifier: String, fallbackPath: String) async -> SystemToolActionResult {
        guard let url = applicationURL(identifier: identifier, fallbackPath: fallbackPath) else {
            return .unavailable("This system app is not installed on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return .launched
        } catch {
            return .failed("Unable to open the system app.")
        }
    }

    private func openSettings(_ pane: SystemToolSettingsPane) async -> SystemToolActionResult {
        guard let url = URL(string: pane.urlString),
              let settings = applicationURL(identifier: "com.apple.systempreferences",
                                            fallbackPath: "/System/Applications/System Settings.app") else {
            return .unavailable("System Settings is unavailable on this Mac.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: settings, configuration: configuration)
            return .launched
        } catch {
            return .failed("Unable to open System Settings.")
        }
    }

    /// Called only after a user explicitly clicks the corresponding tool. Never runs
    /// during launch, catalog enumeration, availability checks, or automated tests.
    private func performShortcut(_ shortcut: SystemToolShortcut) -> SystemToolActionResult {
        guard AXIsProcessTrusted() else {
            return .unavailable("Accessibility access is required to run this system shortcut.")
        }
        switch shortcut {
        case .lockScreen:
            // Apple's Control-Command-Q shortcut, emitted as a paired key event.
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: false) else {
                return .failed("Unable to run the system shortcut.")
            }
            down.flags = [.maskControl, .maskCommand]
            up.flags = [.maskControl, .maskCommand]
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            // Events were submitted. The UI must not claim the screen is already locked.
            return .launched
        }
    }
}
