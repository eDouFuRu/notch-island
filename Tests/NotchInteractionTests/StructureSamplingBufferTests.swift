import XCTest
@testable import NotchInteractionCore

final class StructureSamplingBufferTests: XCTestCase {
    func testOnlyChangesRemainAndReturningToBaselineIsPreserved() {
        var buffer = StructureSamplingBuffer(startedAt: 100)
        XCTAssertTrue(buffer.record(at: 100, fingerprint: "baseline", summary: "baseline age 0"))
        XCTAssertFalse(buffer.record(at: 101, fingerprint: "baseline", summary: "baseline age 1"))
        XCTAssertTrue(buffer.record(at: 102, fingerprint: "banner", summary: "banner exists"))
        XCTAssertFalse(buffer.record(at: 103, fingerprint: "banner", summary: "banner still exists"))
        XCTAssertTrue(buffer.record(at: 104, fingerprint: "baseline", summary: "baseline again"))
        XCTAssertEqual(buffer.samples.map(\.offset), [0, 2, 4])
        XCTAssertEqual(buffer.samples.map(\.summary), ["baseline age 0", "banner exists", "baseline again"])
        XCTAssertEqual(buffer.attempts, 5)
    }

    func testExpiresAtThirtySecondsAndRejectsNonmonotonicOrInvalidTimes() {
        var buffer = StructureSamplingBuffer(startedAt: 100)
        XCTAssertTrue(buffer.record(at: 100, fingerprint: "a", summary: "a"))
        XCTAssertFalse(buffer.record(at: 99, fingerprint: "b", summary: "b"))
        XCTAssertTrue(buffer.record(at: 129.9, fingerprint: "b", summary: "b"))
        XCTAssertFalse(buffer.record(at: 129, fingerprint: "c", summary: "c"))
        XCTAssertFalse(buffer.record(at: 130, fingerprint: "c", summary: "c"))
        XCTAssertFalse(buffer.record(at: .nan, fingerprint: "c", summary: "c"))
        XCTAssertFalse(buffer.record(at: .infinity, fingerprint: "c", summary: "c"))
        XCTAssertEqual(buffer.attempts, 2)
        XCTAssertTrue(buffer.isExpired(at: 130))
    }

    func testReadAttemptsAndSummaryMemoryAreBoundedEvenWhenEveryStructureDiffers() {
        var buffer = StructureSamplingBuffer(startedAt: 0)
        for index in 0..<50 {
            buffer.record(at: Double(index) / 10, fingerprint: "\(index)",
                          summary: String(repeating: "x", count: StructureSamplingBuffer.summaryLimit + 100))
        }
        XCTAssertEqual(buffer.attempts, 30)
        XCTAssertEqual(buffer.samples.count, 30)
        XCTAssertTrue(buffer.samples.allSatisfy { $0.summary.count == StructureSamplingBuffer.summaryLimit })
        XCTAssertTrue(buffer.isExpired(at: 5))
    }

    func testNewSamplingSessionReplacesPreviousEvidence() {
        var buffer = StructureSamplingBuffer(startedAt: 0)
        buffer.record(at: 0, fingerprint: "old", summary: "old session")
        buffer = StructureSamplingBuffer(startedAt: 60)
        XCTAssertTrue(buffer.samples.isEmpty)
        XCTAssertEqual(buffer.attempts, 0)
        XCTAssertEqual(buffer.summary, "")
        XCTAssertTrue(buffer.record(at: 60, fingerprint: "old", summary: "new session baseline"))
        XCTAssertEqual(buffer.samples.first?.offset, 0)
    }
}
