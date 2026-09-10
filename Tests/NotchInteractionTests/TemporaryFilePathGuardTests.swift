// Custom changes for 工位充电岛: containment check in front of a destructive delete.
import XCTest
@testable import NotchInteractionCore

final class TemporaryFilePathGuardTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/var/folders/sl/abc/T")

    private func isInside(_ path: String, root: URL? = nil) -> Bool {
        TemporaryFilePathGuard.isInsideTemporaryDirectory(URL(fileURLWithPath: path),
                                                          temporaryRoot: root ?? self.root)
    }

    // MARK: - The mismatch that made cleanup a no-op

    func testCanonicalPrivatePathCountsAsInsideTheVarStyleRoot() {
        // A resolved bookmark reports /private/var…; NSTemporaryDirectory() reports /var….
        // Treating those as different locations is what stopped every temp file being freed.
        XCTAssertTrue(isInside("/private/var/folders/sl/abc/T/NotchIsland-Captures/x/a.png"))
    }

    func testVarStylePathCountsAgainstAPrivateStyleRoot() {
        XCTAssertTrue(TemporaryFilePathGuard.isInsideTemporaryDirectory(
            URL(fileURLWithPath: "/var/folders/sl/abc/T/cap/a.png"),
            temporaryRoot: URL(fileURLWithPath: "/private/var/folders/sl/abc/T")))
    }

    func testPlainChildIsInside() {
        XCTAssertTrue(isInside("/var/folders/sl/abc/T/a.png"))
    }

    func testDeeplyNestedChildIsInside() {
        XCTAssertTrue(isInside("/var/folders/sl/abc/T/one/two/three/a.png"))
    }

    // MARK: - Things that must never be deleted

    func testPathOutsideTheRootIsRejected() {
        XCTAssertFalse(isInside("/Users/someone/Documents/thesis.pdf"))
    }

    func testSiblingWithSharedPrefixIsRejected() {
        // Without a separator in the comparison, "…/TEvil" would pass as a child of "…/T".
        XCTAssertFalse(isInside("/var/folders/sl/abc/TEvil/a.png"))
    }

    func testTheRootItselfIsRejected() {
        XCTAssertFalse(isInside("/var/folders/sl/abc/T"))
        XCTAssertFalse(isInside("/private/var/folders/sl/abc/T"))
    }

    func testParentOfTheRootIsRejected() {
        XCTAssertFalse(isInside("/var/folders/sl/abc"))
    }

    func testTraversalOutOfTheRootIsRejected() {
        XCTAssertFalse(isInside("/var/folders/sl/abc/T/../../../../etc/passwd"))
    }

    func testTrailingSlashOnTheRootIsHandled() {
        XCTAssertTrue(TemporaryFilePathGuard.isInsideTemporaryDirectory(
            URL(fileURLWithPath: "/var/folders/sl/abc/T/a.png"),
            temporaryRoot: URL(fileURLWithPath: "/var/folders/sl/abc/T/")))
    }
}
