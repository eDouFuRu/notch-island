import Defaults
import SwiftUI

/// One live style for lyrics in both the compact row and the expanded player.
struct LyricsAppearance: DynamicProperty {
    @Default(.lyricsColorMode) private var mode
    @Default(.customLyricsColor) private var customColor
    @ObservedObject private var music = MusicManager.shared

    var color: Color {
        switch mode {
        case .white:
            return .white
        case .custom:
            return customColor
        case .albumArt:
            guard !music.usingAppIconForArtwork else { return .white }
            return Color(nsColor: music.avgColor).ensureMinimumBrightness(factor: 0.6)
        }
    }
}
