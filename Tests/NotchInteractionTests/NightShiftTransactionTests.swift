import XCTest
@testable import NotchInteractionCore

final class NightShiftTransactionTests: XCTestCase {
    private func reading(_ enabled: Bool) -> NightShiftReading {
        .init(enabled: enabled, availability: .available)
    }

    func testRefreshReadsBothStatesWithoutWriting() {
        for enabled in [false, true] {
            var writes = 0
            let result = NightShiftTransaction.execute(.refresh, read: { self.reading(enabled) }, write: { _ in writes += 1; return true })
            XCTAssertEqual(result.enabled, enabled)
            XCTAssertEqual(result.availability, .available)
            XCTAssertNil(result.failure)
            XCTAssertEqual(writes, 0)
        }
    }

    func testUnavailableReadNeverMeansOffOrWrites() {
        for availability: NightShiftAvailability in [.unknown, .unsupportedABI, .unsupportedHardware, .temporarilyUnavailable] {
            var writes = 0
            let result = NightShiftTransaction.execute(.toggle(expectedEnabled: false), read: {
                .init(enabled: false, availability: availability)
            }, write: { _ in writes += 1; return true })
            XCTAssertNil(result.enabled)
            XCTAssertNotNil(result.failure)
            XCTAssertEqual(result.availability, availability)
            XCTAssertEqual(writes, 0)
        }
    }

    func testMalformedAvailableReadingDoesNotWrite() {
        let result = NightShiftTransaction.execute(.toggle(expectedEnabled: false), read: {
            .init(enabled: nil, availability: .available)
        }, write: { _ in XCTFail("Missing state must not be toggled"); return true })
        XCTAssertNil(result.enabled)
        XCTAssertEqual(result.failure, .readFailed)
    }

    func testExpectedStateMismatchPublishesCurrentValueWithoutWriting() {
        let result = NightShiftTransaction.execute(.toggle(expectedEnabled: false), read: { self.reading(true) }, write: { _ in
            XCTFail("An external state change must not be overwritten"); return true
        })
        XCTAssertEqual(result.enabled, true)
        XCTAssertEqual(result.failure, .changedBeforeWrite)
    }

    func testBothToggleDirectionsRequireAcceptedWriteAndReadback() {
        for original in [false, true] {
            var reads = 0
            var written: [Bool] = []
            let result = NightShiftTransaction.execute(.toggle(expectedEnabled: original), read: {
                reads += 1
                return self.reading(reads == 1 ? original : !original)
            }, write: { written.append($0); return true })
            XCTAssertEqual(written, [!original])
            XCTAssertEqual(result.enabled, !original)
            XCTAssertNil(result.failure)
            XCTAssertEqual(reads, 2)
        }
    }

