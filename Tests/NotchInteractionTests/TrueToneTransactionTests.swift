import XCTest
@testable import NotchInteractionCore

final class TrueToneTransactionTests: XCTestCase {
    private func known(_ enabled: Bool) -> TrueToneReading { .init(enabled: enabled, availability: .available) }
    private var unavailable: TrueToneReading { .init(enabled: nil, availability: .temporarilyUnavailable) }

    func testReadPolicyRequiresEveryCapabilityGate() {
        for bits in 0..<16 {
            let result = TrueToneReadPolicy.resolve(supportedBefore: bits & 1 != 0, availableBefore: bits & 2 != 0,
                                                  firstEnabled: false, secondEnabled: false,
                                                  supportedAfter: bits & 4 != 0, availableAfter: bits & 8 != 0)
            XCTAssertEqual(result.enabled, bits == 15 ? false : nil)
            XCTAssertEqual(result.availability, bits == 15 ? .available : .temporarilyUnavailable)
        }
    }

    func testReadPolicyPreservesConfirmedOnAndOff() {
        for enabled in [true, false] {
            let result = TrueToneReadPolicy.resolve(supportedBefore: true, availableBefore: true,
                                                  firstEnabled: enabled, secondEnabled: enabled,
                                                  supportedAfter: true, availableAfter: true)
            XCTAssertEqual(result, known(enabled))
        }
    }

    func testReadPolicyRejectsMissingOrChangingValues() {
        for values: (Bool?, Bool?) in [(nil, nil), (nil, false), (true, nil), (false, true), (true, false)] {
            let result = TrueToneReadPolicy.resolve(supportedBefore: true, availableBefore: true,
                                                  firstEnabled: values.0, secondEnabled: values.1,
                                                  supportedAfter: true, availableAfter: true)
            XCTAssertEqual(result, unavailable)
        }
    }

    func testNegativeCapabilitiesDoNotClaimUnsupportedHardware() {
        XCTAssertNil(TrueToneAvailability.unknown.supported)
        XCTAssertNil(TrueToneAvailability.unsupportedABI.supported)
        XCTAssertNil(TrueToneAvailability.temporarilyUnavailable.supported)
        XCTAssertEqual(TrueToneAvailability.available.supported, true)
    }

    func testRefreshHasNoWriteOrWait() {
        for enabled in [true, false] {
            let result = TrueToneTransaction.execute(.refresh, read: { self.known(enabled) }, write: { _ in
                XCTFail("Refresh must not change True Tone"); return false
            }, wait: { XCTFail("Refresh should not perform write settling") })
            XCTAssertEqual(result.enabled, enabled)
            XCTAssertNil(result.failure)
        }
    }

    func testUnknownUnavailableOrIncompatibleReadCannotWrite() {
        for availability: TrueToneAvailability in [.unknown, .temporarilyUnavailable, .unsupportedABI] {
            let result = TrueToneTransaction.execute(.toggle(expectedEnabled: false), read: {
                .init(enabled: false, availability: availability)
            }, write: { _ in XCTFail("An unconfirmed state cannot be toggled"); return true })
            XCTAssertNil(result.enabled)
            XCTAssertEqual(result.failure, availability == .unsupportedABI ? .unsupportedABI : .readFailed)
        }
    }

    func testMalformedAvailableWithoutValueBecomesUnavailable() {
        let result = TrueToneTransaction.execute(.toggle(expectedEnabled: false), read: {
            .init(enabled: nil, availability: .available)
        }, write: { _ in XCTFail("No value must not imply disabled"); return true })
        XCTAssertNil(result.enabled)
        XCTAssertEqual(result.availability, .temporarilyUnavailable)
        XCTAssertEqual(result.failure, .readFailed)
    }

    func testExternalChangeBetweenDisplayAndClickPreventsWrite() {
        let result = TrueToneTransaction.execute(.toggle(expectedEnabled: false), read: { self.known(true) }, write: { _ in
            XCTFail("Do not overwrite a state the user has not seen"); return true
        })
        XCTAssertEqual(result.enabled, true)
        XCTAssertEqual(result.failure, .changedBeforeWrite)
    }

    func testBothToggleDirectionsWriteOnceAndRequireConfirmedRead() {
        for initial in [true, false] {
            var reads = 0
            var written: [Bool] = []
            let result = TrueToneTransaction.execute(.toggle(expectedEnabled: initial), read: {
                reads += 1
                return self.known(reads == 1 ? initial : !initial)
            }, write: { written.append($0); return true })
            XCTAssertEqual(result.enabled, !initial)
            XCTAssertNil(result.failure)
            XCTAssertEqual(written, [!initial])
            XCTAssertEqual(reads, 2)
        }
    }

