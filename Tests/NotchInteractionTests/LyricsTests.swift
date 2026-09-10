import XCTest
@testable import NotchInteractionCore

final class LyricsTests: XCTestCase {
    func testSimplifiedChinesePresentationUsesICUWithoutChangingSource() {
        let source = "輕輕說聲愛你，願與你一生。"
        XCTAssertEqual(LyricsTextPresentation.render(line: source, simplifiedChinese: true), "轻轻说声爱你，愿与你一生。")
        XCTAssertEqual(source, "輕輕說聲愛你，願與你一生。")
    }
    func testEnglishPresentationKeepsOriginalTraditionalChinese() {
        let source = "張學友 · 願與你一生"
        XCTAssertEqual(LyricsTextPresentation.render(line: source, simplifiedChinese: false), source)
    }
    func testDisplayConversionPreservesBlankInterludesAndNonChineseText() {
        XCTAssertEqual(LyricsTextPresentation.render(line: "", simplifiedChinese: true), "")
        XCTAssertEqual(LyricsTextPresentation.render(line: "Hello — 123 🎵", simplifiedChinese: true), "Hello — 123 🎵")
    }
    private func track(_ title: String = "Song", duration: Double = 180, album: String = "Album") -> LyricsTrack {
        LyricsTrack(source: "com.netease.163music", title: title, artist: "Artist", album: album, duration: duration)
    }
    private func record(title: String = "Song", artist: String = "Artist", album: String = "Album",
                        duration: Double = 180, lyric: String = "[00:01]Correct", id: Int = 1) -> LRCLIBRecord {
        LRCLIBRecord(id: id, trackName: title, artistName: artist, albumName: album,
                     duration: duration, instrumental: false, syncedLyrics: lyric)
    }

