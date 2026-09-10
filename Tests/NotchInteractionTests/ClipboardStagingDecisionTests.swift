import XCTest
@testable import NotchInteractionCore

/// Copying a `.md` or a `.swift` in Finder used to reach the shelf as `Clipboard-<date>.png`:
/// Finder also puts the document's *icon* on the pasteboard, and the import asked for an
/// image before it asked for a file. These pin the ordering that fixes it.
final class ClipboardStagingDecisionTests: XCTestCase {
    func testADeclaredFileWinsOverTheIconBitmapThatComesWithIt() {
        XCTAssertEqual(ClipboardStagingDecision.decide(hasFileURLs: true, hasBitmap: true), .files)
    }

    func testAFileWithNoBitmapIsStillStagedAsAFile() {
        XCTAssertEqual(ClipboardStagingDecision.decide(hasFileURLs: true, hasBitmap: false), .files)
    }

    func testABareBitmapIsTheOnlyCaseThatBecomesAnImage() {
        XCTAssertEqual(ClipboardStagingDecision.decide(hasFileURLs: false, hasBitmap: true), .bitmap)
    }

    func testAnEmptyClipboardStagesNothing() {
        XCTAssertEqual(ClipboardStagingDecision.decide(hasFileURLs: false, hasBitmap: false), .nothing)
    }

    func testTheBackgroundWatcherIgnoresAnythingCarryingFiles() {
        // The regression itself: the watcher saw the icon bitmap of a copied document and
        // staged a PNG of it without the user asking for anything.
        XCTAssertFalse(ClipboardStagingDecision.watcherImportsBitmap(hasFileURLs: true, hasBitmap: true))
    }

    func testTheBackgroundWatcherStillTakesAScreenshot() {
        XCTAssertTrue(ClipboardStagingDecision.watcherImportsBitmap(hasFileURLs: false, hasBitmap: true))
    }

    func testAStagedFileKeepsItsOwnNameAndExtension() {
        XCTAssertEqual(
            ClipboardStagingDecision.stagedFileName(source: "notes.md", fallback: "Clipboard-x"),
            "notes.md")
        XCTAssertEqual(
            ClipboardStagingDecision.stagedFileName(source: "ContentView.swift", fallback: "Clipboard-x"),
            "ContentView.swift")
    }

    func testANamelessSourceFallsBackRatherThanProducingAnEmptyPath() {
        XCTAssertEqual(
            ClipboardStagingDecision.stagedFileName(source: "", fallback: "Clipboard-x"),
            "Clipboard-x")
    }
}
