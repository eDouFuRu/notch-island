import Foundation

/// Position and timestamp are one sample. Never update one simply because an
/// unrelated metadata field (volume, artwork, shuffle…) changed.
struct MediaPlaybackClock: Equatable {
    var elapsed: Double
    var timestamp: TimeInterval
    var rate: Double
    var playing: Bool

    func position(at now: TimeInterval, duration: Double = 0) -> Double {
        let base = elapsed.isFinite ? max(0, elapsed) : 0
        let delta = playing && timestamp.isFinite && timestamp >= 0 && now.isFinite && rate.isFinite
            ? max(0, now - timestamp) * max(0, rate) : 0
        let value = base + delta
        return duration.isFinite && duration > 0 ? min(value, duration) : value
    }

    static func merging(previous: MediaPlaybackClock, elapsed: Double?, timestamp: TimeInterval?,
                        rate: Double?, playing: Bool?, now: TimeInterval, duration: Double,
                        reset: Bool = false) -> MediaPlaybackClock {
        let newRate = rate.flatMap { $0.isFinite ? max(0, $0) : nil } ?? (reset ? 1 : previous.rate)
        let newPlaying = playing ?? (reset ? false : previous.playing)
        let suppliedElapsed = elapsed.flatMap { $0.isFinite ? max(0, $0) : nil }
        let suppliedTimestamp = timestamp.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let base: Double
        let anchor: TimeInterval
        if let suppliedElapsed {
            base = suppliedElapsed
            // Full snapshots normally supply both; an unanchored position is
            // measured at receipt rather than being paired with an old date.
            anchor = suppliedTimestamp ?? now
        } else if reset {
            base = 0
            anchor = now
        } else if let suppliedTimestamp {
            // Legacy adapter diffs may change only the timestamp because the
            // numeric elapsed position is unchanged. Respect that sample pair.
            base = previous.elapsed
            anchor = suppliedTimestamp
        } else if newPlaying != previous.playing || newRate != previous.rate {
            // Freeze before pause/rate changes, and re-anchor on resume. This
            // prevents counting the paused interval after playback resumes.
            base = previous.position(at: now, duration: duration)
            anchor = now
        } else {
            base = previous.elapsed
            anchor = previous.timestamp
        }
        return MediaPlaybackClock(elapsed: base, timestamp: anchor, rate: newRate, playing: newPlaying)
    }
}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
    let durationMicros: Double?
    let elapsedTimeMicros: Double?
    let timestampEpochMicros: Double?

    var resolvedDuration: Double? { Self.seconds(micros: durationMicros, fallback: duration) }
    var resolvedElapsedTime: Double? { Self.seconds(micros: elapsedTimeMicros, fallback: elapsedTime) }
    var resolvedTimestamp: TimeInterval? {
        if let micros = timestampEpochMicros, micros.isFinite, micros >= 0 { return micros / 1_000_000 }
        guard let timestamp else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (fractional.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp))?.timeIntervalSince1970
    }

    private static func seconds(micros: Double?, fallback: Double?) -> Double? {
        if let micros, micros.isFinite, micros >= 0 { return micros / 1_000_000 }
        return fallback.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}
