import XCTest
@testable import NotchInteractionCore

final class AppearanceToggleTests: XCTestCase {
    func testOnlyConfirmedOppositeReadbackSucceeds() {
        XCTAssertEqual(AppearanceToggleResult.decode("ok|0|1|0\n", exitCode: 0),
                       .init(enabled: true, failure: nil))
        XCTAssertEqual(AppearanceToggleResult.decode("ok|1|0|0\n", exitCode: 0),
                       .init(enabled: false, failure: nil))
    }

    func testUnchangedReadbackKeepsActualValueAndReportsFailure() {
        XCTAssertEqual(AppearanceToggleResult.decode("ok|0|0|0", exitCode: 0),
                       .init(enabled: false, failure: .unconfirmed))
        XCTAssertEqual(AppearanceToggleResult.decode("ok|1|1|0", exitCode: 0),
                       .init(enabled: true, failure: .unconfirmed))
    }

    func testConsentFailuresAtEveryStageDoNotInventCurrentState() {
        for stage in ["read|?", "write|0", "readback|1"] {
            for code in [-1743, -1744] {
                XCTAssertEqual(AppearanceToggleResult.decode("\(stage)|?|\(code)", exitCode: 0),
                               .failed(.authorizationRequired))
            }
        }
    }

    func testCancellationAndTimeoutRemainDistinctFromAuthorization() {
        XCTAssertEqual(AppearanceToggleResult.decode("read|?|?|-128", exitCode: 0), .failed(.cancelled))
        XCTAssertEqual(AppearanceToggleResult.decode("readback|0|?|-1712", exitCode: 0), .failed(.timedOut))
    }

    func testReadFailureAndPossibleWriteFailureAreDistinguished() {
        XCTAssertEqual(AppearanceToggleResult.decode("read|?|?|-1708", exitCode: 0), .failed(.unavailable))
        XCTAssertEqual(AppearanceToggleResult.decode("write|0|?|-10006", exitCode: 0), .failed(.unconfirmed))
        XCTAssertEqual(AppearanceToggleResult.decode("readback|1|?|-1708", exitCode: 0), .failed(.unconfirmed))
    }

    func testMalformedOutputNeverClaimsSuccessOrDisplaysRawErrors() {
        for output in ["", "true", "ok|0|1", "ok|0|1|0|extra", "ok|?|1|0", "ok|0|2|0",
                       "ok|0|1|-1743", "read|0|?|-1743", "write|?|?|-1743", "write|0|1|-1743",
                       "read|?|?|0", "unknown|0|1|-1743", "sensitive raw system error"] {
            XCTAssertEqual(AppearanceToggleResult.decode(output, exitCode: 0), .failed(.unavailable), output)
        }
        XCTAssertEqual(AppearanceToggleResult.decode(String(repeating: "x", count: 121), exitCode: 0), .failed(.unavailable))
    }

    func testNonzeroExitCannotBeOverriddenBySuccessText() {
        XCTAssertEqual(AppearanceToggleResult.decode("ok|0|1|0", exitCode: 1), .failed(.unavailable))
    }
}
