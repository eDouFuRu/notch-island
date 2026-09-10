import XCTest
@testable import NotchInteractionCore

final class ClipboardImportGateTests: XCTestCase {
    func testUnchangedGenerationImportsNothing() {
        var gate = ClipboardImportGate(initialChangeCount: 7)
        XCTAssertFalse(gate.shouldImport(changeCount: 7, hasImage: true, enabled: true))
        XCTAssertFalse(gate.shouldImport(changeCount: 7, hasImage: true, enabled: true))
    }

    func testNewImageGenerationImportsOnceOnly() {
        var gate = ClipboardImportGate(initialChangeCount: 7)
        XCTAssertTrue(gate.shouldImport(changeCount: 8, hasImage: true, enabled: true))
        XCTAssertFalse(gate.shouldImport(changeCount: 8, hasImage: true, enabled: true),
                       "Polling again must not add a second copy")
    }

    func testNonImageGenerationIsSkipped() {
        var gate = ClipboardImportGate(initialChangeCount: 1)
        XCTAssertFalse(gate.shouldImport(changeCount: 2, hasImage: false, enabled: true))
    }

    /// A capture writes to the clipboard and is added to the shelf directly; importing the
    /// app's own write too would put the same screenshot on the shelf twice.
    func testOwnWriteIsNotImportedBack() {
        var gate = ClipboardImportGate(initialChangeCount: 1)
        gate.suppress(changeCount: 2)
        XCTAssertFalse(gate.shouldImport(changeCount: 2, hasImage: true, enabled: true))
    }

    func testSuppressionAppliesOnlyToThatGeneration() {
        var gate = ClipboardImportGate(initialChangeCount: 1)
        gate.suppress(changeCount: 2)
        XCTAssertFalse(gate.shouldImport(changeCount: 2, hasImage: true, enabled: true))
        XCTAssertTrue(gate.shouldImport(changeCount: 3, hasImage: true, enabled: true),
                      "A genuine copy right after our own write must still import")
    }

    /// If our write is never polled (watcher off, app busy), the next real copy must still
    /// be treated as new rather than mistaken for the suppressed one.
    func testUnpolledOwnWriteDoesNotSwallowTheNextCopy() {
        var gate = ClipboardImportGate(initialChangeCount: 1)
        gate.suppress(changeCount: 2)
        XCTAssertTrue(gate.shouldImport(changeCount: 3, hasImage: true, enabled: true))
    }

    /// Turning the feature on should not retroactively import whatever was copied while it
    /// was off — only what is copied from then on.
    func testDisabledWatcherStillConsumesGenerations() {
        var gate = ClipboardImportGate(initialChangeCount: 1)
        XCTAssertFalse(gate.shouldImport(changeCount: 2, hasImage: true, enabled: false))
        XCTAssertFalse(gate.shouldImport(changeCount: 2, hasImage: true, enabled: true),
                       "The generation copied while disabled is already consumed")
        XCTAssertTrue(gate.shouldImport(changeCount: 3, hasImage: true, enabled: true))
    }
}