    func testSetterRejectionNeverBecomesSuccessFromCoincidentalRead() {
        var reads = 0
        var writes = 0
        let result = TrueToneTransaction.execute(.toggle(expectedEnabled: false), read: {
            reads += 1
            return self.known(reads > 1)
        }, write: { _ in writes += 1; return false })
        XCTAssertEqual(result.enabled, true)
        XCTAssertEqual(result.failure, .writeFailed)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reads, 2)
    }

    func testSetterRejectionAndUnknownStateClearsOldValue() {
        var reads = 0
        let result = TrueToneTransaction.execute(.toggle(expectedEnabled: true), read: {
            reads += 1
            return reads == 1 ? self.known(true) : self.unavailable
        }, write: { _ in false })
        XCTAssertNil(result.enabled)
        XCTAssertEqual(result.availability, .temporarilyUnavailable)
        XCTAssertEqual(result.failure, .writeFailed)
    }

    func testDelayedConfirmationUsesBoundedReadbacksWithoutRetryingWrite() {
        var reads = 0
        var writes = 0
        var waits = 0
        let result = TrueToneTransaction.execute(.toggle(expectedEnabled: false), read: {
            reads += 1
            if reads == 2 { return self.unavailable }
            return self.known(reads > 3)
        }, write: { _ in writes += 1; return true }, wait: { waits += 1 })
        XCTAssertEqual(result.enabled, true)
        XCTAssertNil(result.failure)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(waits, 2)
    }

    func testKnownWrongReadbackIsUnconfirmedWithFiniteWaits() {
        var reads = 0
        var waits = 0
        var writes = 0
        let result = TrueToneTransaction.execute(.toggle(expectedEnabled: false), read: {
            reads += 1; return self.known(false)
        }, write: { _ in writes += 1; return true }, wait: { waits += 1 })
        XCTAssertEqual(result.enabled, false)
        XCTAssertEqual(result.failure, .unconfirmed)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reads, 1 + TrueToneTransaction.readbackAttempts)
        XCTAssertEqual(waits, TrueToneTransaction.readbackAttempts - 1)
        XCTAssertLessThanOrEqual(Double(waits) * TrueToneTransaction.readbackInterval, 0.75)
    }

    func testUnknownReadbackNeverPublishesRequestedOrPreviousState() {
        var reads = 0
        let result = TrueToneTransaction.execute(.toggle(expectedEnabled: true), read: {
            reads += 1
            return reads == 1 ? self.known(true) : self.unavailable
        }, write: { _ in true })
        XCTAssertNil(result.enabled)
        XCTAssertEqual(result.failure, .readbackUnavailable)
        XCTAssertEqual(reads, 1 + TrueToneTransaction.readbackAttempts)
    }

    func testLostABIDuringReadbackDoesNotPollAgain() {
        var reads = 0
        let result = TrueToneTransaction.execute(.toggle(expectedEnabled: false), read: {
            reads += 1
            return reads == 1 ? self.known(false) : .init(enabled: nil, availability: .unsupportedABI)
        }, write: { _ in true }, wait: { XCTFail("No waiting on unsupported ABI") })
        XCTAssertNil(result.enabled)
        XCTAssertEqual(result.failure, .readbackUnavailable)
        XCTAssertEqual(reads, 2)
    }

    func testDuplicateClicksAndStaleCompletionsAreRejected() throws {
        var state = TrueTonePresentationState()
        let first = try XCTUnwrap(state.begin())
        XCTAssertNil(state.begin())
        XCTAssertTrue(state.receive(.init(enabled: false, availability: .available, failure: nil), generation: first))
        let second = try XCTUnwrap(state.begin())
        XCTAssertFalse(state.receive(.init(enabled: true, availability: .available, failure: nil), generation: first))
        XCTAssertTrue(state.isBusy)
        XCTAssertEqual(state.enabled, false)
        XCTAssertTrue(state.receive(.init(enabled: true, availability: .available, failure: nil), generation: second))
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.enabled, true)
    }

    func testFailureCannotLeakAnUnavailableValueAndRetryClearsError() throws {
        var state = TrueTonePresentationState()
        let generation = try XCTUnwrap(state.begin())
        state.receive(.init(enabled: false, availability: .temporarilyUnavailable, failure: .readFailed), generation: generation)
        XCTAssertNil(state.enabled)
        XCTAssertEqual(state.failure, .readFailed)
        XCTAssertNotNil(state.begin())
        XCTAssertNil(state.failure)
    }

    func testVerifiedABIIsAcceptedAndAnyMissingOrAlteredMethodRejected() {
        let values = ["@16@0:8", "B16@0:8", "B16@0:8", "B16@0:8", "B20@0:8B16"]
        XCTAssertTrue(TrueToneRuntimeABI.accepts(factory: values[0], supported: values[1], available: values[2], enabled: values[3], setter: values[4]))
        for index in values.indices {
            for replacement: String? in [nil, "", "c16@0:8", "v20@0:8B16"] {
                var candidate = values.map(Optional.some)
                candidate[index] = replacement
                XCTAssertFalse(TrueToneRuntimeABI.accepts(factory: candidate[0], supported: candidate[1], available: candidate[2], enabled: candidate[3], setter: candidate[4]))
            }
        }
    }
}
