import Foundation

/// Stable identifiers are persisted; translated names never become preference keys.
enum SystemToolID: String, CaseIterable, Codable, Identifiable, Sendable {
    case captureScreen, captureRegion, captureWindow, captureCustom
    case recordScreen, recordRegion, recordCustom
    case stopwatch, timer, alarm, clock, calculator, notes, voiceMemos, shortcuts
    case volume, displayBrightness, keyboardBrightness, mute, media
    case wifi, bluetooth, airDrop, focus, screenMirroring, stageManager
    case display, darkMode, nightShift, trueTone, sound, battery, energyMode
    case keyboard, inputSources, vpn, network, fastUserSwitching, timeMachine
    case controlCenter, siri, spotlight, recognizeMusic, weather, home
    case accessibility, hearing, backgroundSounds, liveCaptions, liveSpeech
    case voiceOver, zoom, hoverText, hoverTyping, colorFilters, invertColors
    case increaseContrast, reduceMotion, reduceTransparency, accessibilityReader
    case voiceControl, switchControl, fullKeyboardAccess, accessibilityKeyboard
    case stickyKeys, slowKeys, mouseKeys, headPointer, vehicleMotionCues
    case screenSaver, lockScreen, magnifier, reminders

    var id: String { rawValue }
}

enum SystemToolCategory: String, CaseIterable, Codable, Sendable {
    case capture, utilities, displayAndSound, connectivity, system, accessibility

    var titleKey: String {
        switch self {
        case .capture: "Capture & Recording"
        case .utilities: "Everyday Utilities"
        case .displayAndSound: "Display & Sound"
        case .connectivity: "Connectivity"
        case .system: "System Controls"
        case .accessibility: "Accessibility"
        }
    }
}

enum SystemUtilityKind: String, Codable, Sendable { case stopwatch, timer, alarm }
enum SystemToolSlider: String, Codable, Sendable { case volume, displayBrightness, keyboardBrightness }
enum SystemToolShortcut: String, Codable, Sendable { case lockScreen }

/// The capability is explicit: settings launchers must not look like active switches.
enum SystemToolBehavior: Equatable, Sendable {
    case capture
    case utility(SystemUtilityKind)
    case slider(SystemToolSlider)
    case wifiPower
    case bluetoothPower
    case nightShiftToggle
    case trueToneToggle
    case inputSourcePicker
    case audioOutputPicker
    case displayModePicker
    case vpnConnectionPicker
    case accessibilityDisplayToggle(AccessibilityDisplayFeature)
    case appearanceToggle
    case timeMachineBackup
    case nativeApp(bundleIdentifier: String, path: String)
    case systemSettings(SystemToolSettingsPane)
    case systemShortcut(SystemToolShortcut)
    case mute
    case mediaHome

    var labelKey: String {
        switch self {
        case .capture: "Capture"
        case .utility: "Open Tool"
        case .slider: "Adjust Here"
        case .wifiPower: "Wi-Fi Control"
        case .bluetoothPower: "Bluetooth Control"
        case .nightShiftToggle: "Night Shift Control"
        case .trueToneToggle: "True Tone Control"
        case .inputSourcePicker: "Choose Input Source"
        case .audioOutputPicker: "Choose Audio Output"
        case .displayModePicker: "Choose Display Mode"
        case .vpnConnectionPicker: "VPN Connections"
        case .accessibilityDisplayToggle: "Display Accessibility"
        case .appearanceToggle: "Toggle Dark Mode"
        case .timeMachineBackup: "Backup Controls"
        case .nativeApp: "Open App"
        case .systemSettings: "Open Settings"
        case .systemShortcut: "Run Action"
        case .mute: "Toggle Mute"
        case .mediaHome: "Open Player"
        }
    }
}

/// Routes use the settings extension identifiers present on macOS Tahoe. These launch
/// Apple's controls; they do not modify private preferences or imply a toggle succeeded.
enum SystemToolSettingsPane: String, Sendable {
    case wifi, bluetooth, airDrop, focus, displays, desktop, sound, battery
    case keyboard, vpn, network, users, timeMachine, controlCenter, siri, spotlight
    case accessibility, hearing, audio, liveCaptions, liveSpeech, voiceOver, zoom
    case hoverText, displayAccessibility, motion, reader, voiceControl, switchControl
    case keyboardAccessibility, pointerControl, screenSaver, lockScreen, appearance

