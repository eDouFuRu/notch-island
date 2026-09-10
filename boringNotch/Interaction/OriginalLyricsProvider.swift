import Foundation

/// Prefer the active player's original-language source. LRCLIB remains an
/// independent fallback; neither provider's phonetic/translation track is used
/// to invent original words. An outage stays retryable if no provider succeeds.
struct OriginalLyricsProvider: Sendable {
    let netease: @Sendable (LyricsTrack) async throws -> LyricsDocument?
    let library: @Sendable (LyricsTrack) async throws -> LyricsDocument?

    func lookup(_ track: LyricsTrack) async throws -> LyricsDocument? {
        let isNetEase = track.source == "com.netease.163music"
        let mayUseNetEase = isNetEase || OriginalLyricLanguage.containsHan(track.title) || OriginalLyricLanguage.containsHan(track.artist)
        let sources = isNetEase ? [netease, library] : (mayUseNetEase ? [library, netease] : [library])
        var failure: Error?
        for source in sources {
            try Task.checkCancellation()
            do {
                if let result = try await source(track), !OriginalLyricLanguage.isRomanizedMandarin(result, track: track) {
                    try Task.checkCancellation()
                    return result
                }
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        return nil
    }
}
