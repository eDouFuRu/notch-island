import XCTest
@testable import NotchInteractionCore

final class CaptureRecoveryPolicyTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/Users/test/Desktop", isDirectory: true)
    private let start = Date(timeIntervalSince1970: 1_000)
    private let finish = Date(timeIntervalSince1970: 1_010)

    private func file(_ name: String = "new.png", created: Double = 1_009,
                      modified: Double = 1_009, bytes: Int64 = 100,
                      tagged: Bool = true, symlink: Bool = false,
                      folder: URL? = nil) -> CaptureFileCandidate {
        .init(url: (folder ?? directory).appendingPathComponent(name),
              creationDate: Date(timeIntervalSince1970: created), modificationDate: Date(timeIntervalSince1970: modified),
              byteCount: bytes, isRegularFile: true, isSymbolicLink: symlink, isSystemScreenshot: tagged)
    }

    private func policy(existing: [CaptureFileCandidate] = []) -> CaptureRecoveryPolicy {
        .init(directory: directory, startedAt: start, finishedAt: finish, existing: existing)
    }

    func testUniqueNewScreenshotMustBeStableAndWithinTheExplicitSession() {
        var recovery = policy()
        let candidate = file()
        XCTAssertEqual(recovery.evaluate([candidate], currentDirectory: directory, permitted: true, now: finish), .waiting)
        XCTAssertEqual(recovery.evaluate([candidate], currentDirectory: directory, permitted: true,
                                         now: finish.addingTimeInterval(0.5)), .unique(candidate))
    }

    func testFloatingThumbnailDelayedWriteIsAcceptedWithinFifteenSeconds() {
        var recovery = policy()
        let delayed = file(created: 1_016, modified: 1_016)
        XCTAssertEqual(recovery.evaluate([], currentDirectory: directory, permitted: true, now: finish), .waiting)
        XCTAssertEqual(recovery.evaluate([delayed], currentDirectory: directory, permitted: true,
                                         now: Date(timeIntervalSince1970: 1_016.5)), .waiting)
        XCTAssertEqual(recovery.evaluate([delayed], currentDirectory: directory, permitted: true,
                                         now: Date(timeIntervalSince1970: 1_017)), .unique(delayed))
    }

    func testHistoricalAndBaselineFilesAreExcludedEvenWhenRetagged() {
        let baseline = file("existing.png", created: 1_001)
        var recovery = policy(existing: [baseline])
        let old = file("old.png", created: 999)
        for _ in 0..<3 {
            XCTAssertEqual(recovery.evaluate([baseline, old], currentDirectory: directory, permitted: true, now: finish), .waiting)
        }
        XCTAssertEqual(recovery.evaluate([baseline, old], currentDirectory: directory, permitted: true,
                                         now: finish.addingTimeInterval(15)), .timedOut)
    }

    func testMultipleCandidatesAreAmbiguousRatherThanPickingNewestOrPreviouslyImported() {
        var recovery = policy()
        XCTAssertEqual(recovery.evaluate([file("one.png"), file("two.png")], currentDirectory: directory,
                                         permitted: true, now: finish), .ambiguous)
    }

    func testDirectoryChangeOrPrivacyInterruptionRejectsEvenAStableMatch() {
        var recovery = policy()
        let candidate = file()
        _ = recovery.evaluate([candidate], currentDirectory: directory, permitted: true, now: finish)
        XCTAssertEqual(recovery.evaluate([candidate], currentDirectory: directory, permitted: false, now: finish), .interrupted)
        XCTAssertEqual(recovery.evaluate([candidate], currentDirectory: directory.appendingPathComponent("different"),
                                         permitted: true, now: finish), .directoryChanged)
        XCTAssertEqual(recovery.evaluate(nil, currentDirectory: directory, permitted: true, now: finish), .unreadable)
    }

    func testNoSymlinksOrdinaryImagesVideosOrSubfolderScan() {
        var recovery = policy()
        let excluded = [file(tagged: false), file(symlink: true), file("video.mov"),
                        file(folder: directory.appendingPathComponent("private"))]
        for _ in 0..<3 {
            XCTAssertEqual(recovery.evaluate(excluded, currentDirectory: directory, permitted: true, now: finish), .waiting)
        }
    }

    func testUnstableOrLateWritesNeverBecomeSuccessAtTimeout() {
        var recovery = policy()
        let empty = file(bytes: 0)
        XCTAssertEqual(recovery.evaluate([empty], currentDirectory: directory, permitted: true, now: finish), .waiting)
        XCTAssertEqual(recovery.evaluate([empty], currentDirectory: directory, permitted: true,
                                         now: finish.addingTimeInterval(15)), .timedOut)
        let tooLate = file(created: 1_026, modified: 1_026)
        XCTAssertEqual(recovery.evaluate([tooLate], currentDirectory: directory, permitted: true,
                                         now: finish.addingTimeInterval(17)), .timedOut)
    }

    func testObserverFirstAndRecoveryFirstBothProduceOneImport() {
        for automaticObserverFirst in [false, true] {
            var ledger = CaptureImportLedger()
            var recovery = policy()
            let candidate = file()
            var copyCount = 0
            func copyIfNeeded() {
                if !ledger.contains(candidate) { copyCount += 1; ledger.recordSuccessfulImport(candidate) }
            }
            if automaticObserverFirst { copyIfNeeded() }
            _ = recovery.evaluate([candidate], currentDirectory: directory, permitted: true, now: finish)
            guard case .unique = recovery.evaluate([candidate], currentDirectory: directory, permitted: true,
                                                   now: finish.addingTimeInterval(0.5)) else {
                return XCTFail("The explicit session must recognize the observer's same candidate")
            }
            copyIfNeeded()
            if !automaticObserverFirst { copyIfNeeded() }
            XCTAssertEqual(copyCount, 1)
            XCTAssertTrue(ledger.contains(candidate))
        }
    }

    func testFailedCopyDoesNotReserveLedgerAndDifferentCaptureCanReuseAPath() {
        var ledger = CaptureImportLedger()
        let candidate = file()
        XCTAssertFalse(ledger.contains(candidate)) // Copy failed; do not acknowledge it.
        XCTAssertFalse(ledger.contains(candidate))
        ledger.recordSuccessfulImport(candidate)
        XCTAssertTrue(ledger.contains(candidate))
        XCTAssertFalse(ledger.contains(file(created: 1_020, modified: 1_020)))
    }
}