    var urlString: String {
        let identifier: String
        switch self {
        case .wifi: identifier = "com.apple.wifi-settings-extension"
        case .bluetooth: identifier = "com.apple.BluetoothSettings"
        case .airDrop: identifier = "com.apple.AirDrop-Handoff-Settings.extension"
        case .focus: identifier = "com.apple.Focus-Settings.extension"
        case .displays: identifier = "com.apple.Displays-Settings.extension"
        case .desktop: identifier = "com.apple.Desktop-Settings.extension"
        case .sound: identifier = "com.apple.Sound-Settings.extension"
        case .battery: identifier = "com.apple.preference.battery"
        case .keyboard: identifier = "com.apple.Keyboard-Settings.extension"
        case .vpn: identifier = "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension"
        case .network: identifier = "com.apple.Network-Settings.extension"
        case .users: identifier = "com.apple.Users-Groups-Settings.extension"
        case .timeMachine: identifier = "com.apple.Time-Machine-Settings.extension"
        case .controlCenter: identifier = "com.apple.ControlCenter-Settings.extension"
        case .siri: identifier = "com.apple.Siri-Settings.extension"
        case .spotlight: identifier = "com.apple.Spotlight-Settings.extension"
        case .accessibility: identifier = "com.apple.Accessibility-Settings.extension"
        case .hearing: identifier = "com.apple.preference.universalaccess?Hearing"
        case .audio: identifier = "com.apple.preference.universalaccess?Audio"
        case .liveCaptions: identifier = "com.apple.preference.universalaccess?LiveCaptions"
        case .liveSpeech: identifier = "com.apple.preference.universalaccess?LiveSpeech"
        case .voiceOver: identifier = "com.apple.preference.universalaccess?Seeing_VoiceOver"
        case .zoom: identifier = "com.apple.preference.universalaccess?Seeing_Zoom"
        case .hoverText: identifier = "com.apple.preference.universalaccess?HoverText"
        case .displayAccessibility: identifier = "com.apple.preference.universalaccess?Seeing_Display"
        case .motion: identifier = "com.apple.preference.universalaccess?Motion"
        case .reader: identifier = "com.apple.preference.universalaccess?AccessibilityReader"
        case .voiceControl: identifier = "com.apple.preference.universalaccess?VoiceControl"
        case .switchControl: identifier = "com.apple.preference.universalaccess?SwitchControl"
        case .keyboardAccessibility: identifier = "com.apple.preference.universalaccess?Keyboard"
        case .pointerControl: identifier = "com.apple.preference.universalaccess?Mouse"
        case .screenSaver: identifier = "com.apple.Wallpaper-Settings.extension"
        case .lockScreen: identifier = "com.apple.Lock-Screen-Settings.extension"
        case .appearance: identifier = "com.apple.Appearance-Settings.extension"
        }
        return "x-apple.systempreferences:" + identifier
    }
}

/// Tools whose glyph has no SF Symbol equivalent and is drawn by the app instead.
enum SystemToolCustomIcon: Equatable, Sendable {
    case bluetoothRune
}

struct SystemToolDefinition: Identifiable, Equatable, Sendable {
    let id: SystemToolID
    let titleKey: String
    let symbol: String
    let category: SystemToolCategory
    let behavior: SystemToolBehavior
    /// `symbol` stays populated even when this is set: the AppKit drag preview can
    /// only render an `NSImage(systemSymbolName:)` and falls back to it.
    var customIcon: SystemToolCustomIcon?
}

enum SystemToolCatalog {
    /// A small initial board; every catalog item can be added and reordered in Settings.
    static let defaultVisible: [SystemToolID] = [
        .captureScreen, .captureRegion, .captureWindow, .captureCustom,
        .recordScreen, .recordRegion, .stopwatch, .timer, .alarm,
        .calculator, .notes, .volume, .displayBrightness, .keyboardBrightness
    ]
    static let defaultOrderedIDs = defaultVisible.map(\.rawValue)

