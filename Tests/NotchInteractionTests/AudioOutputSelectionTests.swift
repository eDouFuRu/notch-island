import XCTest
@testable import NotchInteractionCore

final class AudioOutputSelectionTests: XCTestCase {
    private func record(_ id: UInt32, uid: String? = nil, name: String = "Output", channels: Int = 2,
                        alive: Bool = true, eligible: Bool = true) -> AudioOutputDeviceRecord {
        .init(objectID: id, uid: uid ?? "uid-\(id)", displayName: name, outputChannels: channels,
              isAlive: alive, canBeDefault: eligible)
    }
    func testAvailableOutputFilteringDoesNotIncludeInputsDeadOrIneligibleDevices() {
        let reading = AudioOutputReading(records: [record(1), record(2, channels: 0), record(3, alive: false),
            record(4, eligible: false), record(0), record(5, uid: "")], selectedObjectID: 1, defaultIsSettable: true)
        XCTAssertEqual(reading.devices.map(\.id), ["uid-1"])
        XCTAssertEqual(reading.selectedID, "uid-1")
        XCTAssertTrue(reading.canSelect)
    }
    func testStableUIDSurvivesObjectIDChangeAndRejectsReusedIDForAnotherDevice() {
        let old = AudioOutputReading(records: [record(7, uid: "speaker")], selectedObjectID: 7, defaultIsSettable: true)
        let reconnected = AudioOutputReading(records: [record(14, uid: "speaker"), record(7, uid: "new-device")],
                                             selectedObjectID: 7, defaultIsSettable: true)
        XCTAssertEqual(old.devices[0].id, "speaker")
        XCTAssertEqual(AudioOutputSelectionDecision.evaluate(id: "speaker", reading: reconnected), .select)
        let disconnected = AudioOutputReading(records: [record(7, uid: "new-device")], selectedObjectID: 7, defaultIsSettable: true)
        XCTAssertEqual(AudioOutputSelectionDecision.evaluate(id: "speaker", reading: disconnected), .unavailable)
    }
    func testSameNamesAreSeparateAndAmbiguousUIDsAreNotGuessed() {
        let reading = AudioOutputReading(records: [record(1), record(2), record(3, uid: "duplicate"), record(4, uid: "duplicate")],
                                         selectedObjectID: 1, defaultIsSettable: true)
        XCTAssertEqual(reading.devices.map(\.id), ["uid-1", "uid-2"])
        XCTAssertEqual(reading.devices[0].displayName, reading.devices[1].displayName)
        XCTAssertFalse(reading.contains("duplicate"))
    }
    func testReadOnlyCurrentAndUnknownStatesDoNotClaimSuccess() {
        let reading = AudioOutputReading(records: [record(1), record(2)], selectedObjectID: 1, defaultIsSettable: false)
        XCTAssertFalse(reading.canSelect)
        XCTAssertEqual(AudioOutputSelectionDecision.evaluate(id: "uid-1", reading: reading), .alreadySelected)
        XCTAssertEqual(AudioOutputSelectionDecision.evaluate(id: "uid-2", reading: reading), .readOnly)
        XCTAssertEqual(AudioOutputVerification.failure(requestedID: "uid-2", actual: reading), .notApplied)
        let unknown = AudioOutputReading(records: [record(1)], selectedObjectID: nil, defaultIsSettable: true)
        XCTAssertNil(unknown.selectedID)
        XCTAssertNil(unknown.currentName)
        XCTAssertEqual(AudioOutputVerification.failure(requestedID: "uid-1", actual: unknown), .unconfirmed)
        XCTAssertEqual(AudioOutputVerification.failure(requestedID: "uid-1", actual: nil), .unconfirmed)
    }
    func testCancelledQueuedRequestNeverBeginsAndLateResultCannotCompleteTwice() {
        let cancelled = AudioOutputRequestGate()
        XCTAssertTrue(cancelled.finish())
        XCTAssertFalse(cancelled.begin())
        XCTAssertFalse(cancelled.finish())
        let active = AudioOutputRequestGate()
        XCTAssertTrue(active.begin())
        XCTAssertFalse(active.begin())
        XCTAssertTrue(active.finish())
        XCTAssertFalse(active.finish())
    }
    func testConcurrentDeadlineAndResultHaveExactlyOneWinner() {
        let gate = AudioOutputRequestGate()
        let winners = NSLock()
        var count = 0
        XCTAssertTrue(gate.begin())
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if gate.finish() { winners.lock(); count += 1; winners.unlock() }
        }
        XCTAssertEqual(count, 1)
    }
    func testConfirmedSelectionRequiresActualUIDAndDisconnectedCurrentIsCleared() {
        let actual = AudioOutputReading(records: [record(8, uid: "chosen")], selectedObjectID: 8, defaultIsSettable: true)
        XCTAssertNil(AudioOutputVerification.failure(requestedID: "chosen", actual: actual))
        let gone = AudioOutputReading(records: [record(8, uid: "chosen", alive: false)], selectedObjectID: 8, defaultIsSettable: true)
        XCTAssertNil(gone.selectedID)
        XCTAssertTrue(gone.devices.isEmpty)
        XCTAssertFalse(gone.canSelect)
    }
}
