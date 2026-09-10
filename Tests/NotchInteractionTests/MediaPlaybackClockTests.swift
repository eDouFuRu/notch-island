import XCTest
@testable import NotchInteractionCore

final class MediaPlaybackClockTests: XCTestCase {
    private let running = MediaPlaybackClock(elapsed: 10, timestamp: 100, rate: 1, playing: true)

    func testAdapterMicrosecondSamplePreservesFractionalClockAndDuration() throws {
        // Time fields observed from the installed adapter, without user content.
        let update = try JSONDecoder().decode(NowPlayingUpdate.self, from: Data(#"{"diff":false,"payload":{"elapsedTimeMicros":54814343,"timestampEpochMicros":1788710116089047,"durationMicros":222693333,"playbackRate":0,"playing":false}}"#.utf8))
        XCTAssertEqual(update.payload.resolvedElapsedTime!, 54.814343, accuracy: 0.000001)
        XCTAssertEqual(update.payload.resolvedDuration!, 222.693333, accuracy: 0.000001)
        XCTAssertEqual(update.payload.resolvedTimestamp!, 1788710116.089047, accuracy: 0.000001)
    }

    func testLegacyWholeAndFractionalISOTimestampsRemainSupported() throws {
        let whole = try payload(#"{"elapsedTime":54.8,"timestamp":"2026-09-06T15:55:16Z","duration":222.6}"#)
        let fractional = try payload(#"{"timestamp":"2026-09-06T15:55:16.089Z"}"#)
        XCTAssertEqual(whole.resolvedTimestamp!, 1788710116, accuracy: 0.001)
        XCTAssertEqual(fractional.resolvedTimestamp! - whole.resolvedTimestamp!, 0.089, accuracy: 0.001)
        XCTAssertEqual(whole.resolvedElapsedTime, 54.8)
        XCTAssertEqual(whole.resolvedDuration, 222.6)
    }

    func testMicrosWinOverRoundedLegacyFields() throws {
        let sample = try payload(#"{"elapsedTime":1,"elapsedTimeMicros":1234567,"timestamp":"2026-09-06T15:55:16Z","timestampEpochMicros":1788710116089047}"#)
        XCTAssertEqual(sample.resolvedElapsedTime!, 1.234567, accuracy: 0.000001)
        XCTAssertEqual(sample.resolvedTimestamp!, 1788710116.089047, accuracy: 0.000001)
    }

    func testPauseAndResumeExcludePausedWallTime() {
        let paused = merge(running, playing: false, now: 105)
        XCTAssertEqual(paused.elapsed, 15)
        XCTAssertEqual(paused.timestamp, 105)
        XCTAssertEqual(paused.position(at: 130), 15)
        let resumed = merge(paused, playing: true, now: 135)
        XCTAssertEqual(resumed.elapsed, 15)
        XCTAssertEqual(resumed.timestamp, 135)
        XCTAssertEqual(resumed.position(at: 137), 17)
    }

    func testRepeatedPauseDoesNotAccumulateTime() {
        let paused = merge(running, rate: 0, playing: false, now: 105)
        let repeated = merge(paused, rate: 0, playing: false, now: 125)
        XCTAssertEqual(repeated, paused)
        let resumed = merge(repeated, rate: 1, playing: true, now: 140)
        XCTAssertEqual(resumed.position(at: 142), 17)
    }

    func testRateChangeReanchorsUsingPreviousRate() {
        let faster = merge(running, rate: 2, now: 105)
        XCTAssertEqual(faster.elapsed, 15)
        XCTAssertEqual(faster.position(at: 107), 19)
    }

    func testMetadataOnlyUpdatePreservesClock() {
        XCTAssertEqual(merge(running, now: 150), running)
    }

    func testSeekUsesExactPairedSampleAndAccountsForDeliveryDelay() {
        let seek = merge(running, elapsed: 50.25, timestamp: 106.5, now: 107)
        XCTAssertEqual(seek.position(at: 107), 50.75)
        let backwards = merge(seek, elapsed: 2, timestamp: 108.25, now: 108.5)
        XCTAssertEqual(backwards.position(at: 108.5), 2.25)
    }

    func testElapsedOnlySampleUsesReceiptInsteadOfOldTimestamp() {
        let changed = merge(running, elapsed: 50, now: 120)
        XCTAssertEqual(changed.position(at: 121), 51)
    }

    func testLegacyTimestampOnlyDiffRetainsCompanionElapsedValue() {
        let changed = merge(running, timestamp: 120, now: 120.5)
        XCTAssertEqual(changed.position(at: 120.5), 10.5)
    }

    func testTrackChangeWithoutPositionNeverInheritsOldTrackClock() {
        let changed = merge(running, playing: true, now: 120, reset: true)
        XCTAssertEqual(changed.elapsed, 0)
        XCTAssertEqual(changed.position(at: 121), 1)
    }

    func testCompletePausedSnapshotDoesNotEstimateWithPreviousPlaybackRate() {
        let changed = merge(running, elapsed: 54.814343, timestamp: 105.089047,
                            rate: 0, playing: false, now: 130, reset: true)
        XCTAssertEqual(changed.position(at: 150), 54.814343)
    }

    func testInvalidOrUninitializedClockCannotJumpToEndOfTrack() {
        let invalid = MediaPlaybackClock(elapsed: 5, timestamp: -100000, rate: 1, playing: true)
        XCTAssertEqual(invalid.position(at: 100, duration: 200), 5)
        XCTAssertEqual(running.position(at: 500, duration: 200), 200)
        XCTAssertEqual(running.position(at: 90), 10)
    }

    private func payload(_ json: String) throws -> NowPlayingPayload {
        try JSONDecoder().decode(NowPlayingPayload.self, from: Data(json.utf8))
    }

    private func merge(_ previous: MediaPlaybackClock, elapsed: Double? = nil, timestamp: TimeInterval? = nil,
                       rate: Double? = nil, playing: Bool? = nil, now: TimeInterval,
                       reset: Bool = false) -> MediaPlaybackClock {
        .merging(previous: previous, elapsed: elapsed, timestamp: timestamp, rate: rate,
                 playing: playing, now: now, duration: 200, reset: reset)
    }
}
