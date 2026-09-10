import Foundation

enum LyricsTextPresentation {
    /// Conversion belongs to presentation only. The provider text and timed
    /// document remain intact for cache identity and language switching.
    static func render(line: String, simplifiedChinese: Bool) -> String {
        guard simplifiedChinese, !line.isEmpty, !OriginalLyricLanguage.preservesNonChineseScript(line) else { return line }
        return line.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? line
    }
}

struct LyricsTrack: Hashable, Sendable {
    let source: String
    let title: String
    let artist: String
    let album: String
    let duration: Double

    init(source: String, title: String, artist: String, album: String, duration: Double) {
        self.source = source
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        self.duration = duration.isFinite ? max(0, duration) : 0
    }
    var canSearch: Bool { !source.isEmpty && !title.isEmpty && !artist.isEmpty }
    static func normalized(_ text: String) -> String {
        (text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text)
            .replacingOccurrences(of: "…", with: "...")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

struct LyricCue: Equatable, Sendable {
    let time: Double
    let text: String
}

struct LyricsDocument: Equatable, Sendable {
    let cues: [LyricCue]
    let instrumental: Bool
    init(cues: [LyricCue], instrumental: Bool = false) {
        self.cues = cues
        self.instrumental = instrumental
    }
    var permitsChineseSimplification: Bool {
        !cues.contains { OriginalLyricLanguage.preservesNonChineseScript($0.text) }
    }
    func line(at seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, !cues.isEmpty else { return "" }
        var low = 0, high = cues.count
        while low < high {
            let middle = low + (high - low) / 2
            if cues[middle].time <= seconds { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? cues[low - 1].text : ""
    }
}

enum LRCParser {
    private static let timestamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):([0-5]\d)(?:\.(\d{1,3}))?\]"#)
    private static let offset = try! NSRegularExpression(pattern: #"(?i)\[offset:\s*([+-]?\d+)\s*\]"#)

    static func parse(_ text: String) -> [LyricCue] {
        guard text.utf8.count <= 256_000 else { return [] }
        // An LRC positive offset advances the lyric relative to the media clock.
        let source = text as NSString
        let wholeRange = NSRange(location: 0, length: source.length)
        let offsetMilliseconds = offset.matches(in: text, range: wholeRange).last
            .flatMap { Double(source.substring(with: $0.range(at: 1))) } ?? 0
        var entries: [(time: Double, text: String, index: Int)] = []
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = line as NSString
            let matches = timestamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let content = ns.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespacesAndNewlines)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                let fractionRange = match.range(at: 3)
                let fraction = fractionRange.location == NSNotFound ? 0 : (Double("0." + ns.substring(with: fractionRange)) ?? 0)
                let time = max(0, minutes * 60 + seconds + fraction - offsetMilliseconds / 1_000)
                guard time.isFinite else { continue }
                entries.append((time, content, entries.count))
                guard entries.count <= 4_096 else { return [] }
            }
        }
        entries.sort { $0.time == $1.time ? $0.index < $1.index : $0.time < $1.time }
        var result: [LyricCue] = []
        for entry in entries {
            if let previous = result.last, previous.time == entry.time {
                // Parallel translated lines are retained in one visible line.
                let components = previous.text.components(separatedBy: " · ")
                if !entry.text.isEmpty && !components.contains(entry.text) {
                    let original = OriginalLyricLanguage.withoutPhoneticDuplicates(components.filter { !$0.isEmpty } + [entry.text])
                    result[result.count - 1] = LyricCue(time: entry.time, text: original.joined(separator: " · "))
                }
            } else {
                // Empty timed cues matter: they clear the line during an interlude.
                result.append(LyricCue(time: entry.time, text: entry.text))
            }
        }
        return result
    }
}

struct LRCLIBRecord: Decodable, Sendable {
    let id: Int?
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let syncedLyrics: String?

