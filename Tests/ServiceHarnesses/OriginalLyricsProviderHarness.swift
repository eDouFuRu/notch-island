import Foundation

private actor OriginalProviderProbe {
    enum Outcome: Sendable {
        case document(LyricsDocument?)
        case failure(URLError.Code)
        case cancellation
        case cancelThenReturnNil
    }
    let outcomes: [String: Outcome]
    private(set) var calls: [String] = []
    init(netease: Outcome, library: Outcome) { outcomes = ["netease": netease, "library": library] }
    func call(_ name: String) throws -> LyricsDocument? {
        calls.append(name)
        switch outcomes[name]! {
        case .document(let value): return value
        case .failure(let code): throw URLError(code)
        case .cancellation: throw CancellationError()
        case .cancelThenReturnNil:
            withUnsafeCurrentTask { $0?.cancel() }
            return nil
        }
    }
}

enum OriginalLyricsProviderHarness {
    static func run() async throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            count += 1; print("PASS: \(message)")
        }
        func provider(_ probe: OriginalProviderProbe) -> OriginalLyricsProvider {
            OriginalLyricsProvider(netease: { _ in try await probe.call("netease") },
                                   library: { _ in try await probe.call("library") })
        }
        let neteaseTrack = LyricsTrack(source: "com.netease.163music", title: "红薯之歌", artist: "薯队长", album: "小岛日记", duration: 180)
        let otherChineseTrack = LyricsTrack(source: "com.apple.Music", title: neteaseTrack.title, artist: neteaseTrack.artist, album: neteaseTrack.album, duration: neteaseTrack.duration)
        let englishTrack = LyricsTrack(source: "com.apple.Music", title: "A Little Sunshine", artist: "The Island", album: "Morning", duration: 180)
        let original = LyricsDocument(cues: [LyricCue(time: 1.2, text: "种一颗红薯"), LyricCue(time: 5, text: "A little sunshine")])
        let english = LyricsDocument(cues: [LyricCue(time: 1.2, text: "The morning sunshine follows me")])
        let romanized = LyricsDocument(cues: (0..<4).map { LyricCue(time: Double($0), text: "wo ai ni yuan zou gao fei") })

        let preferred = OriginalProviderProbe(netease: .document(original), library: .failure(.badServerResponse))
        let selected = try await provider(preferred).lookup(neteaseTrack)
        let preferredCalls = await preferred.calls
        check(selected == original && preferredCalls == ["netease"], "NetEase playback uses the original source without calling LRCLIB")

        let fallback = OriginalProviderProbe(netease: .failure(.timedOut), library: .document(original))
        let fallbackResult = try await provider(fallback).lookup(neteaseTrack)
        let fallbackCalls = await fallback.calls
        check(fallbackResult == original && fallbackCalls == ["netease", "library"], "NetEase outage can fall back to a valid original-language document")

        let rejectedRomanized = OriginalProviderProbe(netease: .document(romanized), library: .document(original))
        let corrected = try await provider(rejectedRomanized).lookup(neteaseTrack)
        let correctedCalls = await rejectedRomanized.calls
        check(corrected == original && correctedCalls == ["netease", "library"], "Romanized Chinese is rejected and another source is tried")

        let otherPlayer = OriginalProviderProbe(netease: .document(original), library: .document(romanized))
        let otherPlayerResult = try await provider(otherPlayer).lookup(otherChineseTrack)
        let otherPlayerCalls = await otherPlayer.calls
        check(otherPlayerResult == original && otherPlayerCalls == ["library", "netease"],
              "Other-player romanized Chinese can recover from the original NetEase source")

        // Source order follows the player: only NetEase playback puts NetEase
        // first, so QQ/Kugou/Spotify/Apple Music keep LRCLIB as their primary.
        let otherPlayerOrder = OriginalProviderProbe(netease: .document(original), library: .document(original))
        _ = try await provider(otherPlayerOrder).lookup(otherChineseTrack)
        let otherPlayerOrderCalls = await otherPlayerOrder.calls
        check(otherPlayerOrderCalls == ["library"],
              "A non-NetEase player never reaches NetEase while LRCLIB answers")

        let bothRomanized = OriginalProviderProbe(netease: .document(romanized), library: .document(romanized))
        let noOriginal = try await provider(bothRomanized).lookup(neteaseTrack)
        check(noOriginal == nil, "Two phonetic-only sources produce no invented Chinese lyrics")

        let bothFailed = OriginalProviderProbe(netease: .failure(.timedOut), library: .failure(.cannotConnectToHost))
        do { _ = try await provider(bothFailed).lookup(neteaseTrack); fatalError("Two outages became no lyrics") }
        catch let error as URLError {
            let calls = await bothFailed.calls
            check(error.code == .cannotConnectToHost && calls == ["netease", "library"], "Two source outages stay retryable instead of becoming a no-lyrics result")
        }
        let oneFailed = OriginalProviderProbe(netease: .failure(.timedOut), library: .document(nil))
        do { _ = try await provider(oneFailed).lookup(neteaseTrack); fatalError("An outage was hidden by a missing fallback") }
        catch let error as URLError { check(error.code == .timedOut, "One outage plus an unmatched fallback also remains retryable") }

        let preferEnglish = OriginalProviderProbe(netease: .failure(.badServerResponse), library: .document(english))
        let englishResult = try await provider(preferEnglish).lookup(englishTrack)
        let englishCalls = await preferEnglish.calls
        check(englishResult == english && englishCalls == ["library"], "Non-NetEase English playback prefers LRCLIB and keeps the original English")
        check(LyricsTextPresentation.render(line: englishResult!.cues[0].text, simplifiedChinese: true) == english.cues[0].text,
              "Simplified-Chinese display does not translate English lyrics")
        let chineseNameEnglish = OriginalProviderProbe(netease: .document(english), library: .failure(.badServerResponse))
        let chineseNameEnglishResult = try await provider(chineseNameEnglish).lookup(neteaseTrack)
        check(chineseNameEnglishResult == english, "Chinese metadata does not force actual English lyrics into Chinese")

        let cancelled = OriginalProviderProbe(netease: .cancellation, library: .document(original))
        do { _ = try await provider(cancelled).lookup(neteaseTrack); fatalError("Cancellation fell through") }
        catch is CancellationError {
            let calls = await cancelled.calls
            check(calls == ["netease"], "A cancelled first source never starts the fallback")
        }
        let lateCancellation = OriginalProviderProbe(netease: .cancelThenReturnNil, library: .document(original))
        let cancelledTask = Task { try await provider(lateCancellation).lookup(neteaseTrack) }
        do { _ = try await cancelledTask.value; fatalError("Post-response cancellation fell through") }
        catch is CancellationError {
            let calls = await lateCancellation.calls
            check(calls == ["netease"], "Cancellation after a nil response is checked before another source")
        }
        return count
    }
}
