import XCTest
@testable import NotchInteractionCore

final class CaptureFilePolicyTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Users/test/Desktop", isDirectory: true)
    private let start = Date(timeIntervalSince1970: 1_000)

    private func candidate(name: String = "capture.png", creation: TimeInterval = 1_001,
                           modification: TimeInterval = 1_001, size: Int64 = 20,
                           regular: Bool = true, symlink: Bool = false,
                           screenshot: Bool = true, directory: URL? = nil) -> CaptureFileCandidate {
        CaptureFileCandidate(url: (directory ?? folder).appendingPathComponent(name),
                             creationDate: Date(timeIntervalSince1970: creation),
                             modificationDate: Date(timeIntervalSince1970: modification),
                             byteCount: size, isRegularFile: regular, isSymbolicLink: symlink,
                             isSystemScreenshot: screenshot)
    }

    func testOnlyFreshStableScreenshotIsImportedOnce() {
        var policy = CaptureFilePolicy(directory: folder, startedAt: start)
        let image = candidate()
        let now = Date(timeIntervalSince1970: 1_002)
        XCTAssertFalse(policy.readyToImport(image, now: now))
        XCTAssertTrue(policy.readyToImport(image, now: now))
        // Failed copy can be retried; only successful add acknowledges the file.
        XCTAssertTrue(policy.readyToImport(image, now: now))
        policy.markImported(image)
        XCTAssertFalse(policy.readyToImport(image, now: now))
        XCTAssertFalse(policy.readyToImport(candidate(size: 40), now: now))
    }

    func testHistoricalImagesAndOrdinaryDownloadsAreNeverImported() {
        var policy = CaptureFilePolicy(directory: folder, startedAt: start)
        for image in [candidate(creation: 999), candidate(screenshot: false),
                      candidate(name: "Screen Shot.png", screenshot: false),
                      candidate(name: "capture.txt"), candidate(size: 0), candidate(regular: false)] {
            for _ in 0..<3 {
                XCTAssertFalse(policy.readyToImport(image, now: Date(timeIntervalSince1970: 1_002)))
            }
        }
    }

    func testNoSymlinksSubfoldersOrLookalikePrefixPaths() {
        var policy = CaptureFilePolicy(directory: folder, startedAt: start)
        for image in [candidate(symlink: true),
                      candidate(directory: folder.appendingPathComponent("private")),
                      candidate(directory: URL(fileURLWithPath: "/Users/test/Desktop-backup"))] {
            for _ in 0..<3 {
                XCTAssertFalse(policy.readyToImport(image, now: Date(timeIntervalSince1970: 1_002)))
            }
        }
    }

    func testFileMustFinishWritingBeforeCopy() {
        var policy = CaptureFilePolicy(directory: folder, startedAt: start)
        XCTAssertFalse(policy.readyToImport(candidate(), now: Date(timeIntervalSince1970: 1_001.1)))
        XCTAssertFalse(policy.readyToImport(candidate(), now: Date(timeIntervalSince1970: 1_002)))
        let larger = candidate(modification: 1_002, size: 40)
        XCTAssertFalse(policy.readyToImport(larger, now: Date(timeIntervalSince1970: 1_003)))
        XCTAssertTrue(policy.readyToImport(larger, now: Date(timeIntervalSince1970: 1_004)))
    }

    func testNewWatcherDoesNotReplayCapturesFromWhileHidden() {
        var resumed = CaptureFilePolicy(directory: folder, startedAt: Date(timeIntervalSince1970: 1_003))
        for _ in 0..<3 {
            XCTAssertFalse(resumed.readyToImport(candidate(), now: Date(timeIntervalSince1970: 1_004)))
        }
        let fresh = candidate(creation: 1_004, modification: 1_004)
        XCTAssertFalse(resumed.readyToImport(fresh, now: Date(timeIntervalSince1970: 1_005)))
        XCTAssertTrue(resumed.readyToImport(fresh, now: Date(timeIntervalSince1970: 1_006)))
    }

    func testCaptureSuppressionKeepsObservationEpochAndAcceptsFreshOutput() {
        var state = CaptureObservationState()
        XCTAssertTrue(state.update(enabled: true, manuallyHidden: false, screenUnavailable: false,
                                   captureInProgress: false, at: start))
        var policy = CaptureFilePolicy(directory: folder, startedAt: state.beganAt!)
        XCTAssertFalse(state.update(enabled: true, manuallyHidden: false, screenUnavailable: false,
                                    captureInProgress: true, at: start.addingTimeInterval(1)))
        XCTAssertEqual(state.gate, .observing)
        XCTAssertEqual(state.beganAt, start)
        let screenshot = candidate(creation: 1_002, modification: 1_002)
        XCTAssertFalse(policy.readyToImport(screenshot, now: Date(timeIntervalSince1970: 1_003)))
        XCTAssertTrue(policy.readyToImport(screenshot, now: Date(timeIntervalSince1970: 1_004)))
        policy.markImported(screenshot)
        XCTAssertFalse(state.update(enabled: true, manuallyHidden: false, screenUnavailable: false,
                                    captureInProgress: false, at: start.addingTimeInterval(5)))
        XCTAssertEqual(state.beganAt, start)
        XCTAssertFalse(policy.readyToImport(screenshot, now: Date(timeIntervalSince1970: 1_006)))
    }

    func testManualHideAndLockStillCutOffHistoryEvenDuringCapture() {
        for lockInsteadOfHide in [false, true] {
            var state = CaptureObservationState()
            state.update(enabled: true, manuallyHidden: false, screenUnavailable: false,
                         captureInProgress: true, at: start)
            XCTAssertTrue(state.update(enabled: true, manuallyHidden: !lockInsteadOfHide,
                                       screenUnavailable: lockInsteadOfHide, captureInProgress: true,
                                       at: start.addingTimeInterval(1)))
            XCTAssertNotEqual(state.gate, .observing)
            XCTAssertNil(state.beganAt)
            let resumedAt = start.addingTimeInterval(10)
            XCTAssertTrue(state.update(enabled: true, manuallyHidden: false, screenUnavailable: false,
                                       captureInProgress: true, at: resumedAt))
            var policy = CaptureFilePolicy(directory: folder, startedAt: state.beganAt!)
            XCTAssertEqual(state.beganAt, resumedAt)
            let historical = candidate(creation: 1_004, modification: 1_004)
            for _ in 0..<3 {
                XCTAssertFalse(policy.readyToImport(historical, now: resumedAt.addingTimeInterval(1)))
            }
        }
    }

    func testUserDisablingImportWinsOverCaptureAndReenableStartsFresh() {
        var state = CaptureObservationState()
        state.update(enabled: true, manuallyHidden: false, screenUnavailable: false,
                     captureInProgress: false, at: start)
        XCTAssertTrue(state.update(enabled: false, manuallyHidden: false, screenUnavailable: false,
                                   captureInProgress: true, at: start.addingTimeInterval(1)))
        XCTAssertEqual(state.gate, .disabled)
        XCTAssertNil(state.beganAt)
        XCTAssertFalse(state.update(enabled: false, manuallyHidden: false, screenUnavailable: false,
                                    captureInProgress: false, at: start.addingTimeInterval(2)))
        let reopened = start.addingTimeInterval(10)
        XCTAssertTrue(state.update(enabled: true, manuallyHidden: false, screenUnavailable: false,
                                   captureInProgress: true, at: reopened))
        XCTAssertEqual(state.beganAt, reopened)
    }

    func testCaptureArgumentsCannotOverrideDestinationAndDoNotInvokeAShell() {
        let output = URL(fileURLWithPath: "/tmp/space $(echo danger);'folder/result.png")
        for kind in CaptureToolKind.allCases {
            let arguments = kind.arguments(output: output, region: CaptureRegion(rect: CGRect(x: 10, y: 20, width: 300, height: 200)))
            if kind == .customRecording {
                XCTAssertTrue(arguments.isEmpty, "Custom recording must use the native recording API")
                continue
            }
            XCTAssertEqual(arguments.last, output.path)
            XCTAssertFalse(arguments.contains("-p"))
            XCTAssertFalse(arguments.contains("-u"))
            XCTAssertFalse(arguments.contains("-c"))
            XCTAssertFalse(arguments.contains("-g"), "Microphone must not silently turn on")
            XCTAssertEqual(arguments.filter { $0 == output.path }.count, 1)
        }
        XCTAssertTrue(CaptureToolKind.windowScreenshot.arguments(output: output).contains("-w"))
        XCTAssertTrue(CaptureToolKind.areaScreenshot.arguments(output: output).contains("-s"))
        XCTAssertTrue(CaptureToolKind.customScreenshot.arguments(output: output).contains("-U"))
        XCTAssertTrue(CaptureToolKind.fullRecording.arguments(output: output).contains("-v"))
    }
}