    static let all: [SystemToolDefinition] = [
        item(.captureScreen, "Full-Screen Screenshot", "rectangle.dashed.badge.record", .capture, .capture),
        item(.captureRegion, "Area Screenshot", "crop", .capture, .capture),
        item(.captureWindow, "Window Screenshot", "macwindow", .capture, .capture),
        item(.captureCustom, "Custom Screenshot", "camera.viewfinder", .capture, .capture),
        item(.recordScreen, "Screen Recording", "record.circle", .capture, .capture),
        item(.recordRegion, "Area Recording", "viewfinder", .capture, .capture),
        item(.recordCustom, "Custom Recording", "slider.horizontal.3", .capture, .capture),
        item(.stopwatch, "Stopwatch", "stopwatch", .utilities, .utility(.stopwatch)),
        item(.timer, "Timer", "timer", .utilities, .utility(.timer)),
        item(.alarm, "Alarm", "alarm", .utilities, .utility(.alarm)),
        app(.clock, "Clock", "clock", "/System/Applications/Clock.app", "com.apple.clock"),
        app(.calculator, "Calculator", "plus.forwardslash.minus", "/System/Applications/Calculator.app", "com.apple.calculator"),
        app(.notes, "Notes", "note.text", "/System/Applications/Notes.app", "com.apple.Notes"),
        app(.voiceMemos, "Voice Memos", "waveform", "/System/Applications/VoiceMemos.app", "com.apple.VoiceMemos"),
        app(.shortcuts, "Shortcuts", "square.stack.3d.up", "/System/Applications/Shortcuts.app", "com.apple.shortcuts"),
        item(.volume, "Volume", "speaker.wave.2", .displayAndSound, .slider(.volume)),
        item(.displayBrightness, "Display Brightness", "sun.max", .displayAndSound, .slider(.displayBrightness)),
        item(.keyboardBrightness, "Keyboard Brightness", "light.max", .displayAndSound, .slider(.keyboardBrightness)),
        item(.mute, "Mute", "speaker.slash", .displayAndSound, .mute),
        item(.media, "Now Playing", "play.rectangle", .displayAndSound, .mediaHome),
        item(.display, "Display", "display", .displayAndSound, .displayModePicker),
        .init(id: .darkMode, titleKey: "Dark Mode", symbol: "moon", category: .displayAndSound, behavior: .appearanceToggle),
        item(.nightShift, "Night Shift", "sun.horizon", .displayAndSound, .nightShiftToggle),
        item(.trueTone, "True Tone", "sun.max.circle", .displayAndSound, .trueToneToggle),
        item(.sound, "Sound & Audio Output", "hifispeaker", .displayAndSound, .audioOutputPicker),
        item(.wifi, "Wi-Fi", "wifi", .connectivity, .wifiPower),
        .init(id: .bluetooth, titleKey: "Bluetooth", symbol: "antenna.radiowaves.left.and.right",
              category: .connectivity, behavior: .bluetoothPower, customIcon: .bluetoothRune),
        settings(.airDrop, "AirDrop", "airplayaudio", .connectivity, .airDrop),
        settings(.focus, "Focus", "moon.zzz", .system, .focus),
        settings(.screenMirroring, "Screen Mirroring", "rectangle.on.rectangle", .connectivity, .displays),
        settings(.stageManager, "Stage Manager", "rectangle.split.2x2", .system, .desktop),
        settings(.battery, "Battery", "battery.100percent", .system, .battery),
        settings(.energyMode, "Energy Mode", "leaf", .system, .battery),
        settings(.keyboard, "Keyboard", "keyboard", .system, .keyboard),
        item(.inputSources, "Input Sources", "character.cursor.ibeam", .system, .inputSourcePicker),
        item(.vpn, "VPN", "network.badge.shield.half.filled", .connectivity, .vpnConnectionPicker),
        settings(.network, "Network", "network", .connectivity, .network),
        settings(.fastUserSwitching, "Fast User Switching", "person.crop.circle", .system, .users),
        item(.timeMachine, "Time Machine", "clock.arrow.circlepath", .system, .timeMachineBackup),
        settings(.controlCenter, "Control Center Settings", "switch.2", .system, .controlCenter),
        item(.siri, "Siri", "sparkles", .system,
             .nativeApp(bundleIdentifier: "com.apple.siri.launcher", path: "/System/Applications/Siri.app")),
        item(.spotlight, "Spotlight", "magnifyingglass", .system,
             .nativeApp(bundleIdentifier: "com.apple.Spotlight", path: "/System/Library/CoreServices/Spotlight.app")),
        // Music Recognition is exposed by macOS's control gallery, not a documented
        // third-party toggle API. Its settings entry is deliberately marked as such.
        settings(.recognizeMusic, "Music Recognition Controls", "shazam.logo", .system, .controlCenter),
        app(.weather, "Weather", "cloud.sun", "/System/Applications/Weather.app", "com.apple.weather"),
        app(.home, "Apple Home", "house", "/System/Applications/Home.app", "com.apple.Home"),
        item(.accessibility, "Accessibility Shortcuts", "accessibility", .accessibility,
             .nativeApp(bundleIdentifier: "com.apple.UniversalAccessControl", path: "/System/Library/CoreServices/UniversalAccessControl.app")),
        settings(.hearing, "Hearing Devices", "ear", .accessibility, .hearing),
        settings(.backgroundSounds, "Background Sounds", "waveform.path", .accessibility, .audio),
        settings(.liveCaptions, "Live Captions", "captions.bubble", .accessibility, .liveCaptions),
        settings(.liveSpeech, "Live Speech", "text.bubble", .accessibility, .liveSpeech),
        settings(.voiceOver, "VoiceOver", "person.wave.2", .accessibility, .voiceOver),
        settings(.zoom, "Zoom", "plus.magnifyingglass", .accessibility, .zoom),
        settings(.hoverText, "Hover Text", "text.magnifyingglass", .accessibility, .hoverText),
        settings(.hoverTyping, "Hover Typing", "character.magnify", .accessibility, .hoverText),
        settings(.colorFilters, "Color Filters", "camera.filters", .accessibility, .displayAccessibility),
        settings(.invertColors, "Invert Colors", "circle.lefthalf.filled", .accessibility, .displayAccessibility),
        item(.increaseContrast, "Increase Contrast", "circle.lefthalf.filled", .accessibility, .accessibilityDisplayToggle(.increaseContrast)),
        settings(.reduceMotion, "Reduce Motion", "circle.dotted", .accessibility, .motion),
        item(.reduceTransparency, "Reduce Transparency", "square.on.square", .accessibility, .accessibilityDisplayToggle(.reduceTransparency)),
        settings(.accessibilityReader, "Accessibility Reader", "book", .accessibility, .reader),
        settings(.voiceControl, "Voice Control", "mic", .accessibility, .voiceControl),
        settings(.switchControl, "Switch Control", "switch.2", .accessibility, .switchControl),
        settings(.fullKeyboardAccess, "Full Keyboard Access", "keyboard", .accessibility, .keyboardAccessibility),
        settings(.accessibilityKeyboard, "Accessibility Keyboard", "keyboard.badge.eye", .accessibility, .keyboardAccessibility),
        settings(.stickyKeys, "Sticky Keys", "command", .accessibility, .keyboardAccessibility),
        settings(.slowKeys, "Slow Keys", "keyboard", .accessibility, .keyboardAccessibility),
        settings(.mouseKeys, "Mouse Keys", "computermouse", .accessibility, .pointerControl),
        settings(.headPointer, "Head Pointer", "person.crop.circle", .accessibility, .pointerControl),
        settings(.vehicleMotionCues, "Vehicle Motion Cues", "car.side", .accessibility, .motion),
        item(.screenSaver, "Start Screen Saver", "sparkles.tv", .system,
             .nativeApp(bundleIdentifier: "com.apple.ScreenSaver.Engine", path: "/System/Library/CoreServices/ScreenSaverEngine.app")),
        item(.lockScreen, "Lock Screen", "lock.display", .system, .systemShortcut(.lockScreen)),
        app(.magnifier, "Magnifier", "plus.magnifyingglass", "/System/Applications/Utilities/Magnifier.app", "com.apple.Magnifier"),
        app(.reminders, "Reminders", "checklist", "/System/Applications/Reminders.app", "com.apple.reminders")
    ]

    static func tool(_ id: SystemToolID) -> SystemToolDefinition {
        // Every persisted enum case is required to have one catalog definition.
        all.first { $0.id == id }!
    }

    private static func item(_ id: SystemToolID, _ title: String, _ symbol: String,
                             _ category: SystemToolCategory, _ behavior: SystemToolBehavior) -> SystemToolDefinition {
        .init(id: id, titleKey: title, symbol: symbol, category: category, behavior: behavior)
    }

    private static func settings(_ id: SystemToolID, _ title: String, _ symbol: String,
                                 _ category: SystemToolCategory, _ pane: SystemToolSettingsPane) -> SystemToolDefinition {
        item(id, title, symbol, category, .systemSettings(pane))
    }

    private static func app(_ id: SystemToolID, _ title: String, _ symbol: String,
                            _ path: String, _ bundleID: String) -> SystemToolDefinition {
        item(id, title, symbol, .utilities, .nativeApp(bundleIdentifier: bundleID, path: path))
    }
}
