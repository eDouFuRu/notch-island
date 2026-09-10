import XCTest
@testable import NotchInteractionCore

final class InputSourceSelectionTests: XCTestCase {
    private func source(_ id: String, name: String? = nil, bundle: String? = nil,
                        kind: KeyboardInputSourceKind = .layout, enabled: Bool = true,
                        selectable: Bool = true) -> KeyboardInputSourceRecord {
        .init(id: id, displayName: name ?? id, bundleID: bundle, kind: kind, enabled: enabled, selectable: selectable)
    }

    func testOnlyEnabledSelectableKeyboardLeavesAppear() {
        let reading = InputSourceReading(records: [source("us"), source("disabled", enabled: false),
            source("unselectable", selectable: false), source("palette", kind: .other),
            source("parent", kind: .inputMethodParent, selectable: false), source(""), source("us")],
            selectedID: "us", currentName: "ABC")
        XCTAssertEqual(reading.sources.map(\.id), ["us"])
        XCTAssertEqual(reading.selectedID, "us")
        XCTAssertEqual(reading.currentName, "ABC")
    }

    func testInputModesUseUniqueSourceIDsAndRequireTheirEnabledParent() {
        let parent = source("com.test.ime", name: "Input Method", bundle: "com.test.ime",
                            kind: .inputMethodParent, selectable: false)
        let modes = [source("com.test.ime.modeA", name: "Mode A", bundle: "com.test.ime", kind: .inputMode),
                     source("com.test.ime.modeB", name: "Mode B", bundle: "com.test.ime", kind: .inputMode)]
        let reading = InputSourceReading(records: [parent] + modes, selectedID: modes[1].id, currentName: "Mode B")
        XCTAssertEqual(reading.sources.map(\.id), modes.map(\.id))
        XCTAssertEqual(reading.sources.first?.parentName, "Input Method")
        XCTAssertEqual(InputSourceSelectionDecision.evaluate(id: modes[1].id, reading: reading), .alreadySelected)
        XCTAssertEqual(InputSourceSelectionDecision.evaluate(id: parent.id, reading: reading), .unavailable)
        XCTAssertTrue(InputSourceReading(records: modes, selectedID: nil, currentName: nil).sources.isEmpty)
        let disabledParent = source("com.test.ime", bundle: "com.test.ime", kind: .inputMethodParent,
                                    enabled: false, selectable: false)
        XCTAssertTrue(InputSourceReading(records: [disabledParent] + modes, selectedID: nil, currentName: nil).sources.isEmpty)
    }

    func testAmbiguousMissingParentMetadataDoesNotGuessASelectionTarget() {
        let mode = source("a.b.mode", bundle: "a.b", kind: .inputMode)
        let parent1 = source("a.b", bundle: "a.b", kind: .inputMethodParent, selectable: false)
        let parent2 = source("different", bundle: "a.b", kind: .inputMethodParent, selectable: false)
        XCTAssertTrue(InputSourceReading(records: [parent1, parent2, mode], selectedID: nil, currentName: nil).sources.isEmpty)
        let missingBundle = source("a.b.mode", kind: .inputMode)
        XCTAssertTrue(InputSourceReading(records: [parent1, missingBundle], selectedID: nil, currentName: nil).sources.isEmpty)
    }

    func testSameLocalizedNamesDoNotMergeDistinctInputSources() {
        let reading = InputSourceReading(records: [source("first", name: "Same"), source("second", name: "Same")],
                                         selectedID: "first", currentName: "Same")
        XCTAssertEqual(reading.sources.count, 2)
        XCTAssertEqual(InputSourceSelectionDecision.evaluate(id: "second", reading: reading), .select)
        XCTAssertEqual(InputSourceSelectionDecision.evaluate(id: "removed", reading: reading), .unavailable)
    }

    func testSuccessfulStatusAloneCannotClaimSelectionAndActualSourceRemainsTruth() {
        let old = InputSourceReading(records: [source("old"), source("new")], selectedID: "old", currentName: "Old")
        let new = InputSourceReading(records: [source("old"), source("new")], selectedID: "new", currentName: "New")
        XCTAssertEqual(InputSourceSelectionVerification.failure(requestedID: "new", writeSucceeded: true, actual: old), .notApplied)
        XCTAssertEqual(InputSourceSelectionVerification.failure(requestedID: "new", writeSucceeded: true, actual: nil), .confirmationFailed)
        XCTAssertEqual(InputSourceSelectionVerification.failure(requestedID: "new", writeSucceeded: false, actual: new), .selectionFailed)
        XCTAssertNil(InputSourceSelectionVerification.failure(requestedID: "new", writeSucceeded: true, actual: new))
        XCTAssertEqual(old.selectedID, "old")
    }

    func testCurrentSourceCanRemainVisibleEvenWhenItCannotBeSelectedFromTheMenu() {
        let reading = InputSourceReading(records: [source("safe")], selectedID: "unavailable-current", currentName: "Current IME")
        XCTAssertEqual(reading.currentName, "Current IME")
        XCTAssertFalse(reading.containsSelectableSource("unavailable-current"))
        XCTAssertEqual(InputSourceSelectionDecision.evaluate(id: "safe", reading: reading), .select)
    }
}