    func testFractionalTimestampsRespectTheirPrecision() {
        let cues = LRCParser.parse("[00:01.5]a\n[00:01.05]b\n[00:01.500]c\n[123:59.999]d")
        XCTAssertEqual(cues.map(\.time), [1.05, 1.5, 7439.999])
        XCTAssertEqual(cues[1].text, "a · c")
    }
    func testMultipleTimestampsCreateRepeatedCueWithoutLeakingTags() {
        XCTAssertEqual(LRCParser.parse("[00:02.00][00:12.50]副歌"), [LyricCue(time: 2, text: "副歌"), LyricCue(time: 12.5, text: "副歌")])
    }
    func testOffsetMetadataAndCRLFAreParsedWithoutBecomingLyrics() {
        let cues = LRCParser.parse("[ar:Someone]\r\n[offset:+500]\r\n[00:02] Line \r\n")
        XCTAssertEqual(cues, [LyricCue(time: 1.5, text: "Line")])
        XCTAssertEqual(LRCParser.parse("[offset:-100]\n[00:00]Start").first?.time, 0.1)
    }
    func testBeforeFirstCueAndEmptyInterludeRemainEmpty() {
        let document = LyricsDocument(cues: LRCParser.parse("[00:05]First\n[00:08]\n[00:10]Second"))
        XCTAssertEqual(document.line(at: 0), "")
        XCTAssertEqual(document.line(at: 4.99), "")
        XCTAssertEqual(document.line(at: 5), "First")
        XCTAssertEqual(document.line(at: 8.1), "")
        XCTAssertEqual(document.line(at: 10), "Second")
    }
    func testSeekBackwardsUsesClockNotPreviouslyDisplayedIndex() {
        let document = LyricsDocument(cues: LRCParser.parse("[00:01]One\n[00:05]Two\n[00:10]Three"))
        XCTAssertEqual(document.line(at: 12), "Three")
        XCTAssertEqual(document.line(at: 2), "One")
        XCTAssertEqual(document.line(at: .nan), "")
        XCTAssertEqual(document.line(at: -.infinity), "")
    }
    func testDuplicateTranslationsCombineAndRepeatedIdenticalTextDeduplicates() {
        XCTAssertEqual(LRCParser.parse("[00:01]Hello\n[00:01]你好\n[00:01]Hello"), [LyricCue(time: 1, text: "Hello · 你好")])
    }
    func testInvalidSecondsAndPlainTextDoNotPretendToBeSynchronized() {
        XCTAssertEqual(LRCParser.parse("Plain lyric\n[00:99]Bad\n[00:01.1234]Too many decimals"), [])
    }
    func testOversizedLyricPayloadAndCueCountsAreBounded() {
        XCTAssertTrue(LRCParser.parse(String(repeating: "a", count: 256_001)).isEmpty)
        XCTAssertTrue(LRCParser.parse(String(repeating: "[00:01]Line\n", count: 4_097)).isEmpty)
    }
    func testSearchRejectsWrongArtistAlbumVersionAndDuration() {
        let expected = track()
        for wrong in [record(title: "Song (Live)"), record(artist: "Cover Artist"), record(album: "Concert"), record(duration: 181.01)] {
            XCTAssertFalse(wrong.matches(expected))
        }
        XCTAssertTrue(record(title: "  SONG ", artist: "ARTIST", duration: 181).matches(expected))
    }
    func testSearchSelectsValidatedClosestDurationNotFirstResult() {
        let result = LRCLIBRecord.bestMatch([record(title: "Other", lyric: "[00:01]Wrong"),
                                           record(duration: 181.5, lyric: "[00:01]Less precise", id: 2),
                                           record(duration: 180.1)], track: track())
        XCTAssertEqual(result?.line(at: 1), "Correct")
    }
    func testAmbiguousUnversionedSearchAndPlainLyricsHaveNoSyncedResult() {
        XCTAssertNil(LRCLIBRecord.bestMatch([record(), record(id: 2)], track: track(duration: 0, album: "")))
        XCTAssertNil(record(lyric: "Just a plain song").document)
    }
    func testUnknownAlbumRejectsRealExampleOfSimilarDurationButDifferentClock() {
        let request = track(duration: 309, album: "")
        let compilation = record(album: "世纪之歌", duration: 310, lyric: "[00:39.33]Other clock")
        let original = record(album: "我与你", duration: 309, lyric: "[00:36.12]Expected clock", id: 2)
        XCTAssertFalse(compilation.matches(request))
        XCTAssertNil(LRCLIBRecord.bestMatch([compilation], track: request))
        XCTAssertEqual(LRCLIBRecord.bestMatch([compilation, original], track: request)?.cues.first?.time, 36.12)
    }
    func testUnknownAlbumUsesHalfSecondToleranceAndClosestCandidate() {
        let request = track(duration: 180.123, album: "")
        XCTAssertTrue(record(duration: 180.623).matches(request))
        XCTAssertFalse(record(duration: 180.624).matches(request))
        let selected = LRCLIBRecord.bestMatch([record(duration: 180.5, lyric: "[00:03]Further"),
                                               record(duration: 180.12, lyric: "[00:02]Closer", id: 2)], track: request)
        XCTAssertEqual(selected?.cues.first?.time, 2)
    }
    func testUnknownAlbumRejectsNearTiesWithDifferentLyricsOrClock() {
        let request = track(album: "")
        let first = record(duration: 180.1, lyric: "[00:02]A")
        XCTAssertNil(LRCLIBRecord.bestMatch([first, record(duration: 179.9, lyric: "[00:03]A", id: 2)], track: request))
        XCTAssertNil(LRCLIBRecord.bestMatch([first, record(duration: 180.12, lyric: "[00:02]B", id: 2)], track: request))
    }
    func testUnknownAlbumAcceptsIdenticalDocumentTiesAndTrulyUniqueUndatedRecord() {
        let first = record(duration: 180.1)
        XCTAssertNotNil(LRCLIBRecord.bestMatch([first, record(duration: 179.9, id: 2)], track: track(album: "")))
        XCTAssertNotNil(LRCLIBRecord.bestMatch([first], track: track(duration: 0, album: "")))
    }
    func testUnknownAlbumRejectsSaturatedSearchPageWithoutClaimingGlobalUniqueness() {
        let page = (0..<20).map { record(title: $0 == 0 ? "Song" : "Other \($0)", id: $0) }
        XCTAssertNil(LRCLIBRecord.bestMatch(page, track: track(album: "")))
        XCTAssertNotNil(LRCLIBRecord.bestMatch(page, track: track()), "Known album keeps the existing validated path")
    }
    func testInstrumentalRecordIsExplicitlyAnEmptyDocument() {
        let item = LRCLIBRecord(id: 1, trackName: "Song", artistName: "Artist", albumName: "Album", duration: 180,
                               instrumental: true, syncedLyrics: nil)
        XCTAssertEqual(item.document, LyricsDocument(cues: [], instrumental: true))
    }
    func testNegativeCacheHitIsDifferentFromMissAndExpires() {
        var cache = LyricsCache()
        cache.insert(nil, for: track(), now: 100, lifetime: 10)
        let hit = cache.lookup(track(), now: 109)
        XCTAssertNotNil(hit)
        XCTAssertNil(hit?.document)
        XCTAssertNil(cache.lookup(track(), now: 110))
    }
    func testBoundedCacheEvictsLeastRecentlyUsedTrack() {
        var cache = LyricsCache(capacity: 2)
        cache.insert(nil, for: track("A"), now: 0, lifetime: 100)
        cache.insert(nil, for: track("B"), now: 1, lifetime: 100)
        XCTAssertNotNil(cache.lookup(track("A"), now: 2))
        cache.insert(nil, for: track("C"), now: 3, lifetime: 100)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.lookup(track("B"), now: 4))
        XCTAssertNotNil(cache.lookup(track("A"), now: 4))
    }
    func testTrackKeysSeparateApplicationsVersionsAndDurations() {
        XCTAssertNotEqual(track(), track(album: "Deluxe"))
        XCTAssertNotEqual(track(), track(duration: 181))
        XCTAssertNotEqual(track(), LyricsTrack(source: "another.app", title: "Song", artist: "Artist", album: "Album", duration: 180))
        XCTAssertEqual(track(duration: .nan).duration, 0)
    }
    func testPlaybackClockHandlesPauseRateSeekAndUnknownDuration() {
        XCTAssertEqual(LyricsPlaybackClock.position(elapsed: 5, timestamp: 100, now: 103, duration: 60, rate: 2, playing: true), 11)
        XCTAssertEqual(LyricsPlaybackClock.position(elapsed: 5, timestamp: 100, now: 103, duration: 60, rate: 2, playing: false), 5)
        XCTAssertEqual(LyricsPlaybackClock.position(elapsed: 59, timestamp: 100, now: 103, duration: 60, rate: 1, playing: true), 60)
        XCTAssertEqual(LyricsPlaybackClock.position(elapsed: 5, timestamp: 100, now: 103, duration: 0, rate: 1, playing: true), 8)
        XCTAssertEqual(LyricsPlaybackClock.position(elapsed: 5, timestamp: 100, now: 99, duration: 60, rate: 1, playing: true), 5)
    }
    func testChineseMetadataScriptsMatchWithoutLooseningVersionChecks() {
        let request = LyricsTrack(source: "com.netease.163music", title: "街道", artist: "林俊杰", album: "JJ陆", duration: 242)
        XCTAssertTrue(record(title: "街道", artist: "林俊傑", album: "JJ陸", duration: 242).matches(request))
        XCTAssertTrue(record(title: "街道", artist: "JJ Lin 林俊傑", album: "JJ陸", duration: 242).matches(request))
        XCTAssertFalse(record(title: "街道", artist: "林俊杰[PT80]", album: "JJ陸", duration: 242).matches(request))
        XCTAssertFalse(record(title: "街道", artist: "林俊杰", album: "I AM 世界巡回演唱会", duration: 220).matches(request))
        XCTAssertFalse(record(title: "街道 (Live)", artist: "林俊傑", album: "JJ陸", duration: 242).matches(request))
    }

}
