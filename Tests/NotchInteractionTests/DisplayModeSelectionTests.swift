import XCTest
@testable import NotchInteractionCore

final class DisplayModeSelectionTests: XCTestCase {
    private func mode(_ id: Int32, width: Int = 1000, pixels: Int = 2000,
                      rate: Double = 60, desktop: Bool = true) -> DisplayModeOption {
        .init(id: id, width: width, height: 700, pixelWidth: pixels, pixelHeight: pixels == width ? 700 : 1400,
              refreshRate: rate, usableForDesktop: desktop)
    }
    private func display(_ modes: [DisplayModeOption], current: Int32? = 1, id: String = "display-A") -> DisplayModeDisplay {
        .init(id: id, ordinal: 1, isBuiltIn: true, isMirrored: false, currentModeID: current, modes: modes)
    }
    private var old: DisplayModeOption { mode(1) }
    private var target: DisplayModeOption { mode(2, width: 1200, pixels: 2400) }
    private var request: DisplayModeRequest { .init(displayID: "display-A", mode: target) }

    func testFiltersNonDesktopAndMalformedModes() {
        let invalid = [mode(2, desktop: false), mode(3, width: 0), mode(4, pixels: 500),
                       mode(5, rate: -.infinity), mode(6, rate: .nan), mode(7, rate: -1)]
        XCTAssertEqual(DisplayModeMenu.options([old] + invalid, currentModeID: nil), [old])
    }
    func testExactlyEquivalentModesKeepCurrentRealID() {
        XCTAssertEqual(DisplayModeMenu.options([mode(7), mode(3), old], currentModeID: 7).map(\.id), [7])
        XCTAssertEqual(DisplayModeMenu.options([mode(7), mode(3), old], currentModeID: nil).map(\.id), [1])
    }
    func testConflictingReuseOfModeIDIsOmitted() {
        XCTAssertTrue(DisplayModeMenu.options([old, mode(1, rate: 120)], currentModeID: 1).isEmpty)
    }
    func testHiDPIAndDifferentRefreshRatesRemainDistinct() {
        let modes = [mode(1, pixels: 1000), mode(2), mode(3, rate: 120), mode(4, rate: 59.94), mode(5, rate: 0)]
        XCTAssertEqual(DisplayModeMenu.options(modes, currentModeID: 2).count, 5)
        XCTAssertFalse(modes[0].isHiDPI)
        XCTAssertTrue(modes[1].isHiDPI)
        XCTAssertNil(modes[4].refreshRateLabel)
        XCTAssertEqual(modes[1].resolutionLabel, "1000 × 700")
        XCTAssertEqual(modes[1].refreshRateLabel, "60 Hz")
    }
    func testSortIsDeterministicRegardlessOfDriverOrder() {
        let modes = [mode(4, width: 1600, pixels: 3200), mode(3, rate: 120), mode(2, pixels: 1000), old]
        XCTAssertEqual(DisplayModeMenu.options(modes, currentModeID: 1), DisplayModeMenu.options(modes.reversed(), currentModeID: 1))
    }
    func testStableUUIDCannotSelectReconnectedDifferentDisplay() {
        XCTAssertEqual(DisplayModeDecision.evaluate(request, displays: [display([old, target], id: "display-B")]), .fail(.displayMissing))
    }
    func testRemovedModeAndReusedIDAreDifferentFailures() {
        XCTAssertEqual(DisplayModeDecision.evaluate(request, displays: [display([old])]), .fail(.modeMissing))
        XCTAssertEqual(DisplayModeDecision.evaluate(request, displays: [display([old, mode(2, rate: 120)])]), .fail(.modeChanged))
    }
    func testCurrentModeMustBeReadableBeforeChange() {
        XCTAssertEqual(DisplayModeDecision.evaluate(request, displays: [display([old, target], current: nil)]), .fail(.currentUnreadable))
    }
    func testAlreadySelectedIsANoOpOnlyForMatchingMetadata() {
        XCTAssertEqual(DisplayModeDecision.evaluate(request, displays: [display([old, target], current: 2)]), .alreadySelected)
        XCTAssertEqual(DisplayModeDecision.evaluate(request, displays: [display([old, mode(2)], current: 2)]), .fail(.modeChanged))
    }
    func testRefreshOnlyReadsAndReportsNoDisplaysDistinctly() {
        let value = DisplayModeTransaction.execute(.refresh, read: { [] }, write: { _ in XCTFail("Unexpected write"); return nil })
        XCTAssertEqual(value, .init(displays: [], failure: .noDisplays))
        let failed = DisplayModeTransaction.execute(.refresh, read: { nil }, write: { _ in XCTFail("Unexpected write"); return nil })
        XCTAssertEqual(failed, .init(displays: nil, failure: .unavailable))
    }
    func testStaleDisplayCannotInvokeWriter() {
        let value = DisplayModeTransaction.execute(.select(request), read: { [self.display([self.old, self.target], id: "replacement")] },
                                                  write: { _ in XCTFail("Stale display write"); return nil })
        XCTAssertEqual(value.failure, .displayMissing)
    }
    func testAlreadySelectedNeverWrites() {
        let value = DisplayModeTransaction.execute(.select(request), read: { [self.display([self.old, self.target], current: 2)] },
                                                  write: { _ in XCTFail("Redundant write"); return nil })
        XCTAssertNil(value.failure)
    }
    func testSelectWritesExactlyOnceThenConfirmsActualMode() {
        var reads = 0, writes = 0, waits = 0
        let value = DisplayModeTransaction.execute(.select(request), read: {
            reads += 1
            return [self.display([self.old, self.target], current: reads >= 3 ? 2 : 1)]
        }, write: { received in
            writes += 1; XCTAssertEqual(received, self.request); return nil
        }, wait: { waits += 1 })
        XCTAssertNil(value.failure)
        XCTAssertEqual(value.displays?.first?.currentModeID, 2)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(waits, 1)
    }
    func testRejectedWriteIsNeverSuccessEvenIfAnotherActorChangesMode() {
        var reads = 0
        let value = DisplayModeTransaction.execute(.select(request), read: {
            reads += 1
            return [self.display([self.old, self.target], current: reads == 1 ? 1 : 2)]
        }, write: { _ in .writeFailed })
        XCTAssertEqual(value.failure, .writeFailed)
        XCTAssertEqual(value.displays?.first?.currentModeID, 2)
    }
    func testSuccessfulAPIReturnWithUnchangedModeRemainsUnconfirmed() {
        var reads = 0, writes = 0, waits = 0
        let value = DisplayModeTransaction.execute(.select(request), read: {
            reads += 1; return [self.display([self.old, self.target])]
        }, write: { _ in writes += 1; return nil }, wait: { waits += 1 })
        XCTAssertEqual(value.failure, .unconfirmed)
        XCTAssertEqual(value.displays?.first?.currentModeID, 1)
        XCTAssertEqual(reads, 9)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(waits, 7)
    }
    func testReadbackMustConfirmMetadataNotJustReusedModeID() {
        var reads = 0
        let value = DisplayModeTransaction.execute(.select(request), read: {
            reads += 1
            return [self.display([self.old, reads == 1 ? self.target : self.mode(2, rate: 120)], current: reads == 1 ? 1 : 2)]
        }, write: { _ in nil })
        XCTAssertEqual(value.failure, .unconfirmed)
    }
    func testReadbackFailureDiscardsStaleDisplayList() {
        var reads = 0
        let value = DisplayModeTransaction.execute(.select(request), read: {
            reads += 1; return reads == 1 ? [self.display([self.old, self.target])] : nil
        }, write: { _ in nil })
        XCTAssertEqual(value, .init(displays: nil, failure: .readbackUnavailable))
    }
    func testDisconnectedDisplayDuringReadbackCannotSucceed() {
        var reads = 0
        let value = DisplayModeTransaction.execute(.select(request), read: {
            reads += 1
            return reads == 1 ? [self.display([self.old, self.target])] : []
        }, write: { _ in nil })
        XCTAssertEqual(value, .init(displays: [], failure: .readbackUnavailable))
    }
    func testCancellationBeforeTransactionDoesNotReadOrWrite() {
        let value = DisplayModeTransaction.execute(.select(request), read: { XCTFail("Cancelled read"); return nil },
            write: { _ in XCTFail("Cancelled write"); return nil }, isCancelled: { true })
        XCTAssertEqual(value.failure, .cancelled)
    }
    func testCancellationBetweenReadAndWriteDoesNotWrite() {
        var cancelled = false
        let value = DisplayModeTransaction.execute(.select(request), read: {
            cancelled = true; return [self.display([self.old, self.target])]
        }, write: { _ in XCTFail("Cancelled write"); return nil }, isCancelled: { cancelled })
        XCTAssertEqual(value.failure, .cancelled)
    }
    func testCancellationAfterWriteDoesNotAutomaticallyRestoreMode() {
        var cancelled = false, writes = 0
        let value = DisplayModeTransaction.execute(.select(request), read: { [self.display([self.old, self.target])] },
            write: { _ in writes += 1; cancelled = true; return nil }, isCancelled: { cancelled })
        XCTAssertEqual(value.failure, .cancelled)
        XCTAssertNil(value.displays)
        XCTAssertEqual(writes, 1)
    }
}
