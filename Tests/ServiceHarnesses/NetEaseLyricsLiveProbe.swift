import Foundation
import Darwin

/// Explicit opt-in only. Prints timing/count metadata, never the lyric text.
/// A source timestamp is not evidence that someone has listened to its timing.
@main struct NetEaseLyricsLiveProbe {
    static func main() async {
        guard CommandLine.arguments.contains("--live") else {
            emit(["network_requested": false, "status": "skipped", "instruction": "Pass --live to run the anonymous production client lookup."])
            return
        }
        // The last two are the collaborations that had no lyrics (All for Joy)
        // or borrowed a three-second-late LRCLIB transcription (加油！) while
        // artist matching demanded the full credit. Metadata is exactly what
        // MediaRemote publishes for them: the lead performer only.
        let tracks = [
            LyricsTrack(source: "com.netease.163music", title: "远走高飞", artist: "林忆莲", album: "2001莲", duration: 222.693333),
            LyricsTrack(source: "com.netease.163music", title: "加油！", artist: "林俊杰", album: "100天", duration: 227.64),
            LyricsTrack(source: "com.netease.163music", title: "All for Joy", artist: "陶喆", album: "再见你好吗", duration: 258.4)
        ]
        let client = NetEaseLyricsClient()
        var failed = false
        for track in tracks {
            do {
                let document = try await client.lookup(track)
                var result: [String: Any] = ["network_requested": true, "matched": document != nil,
                                            "track": track.title, "artist": track.artist,
                                            "cue_count": document?.cues.count ?? 0,
                                            "tested_at": ISO8601DateFormatter().string(from: Date())]
                if let document {
                    let nonempty = document.cues.filter { !$0.text.isEmpty }
                    result["nonempty_cue_count"] = nonempty.count
                    result["han_cue_count"] = nonempty.filter { OriginalLyricLanguage.containsHan($0.text) }.count
                    result["romanized_document"] = OriginalLyricLanguage.isRomanizedMandarin(document, track: track)
                    result["instrumental"] = document.instrumental
                    if let first = nonempty.first { result["first_nonempty_cue_seconds"] = first.time }
                    if let vocal = nonempty.first(where: { !isCredit($0.text, track: track) }) {
                        result["first_vocal_candidate_seconds"] = vocal.time
                        // The notch renders exactly document.line(at:) for the
                        // extrapolated clock, so sampling either side of the cue
                        // shows when the first sung line actually appears.
                        result["line_is_empty_just_before"] = document.line(at: vocal.time - 0.05) != vocal.text
                        result["line_matches_at_cue"] = document.line(at: vocal.time) == vocal.text
                        result["line_still_matches_one_second_later"] = document.line(at: vocal.time + 1) == vocal.text
                    }
                    result["timing_evidence"] = "Source LRC timestamps only; vocal candidate excludes common credits and has not been aurally verified."
                } else { failed = true }
                emit(result)
            } catch {
                failed = true
                var result: [String: Any] = ["network_requested": true, "status": "lookup_failed",
                                            "track": track.title, "artist": track.artist,
                                            "tested_at": ISO8601DateFormatter().string(from: Date())]
                switch error {
                case NetEaseLyricsError.response(let code): result["error_type"] = "http"; result["error_code"] = code
                case NetEaseLyricsError.service(let code): result["error_type"] = "service"; result["error_code"] = code
                case NetEaseLyricsError.oversizedResponse: result["error_type"] = "oversized_response"
                case NetEaseLyricsError.rateLimited: result["error_type"] = "rate_limited"
                case NetEaseLyricsError.insecureRedirect: result["error_type"] = "insecure_redirect"
                case let error as URLError: result["error_type"] = "network"; result["error_code"] = error.code.rawValue
                case is CancellationError: result["error_type"] = "cancelled"
                case is DecodingError: result["error_type"] = "decoding"
                default: result["error_type"] = "unknown"
                }
                emit(result)
            }
        }
        if failed { exit(1) }
    }

    private static func isCredit(_ line: String, track: LyricsTrack) -> Bool {
        // NetEase headers spell the credit as "题目 - 甲/乙", where the title may
        // carry punctuation the track metadata omits, so compare without it.
        func bare(_ value: String) -> String {
            LyricsTrack.normalized(value).components(separatedBy: CharacterSet.punctuationCharacters).joined()
                .trimmingCharacters(in: .whitespaces)
        }
        let normalized = LyricsTrack.normalized(line), title = bare(track.title)
        if normalized == LyricsTrack.normalized(track.title) { return true }
        if !title.isEmpty, bare(line.components(separatedBy: " - ").first ?? "") == title,
           line.contains(" - ") { return true }
        // "rap" needs word boundaries: as a bare substring it also fires on
        // "wrapped"/"therapy", which would silently skip a real first line and
        // report a later time as the first vocal cue.
        // 监制/出品/录音/混音 head a NetEase credit block too; leaving them out made
        // this probe report a credit line's timestamp as the first sung line.
        return normalized.range(of: "(?i)(?:作词|作曲|编曲|制作|监制|出品|录音|混音|母带|和声|producer|composer|lyricist|arrang|mixing|mastered|recorded|(?<![a-z])(?:rap|op|sp)(?![a-z])|曲\\s*[:：]|词\\s*[:：])", options: .regularExpression) != nil
    }

    private static func emit(_ result: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
