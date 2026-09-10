import Foundation

@main
enum PlaybackClockHarness {
    static func main() {
        var base = PlaybackState(bundleIdentifier: "test.player")
        base.currentTime = 10
        base.lastUpdated = Date(timeIntervalSince1970: 100)
        var replacement = base
        replacement.lastUpdated = Date(timeIntervalSince1970: 105)
        precondition(base != replacement, "Same numeric position at a new instant must be published (seek/repeated song).")
        replacement = base
        replacement.playbackRate = 2
        precondition(base != replacement, "A rate-only update must not be discarded by controller deduplication.")
        replacement = base
        replacement.volume = 0.75
        precondition(base != replacement, "Volume-only player events must still update controls.")
        replacement = base
        precondition(base == replacement, "Identical playback samples may be deduplicated.")
        print("PASS: 4 PlaybackState equality checks (time anchor, rate, volume, unchanged state)")
    }
}
