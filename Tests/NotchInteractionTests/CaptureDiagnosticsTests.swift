import XCTest
@testable import NotchInteractionCore

final class CaptureDiagnosticsTests: XCTestCase {
    func testStderrIsReducedToFiniteCategoriesWithoutRetainingContents() {
        let cases: [(String, CaptureErrorCategory)] = [
            ("\n  ", .none),
            ("screencapture: user cancelled", .cancelled),
            ("Screen capture permission denied", .permission),
            ("Not authorized to capture", .permission),
            ("could not create image /Users/example/private-secret.png", .captureFailure),
            ("Unexpected details /Users/example/private-secret.png", .other)
        ]
        for (stderr, expected) in cases {
            let category = CaptureErrorCategory.classify(stderr)
            XCTAssertEqual(category, expected)
            var diagnostic = CaptureProcessDiagnostic(kind: .customScreenshot)
            diagnostic.error = category
            XCTAssertFalse(diagnostic.summary.contains("private-secret"))
            XCTAssertFalse(diagnostic.summary.contains("/Users/"))
        }
    }

    func testCancelledToolSessionAndMissingOutputAreDistinguishable() {
        let diagnostic = CaptureProcessDiagnostic(kind: .customScreenshot, phase: "finished",
                                                   startedAt: Date(timeIntervalSince1970: 1_000),
                                                   endedAt: Date(timeIntervalSince1970: 1_010), exitCode: 1,
                                                   userRequestedStop: false, output: .absent,
                                                   error: .cancelled, imported: false)
        XCTAssertTrue(diagnostic.summary.contains("Exit code: 1"))
        XCTAssertTrue(diagnostic.summary.contains("Output classification: absent"))
        XCTAssertTrue(diagnostic.summary.contains("User requested stop: false"))
        XCTAssertTrue(diagnostic.summary.contains("Imported: false"))
    }

    func testObserverGateAndReadFailureAreNotMistakenForEmptyDirectory() {
        let gated = CaptureImportDiagnostic(gate: "capture in progress")
        XCTAssertTrue(gated.summary.contains("Directory readable: not checked"))
        let denied = CaptureImportDiagnostic(gate: "observing", directoryReadable: false)
        XCTAssertTrue(denied.summary.contains("Directory readable: false"))
        let empty = CaptureImportDiagnostic(gate: "observing", directoryReadable: true)
        XCTAssertTrue(empty.summary.contains("Directory readable: true"))
        XCTAssertTrue(empty.summary.contains("Candidate files: 0"))
    }
}
