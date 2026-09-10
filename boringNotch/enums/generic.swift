//
//  generic.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Foundation
import Defaults

public enum Style {
    case notch
    case floating
}

public enum ContentType: Int, Codable, Hashable, Equatable {
    case normal
    case menu
    case settings
}

public enum NotchState {
    case closed
    case open
}

public enum NotchViews {
    case island
    case home
    case shelf
    case tools
}

enum SettingsEnum {
    case general
    case about
    case charge
    case download
    case mediaPlayback
    case hud
    case shelf
    case extensions
}

enum DownloadIndicatorStyle: String, Defaults.Serializable {
    case progress = "Progress"
    case percentage = "Percentage"
}

enum DownloadIconStyle: String, Defaults.Serializable {
    case onlyAppIcon = "Only app icon"
    case onlyIcon = "Only download icon"
    case iconAndAppIcon = "Icon and app icon"
}

enum MirrorShapeEnum: String, Defaults.Serializable {
    case rectangle = "Rectangular"
    case circle = "Circular"
}

/// Mirrors `NotchHoverStateMachine.CloseTrigger`, which lives in the Core module and so
/// cannot depend on `Defaults`.
enum NotchCloseTriggerMode: String, CaseIterable, Defaults.Serializable {
    case hoverOut = "Pointer leaves the island"
    case externalClickOnly = "Click outside the island"

    var machineTrigger: NotchHoverStateMachine.CloseTrigger {
        switch self {
        case .hoverOut: .hoverOut
        case .externalClickOnly: .externalClickOnly
        }
    }

    var labelKey: String {
        switch self {
        case .hoverOut: "When the pointer leaves"
        case .externalClickOnly: "Only when clicking outside"
        }
    }
}

/// Mirrors `ShelfDragRemovalTrigger`, which lives in the Core module and so cannot depend
/// on `Defaults`.
enum ShelfDragRemovalTriggerMode: String, CaseIterable, Defaults.Serializable {
    case off = "Off"
    case optionCommand = "Option-Command"
    case controlCommand = "Control-Command"
    case legacyCommandD = "Command-D"

    var coreTrigger: ShelfDragRemovalTrigger {
        switch self {
        case .off: .off
        case .optionCommand: .optionCommand
        case .controlCommand: .controlCommand
        case .legacyCommandD: .legacyCommandD
        }
    }

    var labelKey: String {
        switch self {
        case .off: "Never"
        case .optionCommand: "Hold ⌥⌘"
        case .controlCommand: "Hold ⌃⌘"
        case .legacyCommandD: "Hold ⌘D (may clash with other apps)"
        }
    }
}

/// Mirrors `ShelfRetentionPolicy`, which lives in the Core module and so cannot depend on
/// `Defaults`.
enum ShelfRetentionMode: String, CaseIterable, Defaults.Serializable {
    case off = "Keep"
    case hours12 = "12 hours"
    case day1 = "1 day"
    case day3 = "3 days"
    case week1 = "1 week"

    var corePolicy: ShelfRetentionPolicy {
        switch self {
        case .off: .off
        case .hours12: .hours12
        case .day1: .day1
        case .day3: .day3
        case .week1: .week1
        }
    }

    var labelKey: String {
        switch self {
        case .off: "Never clear automatically"
        case .hours12: "After 12 hours"
        case .day1: "After 1 day"
        case .day3: "After 3 days"
        case .week1: "After 1 week"
        }
    }
}

enum WindowHeightMode: String, Defaults.Serializable {
    case matchMenuBar = "Match menubar height"
    case matchRealNotchSize = "Match real notch height"
    case custom = "Custom height"
}

enum SliderColorEnum: String, CaseIterable, Defaults.Serializable {
    case white = "White"
    case albumArt = "Match album art"
    case accent = "Accent color"
}

enum LyricsColorMode: String, CaseIterable, Defaults.Serializable {
    case white = "white"
    case albumArt = "albumArt"
    case custom = "custom"
}
