import XCTest
@testable import NotchInteractionCore

final class WifiPowerTests: XCTestCase {
    func testRefreshNeverWritesPower() {
        var writes = 0
        let result = WifiPowerTransaction.execute(.refresh, read: { .init(interfaceID: "en0", enabled: true) },
            write: { _, _ in writes += 1; return true })
        XCTAssertEqual(result, .init(enabled: true, failure: nil))
        XCTAssertEqual(writes, 0)
    }

    func testMissingHardwareCannotBeToggled() {
        var writes = 0
        let result = WifiPowerTransaction.execute(.toggle(expectedEnabled: false), read: { nil },
            write: { _, _ in writes += 1; return true })
        XCTAssertEqual(result, .init(enabled: nil, failure: .unavailable))
        XCTAssertEqual(writes, 0)
    }

    func testClickWithStaleDisplayedStateDoesNotReverseNewSystemState() {
        var writes = 0
        let result = WifiPowerTransaction.execute(.toggle(expectedEnabled: true),
            read: { .init(interfaceID: "en0", enabled: false) },
            write: { _, _ in writes += 1; return true })
        XCTAssertEqual(result, .init(enabled: false, failure: .changedBeforeWrite))
        XCTAssertEqual(writes, 0)
    }

    func testSuccessfulToggleReadsBackSameInterfaceAndActualValue() {
        var enabled = true
        var log: [String] = []
        let result = WifiPowerTransaction.execute(.toggle(expectedEnabled: true), read: {
            log.append("read")
            return .init(interfaceID: "en0", enabled: enabled)
        }, write: { value, id in
            log.append("write")
            XCTAssertEqual(id, "en0")
            enabled = value
            return true
        })
        XCTAssertEqual(log, ["read", "write", "read"])
        XCTAssertEqual(result, .init(enabled: false, failure: nil))
    }

    func testFailedWritePreservesActualReadbackAndDoesNotClaimTarget() {
        let result = WifiPowerTransaction.execute(.toggle(expectedEnabled: true),
            read: { .init(interfaceID: "en0", enabled: true) }, write: { _, _ in false })
        XCTAssertEqual(result, .init(enabled: true, failure: .writeFailed))
    }

    func testSuccessReturnWithoutHardwareChangeIsUnconfirmed() {
        let result = WifiPowerTransaction.execute(.toggle(expectedEnabled: true),
            read: { .init(interfaceID: "en0", enabled: true) }, write: { _, _ in true })
        XCTAssertEqual(result, .init(enabled: true, failure: .unconfirmed))
    }

    func testDisappearingAndReplacedInterfacesDoNotProduceFakeSuccess() {
        for replacement in [nil, WifiPowerReading(interfaceID: "en9", enabled: false)] {
            var first = true
            let result = WifiPowerTransaction.execute(.toggle(expectedEnabled: true), read: {
                if first { first = false; return .init(interfaceID: "en0", enabled: true) }
                return replacement
            }, write: { _, _ in true })
            XCTAssertEqual(result.failure, replacement == nil ? .readbackUnavailable : .interfaceChanged)
            XCTAssertEqual(result.enabled, replacement?.enabled)
        }
    }

    func testOlderAsyncReadCannotReplaceNewerBusyOrCompletedState() {
        var state = WifiPowerPresentationState()
        let old = state.begin()
        let new = state.begin()
        XCTAssertFalse(state.receive(.init(enabled: true, failure: nil), generation: old))
        XCTAssertNil(state.enabled)
        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.receive(.init(enabled: false, failure: nil), generation: new))
        XCTAssertEqual(state.enabled, false)
        XCTAssertFalse(state.isBusy)
        XCTAssertFalse(state.receive(.init(enabled: true, failure: .unavailable), generation: old))
        XCTAssertEqual(state.enabled, false)
        XCTAssertNil(state.failure)
    }
}