    func testRejectedWriteCannotBecomeSuccessFromCoincidentalReadback() {
        var reads = 0
        var writes = 0
        let result = NightShiftTransaction.execute(.toggle(expectedEnabled: false), read: {
            reads += 1
            return self.reading(reads > 1)
        }, write: { _ in writes += 1; return false })
        XCTAssertEqual(result.enabled, true)
        XCTAssertEqual(result.failure, .writeFailed)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reads, 2)
    }

    func testRejectedWriteAndFailedReadbackClearStaleValue() {
        var reads = 0
        let result = NightShiftTransaction.execute(.toggle(expectedEnabled: true), read: {
            reads += 1
            return reads == 1 ? self.reading(true) : .init(enabled: nil, availability: .temporarilyUnavailable)
        }, write: { _ in false })
        XCTAssertNil(result.enabled)
        XCTAssertEqual(result.availability, .temporarilyUnavailable)
        XCTAssertEqual(result.failure, .writeFailed)
    }

    func testDelayedConfirmationWaitsWithoutRepeatingSetter() {
        var reads = 0
        var writes = 0
        var waits = 0
        let result = NightShiftTransaction.execute(.toggle(expectedEnabled: false), read: {
            reads += 1
            return self.reading(reads >= 4)
        }, write: { _ in writes += 1; return true }, wait: { waits += 1 })
        XCTAssertEqual(result.enabled, true)
        XCTAssertNil(result.failure)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(waits, 2)
    }

    func testTransientReadbackCanRecoverWithinBound() {
        var reads = 0
        let result = NightShiftTransaction.execute(.toggle(expectedEnabled: false), read: {
            reads += 1
            if reads == 1 { return self.reading(false) }
            if reads == 2 { return .init(enabled: nil, availability: .temporarilyUnavailable) }
            return self.reading(true)
        }, write: { _ in true })
        XCTAssertEqual(result.enabled, true)
        XCTAssertNil(result.failure)
    }

    func testUnconfirmedWriteHasBoundedReadbackAndOneSetter() {
        var reads = 0
        var writes = 0
        var waits = 0
        let result = NightShiftTransaction.execute(.toggle(expectedEnabled: false), read: {
            reads += 1; return self.reading(false)
        }, write: { _ in writes += 1; return true }, wait: { waits += 1 })
        XCTAssertEqual(result.enabled, false)
        XCTAssertEqual(result.failure, .unconfirmed)
        XCTAssertEqual(reads, 1 + NightShiftTransaction.readbackAttempts)
        XCTAssertEqual(waits, NightShiftTransaction.readbackAttempts - 1)
        XCTAssertEqual(writes, 1)
        XCTAssertLessThanOrEqual(Double(waits) * NightShiftTransaction.readbackInterval, 0.75)
    }

    func testReadbackFailureNeverPublishesTargetOrOldValue() {
        var reads = 0
        let result = NightShiftTransaction.execute(.toggle(expectedEnabled: true), read: {
            reads += 1
            return reads == 1 ? self.reading(true) : .init(enabled: nil, availability: .temporarilyUnavailable)
        }, write: { _ in true })
        XCTAssertNil(result.enabled)
        XCTAssertEqual(result.failure, .readbackUnavailable)
        XCTAssertEqual(reads, 1 + NightShiftTransaction.readbackAttempts)
    }

    func testLostHardwareOrABIStopsReadbackImmediately() {
        for availability: NightShiftAvailability in [.unsupportedABI, .unsupportedHardware] {
            var reads = 0
            let result = NightShiftTransaction.execute(.toggle(expectedEnabled: false), read: {
                reads += 1
                return reads == 1 ? self.reading(false) : .init(enabled: nil, availability: availability)
            }, write: { _ in true }, wait: { XCTFail("Unsupported backend must not be polled") })
            XCTAssertNil(result.enabled)
            XCTAssertEqual(result.failure, .readbackUnavailable)
            XCTAssertEqual(reads, 2)
        }
    }

    func testDuplicateOperationIsRejectedWhileBusy() {
        var state = NightShiftPresentationState()
        let generation = state.begin()
        XCTAssertNotNil(generation)
        XCTAssertTrue(state.isBusy)
        XCTAssertNil(state.begin())
    }

    func testStaleCompletionCannotEndNewOperationOrReplaceState() throws {
        var state = NightShiftPresentationState()
        let first = try XCTUnwrap(state.begin())
        XCTAssertTrue(state.receive(.init(enabled: false, availability: .available, failure: nil), generation: first))
        let second = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.receive(.init(enabled: true, availability: .available, failure: nil), generation: first))
        XCTAssertTrue(state.isBusy)
        XCTAssertEqual(state.enabled, false)
        XCTAssertTrue(state.receive(.init(enabled: true, availability: .available, failure: nil), generation: second))
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.enabled, true)
    }

    func testNewOperationClearsPreviousErrorAndFailureClearsValue() throws {
        var state = NightShiftPresentationState()
        let first = try XCTUnwrap(state.begin())
        state.receive(.init(enabled: nil, availability: .temporarilyUnavailable, failure: .readFailed), generation: first)
        XCTAssertEqual(state.failure, .readFailed)
        XCTAssertNil(state.enabled)
        XCTAssertNotNil(state.begin())
        XCTAssertNil(state.failure)
    }

    func testSupportedDistinguishesUnknownCompatibilityAndHardware() {
        XCTAssertNil(NightShiftAvailability.unknown.supported)
        XCTAssertNil(NightShiftAvailability.unsupportedABI.supported)
        XCTAssertEqual(NightShiftAvailability.unsupportedHardware.supported, false)
        XCTAssertEqual(NightShiftAvailability.available.supported, true)
        XCTAssertEqual(NightShiftAvailability.temporarilyUnavailable.supported, true)
    }

    func testExactVerifiedRuntimeABIIsAccepted() {
        XCTAssertTrue(NightShiftRuntimeABI.accepts(getter: "B24@0:8^{?=BBBi{?={?=ii}{?=ii}}QB}16",
                                                 setter: "B20@0:8B16", support: "B16@0:8", factory: "@16@0:8"))
        XCTAssertEqual(NightShiftRuntimeABI.statusBytes, 40)
        XCTAssertEqual(NightShiftRuntimeABI.statusAlignment, 8)
        XCTAssertLessThan(NightShiftRuntimeABI.availableOffset, NightShiftRuntimeABI.statusBytes)
        XCTAssertLessThan(NightShiftRuntimeABI.enabledOffset, NightShiftRuntimeABI.statusBytes)
    }

    func testMissingOrIncompatibleRuntimeMethodsAreRejected() {
        let values = ["B24@0:8^{?=BBBi{?={?=ii}{?=ii}}QB}16", "B20@0:8B16", "B16@0:8", "@16@0:8"]
        for index in values.indices {
            for replacement: String? in [nil, "", "v16@0:8", "c16@0:8"] {
                var candidate = values.map(Optional.some)
                candidate[index] = replacement
                XCTAssertFalse(NightShiftRuntimeABI.accepts(getter: candidate[0], setter: candidate[1], support: candidate[2], factory: candidate[3]))
            }
        }
    }

    func testChangedPrivateStructureIsRejectedBeforeAnyFFIAccess() {
        XCTAssertFalse(NightShiftRuntimeABI.accepts(getter: "B24@0:8^{?=BBBi{?={?=ii}{?=ii}}IB}16",
                                                  setter: "B20@0:8B16", support: "B16@0:8", factory: "@16@0:8"))
    }
}
