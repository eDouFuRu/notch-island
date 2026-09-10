import XCTest
@testable import NotchInteractionCore

final class SerialScalarControlTests: XCTestCase {
    @MainActor func testRapidRelativeCommandsReadLatestResultAndNeverOverlapWrites() async {
        var value: Float = 0.25
        var activeWrites = 0, maximumWrites = 0
        var results: [ScalarControlResult] = []
        let control = SerialScalarControl(read: { value }, write: { target in
            activeWrites += 1
            maximumWrites = max(maximumWrites, activeWrites)
            try? await Task.sleep(for: .milliseconds(2))
            value = target
            activeWrites -= 1
            return true
        }, receive: { results.append($0) })
        for _ in 0..<4 { control.enqueue(.relative(1 / 16)) }
        await control.waitUntilIdle()
        XCTAssertEqual(value, 0.5)
        XCTAssertEqual(maximumWrites, 1)
        XCTAssertEqual(results.compactMap(\.value), [0.3125, 0.375, 0.4375, 0.5])
    }

    @MainActor func testReadbackRatherThanRequestedTargetIsPublished() async {
        var value: Float = 0.3
        var result: ScalarControlResult?
        let control = SerialScalarControl(read: { value }, write: { _ in value = 0.625; return true }, receive: { result = $0 })
        control.enqueue(.absolute(0.6))
        await control.waitUntilIdle()
        XCTAssertEqual(result?.value, 0.625)
        XCTAssertNil(result?.failure)
    }

    @MainActor func testWriteFailureReportsActualUnchangedValue() async {
        var result: ScalarControlResult?
        let control = SerialScalarControl(read: { 0.3 }, write: { _ in false }, receive: { result = $0 })
        control.enqueue(.absolute(0.9))
        await control.waitUntilIdle()
        XCTAssertEqual(result?.value, 0.3)
        XCTAssertEqual(result?.failure, .writeFailed)
    }

    @MainActor func testMissingReadbackNeverInventsTargetValue() async {
        var hasWritten = false
        var result: ScalarControlResult?
        let control = SerialScalarControl(read: { hasWritten ? nil : 0.3 }, write: { _ in hasWritten = true; return true }, receive: { result = $0 })
        control.enqueue(.absolute(0.9))
        await control.waitUntilIdle()
        XCTAssertNil(result?.value)
        XCTAssertEqual(result?.failure, .readbackUnavailable)
    }

    @MainActor func testUnavailableInitialReadDoesNotWrite() async {
        var writes = 0
        var result: ScalarControlResult?
        let control = SerialScalarControl(read: { nil }, write: { _ in writes += 1; return true }, receive: { result = $0 })
        control.enqueue(.relative(0.1))
        await control.waitUntilIdle()
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(result?.failure, .readUnavailable)
    }

    @MainActor func testInvalidAndClampedCommandsAndPassiveRefresh() async {
        var value: Float = 0.5
        var writes: [Float] = []
        var results: [ScalarControlResult] = []
        let control = SerialScalarControl(read: { value }, write: { target in writes.append(target); value = target; return true }, receive: { results.append($0) })
        control.enqueue(.absolute(.nan))
        control.enqueue(.absolute(2))
        control.enqueue(.relative(-3))
        control.enqueue(.refresh)
        await control.waitUntilIdle()
        XCTAssertEqual(writes, [1, 0])
        XCTAssertEqual(results.first?.failure, .invalidValue)
        XCTAssertEqual(results.last?.value, 0)
        XCTAssertEqual(results.last?.shouldPresent, false)
    }

    @MainActor func testAvailabilityChangeCancelsBeforeWritingAfterAnAsyncRead() async {
        var generation = 0
        var writes = 0
        var readStarted = false
        var finishRead: CheckedContinuation<Float?, Never>?
        var results: [ScalarControlResult] = []
        let control = SerialScalarControl(read: {
            readStarted = true
            return await withCheckedContinuation { finishRead = $0 }
        }, write: { _ in writes += 1; return true }, receive: { results.append($0) })
        control.enqueue(.relative(0.1), isCurrent: { generation == 0 })
        control.enqueue(.absolute(0.9), isCurrent: { generation == 0 })
        while !readStarted { await Task.yield() }
        generation += 1
        finishRead?.resume(returning: 0.5)
        await control.waitUntilIdle()
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(results.map(\.failure), [.cancelled, .cancelled])
        XCTAssertTrue(results.allSatisfy { !$0.shouldPresent })
    }

    func testXPCReplyIsCompletedExactlyOnceAcrossReplyErrorAndTimeout() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
        }
        let counter = Counter()
        let reply = OneShotReply<Int> { _ in counter.increment() }
        DispatchQueue.concurrentPerform(iterations: 100) { index in reply.finish(index) }
        XCTAssertEqual(counter.count, 1)
        XCTAssertFalse(reply.finish(-1))
    }
}
