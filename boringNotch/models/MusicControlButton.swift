//
//  MusicControlButton.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-16.
//

import Defaults

enum MusicControlButton: String, CaseIterable, Identifiable, Codable, Defaults.Serializable {
    case shuffle
    case previous
    case playPause
    case next
    case repeatMode
    case volume
    case favorite
    case goBackward
    case goForward
    case none

    var id: String { rawValue }

    static let defaultLayout: [MusicControlButton] = [
        .none,
        .previous,
        .playPause,
        .next,
        .none
    ]

    static let minSlotCount: Int = 3
    static let maxSlotCount: Int = 5

    static let pickerOptions: [MusicControlButton] = [
        .shuffle,
        .previous,
        .playPause,
        .next,
        .repeatMode,
        .favorite,
        .volume,
        .goBackward,
        .goForward
    ]

    var label: String {
        switch self {
        case .shuffle:
            return "Shuffle"
        case .previous:
            return "Previous"
        case .playPause:
            return "Play/Pause"
        case .next:
            return "Next"
        case .repeatMode:
            return "Repeat"
        case .volume:
            return "Volume"
        case .favorite:
            return "Favorite"
        case .goBackward:
            return "Backward 15s"
        case .goForward:
            return "Forward 15s"
        case .none:
            return "Empty slot"
        }
    }

    var iconName: String {
        switch self {
        case .shuffle:
            return "shuffle"
        case .previous:
            return "backward.fill"
        case .playPause:
            return "playpause"
        case .next:
            return "forward.fill"
        case .repeatMode:
            return "repeat"
        case .volume:
            return "speaker.wave.2.fill"
        case .favorite:
            return "heart"
        case .goBackward:
            return "gobackward.15"
        case .goForward:
            return "goforward.15"
        case .none:
            return ""
        }
    }

    var prefersLargeScale: Bool {
        self == .playPause
    }

    static func normalized(_ slots: [Self]) -> [Self] {
        MediaSlotReducer.normalize(slots, empty: .none)
    }

    static func applying(_ payload: MediaControlDragPayload, to target: Int?, in slots: [Self]) -> [Self] {
        guard let control = Self(rawValue: payload.controlID), control != .none else { return normalized(slots) }
        return MediaSlotReducer.drop(control, from: payload.sourceSlot, to: target, in: slots, empty: .none)
    }
}
