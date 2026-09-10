import Foundation
import Defaults

// This executable links the actual LyricsStore and Defaults implementation.
// No standard preferences are touched: every store uses its injected initializer.
func L(_ key: String) -> String { key }
extension Defaults.Keys {
    static let lyricsDisplayLocation = Key<LyricsDisplayLocation>("harness.lyrics.location", default: .off)
    static let enableLyrics = Key<Bool>("harness.lyrics.legacy", default: false)
}

@MainActor private final class ControlledLyricsProvider {
    struct Pending { let title: String; let continuation: CheckedContinuation<LyricsDocument?, Error> }
    var pending: [Pending] = []
    func lookup(_ track: LyricsTrack) async throws -> LyricsDocument? {
        // Deliberately ignores task cancellation until resolved, to exercise the
        // production writeback guard against an uncooperative delayed provider.
        try await withCheckedThrowingContinuation { pending.append(Pending(title: track.title, continuation: $0)) }
    }
    func finish(_ index: Int, text: String?) {
        pending[index].continuation.resume(returning: text.map { LyricsDocument(cues: [LyricCue(time: 0, text: $0)]) })
    }
}

@main struct LyricsStoreHarness {
    @MainActor static func main() async {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            count += 1; print("PASS: \(message)")
        }
        func state(_ title: String, playing: Bool = true, elapsed: Double = 2) -> PlaybackState {
            var state = PlaybackState(bundleIdentifier: "com.netease.163music")
            state.title = title; state.artist = "Artist"; state.album = "Album"; state.duration = 180
            state.currentTime = elapsed; state.lastUpdated = Date(); state.isPlaying = playing
            return state
        }
        func settle() async { for _ in 0..<20 { await Task.yield() } }
        let provider = ControlledLyricsProvider()
        let store = LyricsStore(testLocation: .notch, lookup: provider.lookup)
        let panelID = UUID()
        store.setNotchPresentation(sourceID: panelID, visible: true)
        store.updatePlayback(state("A"))
        await settle()
        check(provider.pending.isEmpty, "Unavailable app makes no lyric request")
        store.setApplicationAvailable(true)
        await settle()
        check(provider.pending.count == 1 && store.isLoading, "Availability loads current track immediately")
        store.updatePlayback(state("A", elapsed: 7))
        await settle()
        check(provider.pending.count == 1, "Repeated playback positions coalesce one request")
        store.updatePlayback(state("B"))
        await settle()
        check(provider.pending.count == 2, "Track change starts its own request")
        provider.finish(1, text: "B lyric")
        await settle()
        check(store.currentLine == "B lyric", "Current-track result is published")
        check(store.diagnosticsSummary.contains("ticking=true"), "Visible synchronized lyric starts visual ticker")
        store.removeNotchPresentation(sourceID: panelID)
        check(store.diagnosticsSummary.contains("ticking=false"), "Occluded synchronized lyric stops visual ticker")
        store.setNotchPresentation(sourceID: panelID, visible: true)
        check(store.diagnosticsSummary.contains("ticking=true"), "Restored presentation immediately resumes synchronization")
        provider.finish(0, text: "Stale A lyric")
        await settle()
        check(store.currentLine == "B lyric", "Cancelled late A result cannot overwrite B")
        check(store.shouldShowNotch, "Playing notch location exposes lyric presentation")
        store.updatePlayback(state("B", playing: false))
        await settle()
        check(!store.shouldShowNotch && store.currentLine == "B lyric", "Pause hides notch while retaining synchronized content")
        store.updatePlayback(state("B"))
        await settle()
        check(store.shouldShowNotch && provider.pending.count == 2, "Resume reuses loaded lyrics")
        store.updatePlayback(state("C"))
        await settle()
        store.setApplicationAvailable(false)
        provider.finish(2, text: "Hidden C lyric")
        await settle()
        check(!store.isLoading && !store.shouldShowNotch && store.currentLine.isEmpty,
              "Hide cancels request and rejects late completion")
        store.setApplicationAvailable(true)
        await settle()
        check(provider.pending.count == 4, "Show retries the interrupted current track")
        provider.finish(3, text: nil)
        await settle()
        check(store.displayText == "No synced lyrics available", "Unmatched track has explicit synchronized-lyrics fallback")
        check(!store.shouldShowNotch, "Unmatched track retracts the notch lyric row")
        store.updatePlayback(state("B"))
        await settle()
        check(store.currentLine == "B lyric" && provider.pending.count == 4, "Switching back uses bounded track cache")
        store.updatePlayback(state("C"))
        await settle()
        check(provider.pending.count == 4 && store.currentLine.isEmpty, "Negative cache avoids repeated unmatched requests")
        store.removeNotchPresentation(sourceID: panelID)
        check(store.diagnosticsSummary.contains("ticking=false"), "Unmounting removes the visual ticker")
        let disabled = LyricsStore(testLocation: .off, lookup: provider.lookup)
        disabled.setApplicationAvailable(true); disabled.updatePlayback(state("Off"))
        await settle()
        check(provider.pending.count == 4 && !disabled.shouldShowNotch, "Off location never requests or displays lyrics")
        let player = LyricsStore(testLocation: .player, lookup: provider.lookup)
        player.setApplicationAvailable(true); player.updatePlayback(state("Player"))
        await settle(); provider.finish(4, text: "Player lyric"); await settle()
        check(player.currentLine == "Player lyric" && !player.shouldShowNotch, "Player location does not leak into the notch")
        var simplifiedChinese = true
        let chinese = LyricsStore(testLocation: .notch, prefersSimplifiedChinese: { simplifiedChinese }, lookup: provider.lookup)
        let chineseRequest = provider.pending.count
        chinese.setApplicationAvailable(true); chinese.updatePlayback(state("Chinese display"))
        await settle(); provider.finish(chineseRequest, text: "願與你一生，輕輕說聲愛你"); await settle()
        check(chinese.currentLine == "願與你一生，輕輕說聲愛你", "Production store retains original provider text")
        check(chinese.displayText == "愿与你一生，轻轻说声爱你", "Chinese display converts traditional lyrics to simplified")
        simplifiedChinese = false
        check(chinese.displayText == "願與你一生，輕輕說聲愛你", "English display immediately restores original lyrics")
        simplifiedChinese = true
        check(chinese.displayText == "愿与你一生，轻轻说声爱你" && provider.pending.count == chineseRequest + 1,
              "Language display switching neither re-fetches nor rewrites the lyric cache")
        chinese.setApplicationAvailable(false)
        store.setApplicationAvailable(false); player.setApplicationAvailable(false)
        var failedAttempts = 0
        let recovery = LyricsStore(testLocation: .notch, retryDelay: 0.04) { _ in
            failedAttempts += 1
            if failedAttempts == 1 { throw URLError(.timedOut) }
            return LyricsDocument(cues: [LyricCue(time: 0, text: "Recovered")])
        }
        let recoveryPanel = UUID()
        recovery.setNotchPresentation(sourceID: recoveryPanel, visible: true)
        recovery.updatePlayback(state("Recover without metadata event")); recovery.setApplicationAvailable(true)
        try? await Task.sleep(for: .milliseconds(150))
        check(failedAttempts == 2 && recovery.currentLine == "Recovered", "Visible failed lookup automatically recovers without metadata updates")
        var persistentFailures = 0
        let limited = LyricsStore(testLocation: .notch, retryDelay: 0.02) { _ in
            persistentFailures += 1; throw URLError(.notConnectedToInternet)
        }
        let limitedPanel = UUID()
        limited.setNotchPresentation(sourceID: limitedPanel, visible: true)
        limited.updatePlayback(state("Bounded failure")); limited.setApplicationAvailable(true)
        try? await Task.sleep(for: .milliseconds(160))
        check(persistentFailures == 3, "A lookup has at most two automatic retries")
        limited.updatePlayback(state("Bounded failure", elapsed: 20))
        await settle()
        check(persistentFailures == 3, "Metadata updates cannot bypass automatic retry limit")
        check(limited.displayText == "Lyrics temporarily unavailable", "Network failure is distinct from an unmatched song")
        check(!limited.shouldShowNotch, "Network failure does not hold an empty notch panel open")
        limited.retryCurrentTrack(); await settle()
        let manualAttempts = persistentFailures
        limited.retryCurrentTrack(); await settle()
        check(persistentFailures == manualAttempts, "Manual retry is debounced")
        limited.setApplicationAvailable(false)
        try? await Task.sleep(for: .milliseconds(100))
        check(persistentFailures == manualAttempts, "Hidden app cancels scheduled retries")
        var pauseAttempts = 0
        let paused = LyricsStore(testLocation: .notch, retryDelay: 0.03) { _ in
            pauseAttempts += 1; throw URLError(.timedOut)
        }
        paused.setNotchPresentation(sourceID: UUID(), visible: true)
        paused.updatePlayback(state("Paused failure", playing: false)); paused.setApplicationAvailable(true)
        try? await Task.sleep(for: .milliseconds(100))
        check(pauseAttempts == 1, "Paused playback does not schedule network retry")
        paused.setApplicationAvailable(false); recovery.setApplicationAvailable(false)
        let cueStore = LyricsStore(testLocation: .notch) { _ in
            LyricsDocument(cues: [LyricCue(time: 3, text: "First"), LyricCue(time: 5, text: ""), LyricCue(time: 7, text: "Next")])
        }
        cueStore.setNotchPresentation(sourceID: UUID(), visible: true)
        cueStore.updatePlayback(state("Intro", elapsed: 0)); cueStore.setApplicationAvailable(true)
        await settle()
        check(!cueStore.shouldShowNotch && cueStore.diagnosticsSummary.contains("ticking=true"), "Blank intro retracts row while keeping its eligible cue clock alive")
        cueStore.updatePlayback(state("Intro", elapsed: 3.1))
        check(cueStore.shouldShowNotch, "A real first lyric reveals the row")
        cueStore.updatePlayback(state("Intro", elapsed: 5.1))
        check(!cueStore.shouldShowNotch, "A timed empty interlude retracts the row")
        cueStore.updatePlayback(state("Intro", elapsed: 7.1))
        check(cueStore.shouldShowNotch, "The next lyric restores the row after interlude")
        cueStore.setApplicationAvailable(false)
        print("Lyrics service checks: \(count) passed")
    }
}