    func matches(_ track: LyricsTrack) -> Bool {
        guard LyricsTrack.normalized(trackName) == LyricsTrack.normalized(track.title),
              LyricsTrack.artistMatches(artistName, track.artist) else { return false }
        if !track.album.isEmpty {
            guard let albumName, !albumName.isEmpty,
                  LyricsTrack.normalizedAlbum(albumName) == LyricsTrack.normalizedAlbum(track.album) else { return false }
        }
        if track.duration > 0 {
            let tolerance = track.album.isEmpty ? 0.5 : 1.0
            guard let duration, duration.isFinite, abs(duration - track.duration) <= tolerance else { return false }
        }
        return true
    }
    var document: LyricsDocument? {
        let cues = LRCParser.parse(syncedLyrics ?? "")
        return cues.isEmpty && instrumental != true ? nil : LyricsDocument(cues: cues, instrumental: instrumental == true)
    }
    static func bestMatch(_ records: [LRCLIBRecord], track: LyricsTrack) -> LyricsDocument? {
        // A full search page cannot prove uniqueness across the catalog. Prefer
        // no synchronized lyric to silently choosing among truncated versions.
        if track.album.isEmpty && records.count >= 20 { return nil }
        let candidates = records.compactMap { record -> (record: LRCLIBRecord, document: LyricsDocument, distance: Double)? in
            guard record.matches(track), let document = record.document,
                  !OriginalLyricLanguage.isRomanizedMandarin(document, track: track) else { return nil }
            return (record, document, abs((record.duration ?? track.duration) - track.duration))
        }
        // Without duration/album, multiple versions are ambiguous; avoid guessing.
        if track.duration == 0 && track.album.isEmpty && candidates.count > 1 { return nil }
        guard let best = candidates.min(by: {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return ($0.record.id ?? Int.max) < ($1.record.id ?? Int.max)
        }) else { return nil }
        if track.album.isEmpty {
            // Small metadata rounding differences are not evidence for selecting
            // one of two incompatible clocks. Identical documents are harmless.
            let tied = candidates.filter { $0.distance <= best.distance + 0.05 }
            guard tied.allSatisfy({ $0.document == best.document }) else { return nil }
        }
        return best.document
    }
}

/// Explicit track cache, including negative results. HTTP caching alone cannot
/// prevent duplicate searches for a song or represent an unmatched version.
struct LyricsCache {
    struct Hit { let document: LyricsDocument?; let expiry: TimeInterval }
    private struct Entry { let document: LyricsDocument?; let expiry: TimeInterval; var access: UInt64 }
    private var entries: [LyricsTrack: Entry] = [:]
    private var counter: UInt64 = 0
    let capacity: Int
    init(capacity: Int = 64) { self.capacity = max(1, capacity) }
    var count: Int { entries.count }
    mutating func lookup(_ track: LyricsTrack, now: TimeInterval) -> Hit? {
        guard var entry = entries[track] else { return nil }
        guard entry.expiry > now else { entries[track] = nil; return nil }
        counter &+= 1; entry.access = counter; entries[track] = entry
        return Hit(document: entry.document, expiry: entry.expiry)
    }
    mutating func remove(_ track: LyricsTrack) { entries.removeValue(forKey: track) }

    mutating func insert(_ document: LyricsDocument?, for track: LyricsTrack, now: TimeInterval, lifetime: TimeInterval) {
        entries = entries.filter { $0.value.expiry > now }
        counter &+= 1
        entries[track] = Entry(document: document, expiry: now + max(0, lifetime), access: counter)
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries[oldest] = nil
        }
    }
}

enum LyricsPlaybackClock {
    static func position(elapsed: Double, timestamp: TimeInterval, now: TimeInterval,
                         duration: Double, rate: Double, playing: Bool) -> Double {
        let base = elapsed.isFinite ? max(0, elapsed) : 0
        let delta = playing && now.isFinite && timestamp.isFinite && rate.isFinite
            ? max(0, now - timestamp) * max(0, rate) : 0
        let value = base + delta
        return duration.isFinite && duration > 0 ? min(value, duration) : value
    }
}
