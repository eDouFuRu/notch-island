import XCTest
@testable import NotchInteractionCore

final class HiAXDiagnosticStructureTests: XCTestCase {
    func testAcceptsOnlyBoundedAXRoleNamesAndFixedSourceClassifications() {
        var structure = HiAXDiagnosticStructure()
        structure.record(role: "AXGroup", subrole: "AXNotificationCenterBanner")
        structure.record(role: "AXGroup", subrole: "AXNotificationCenterBanner")
        for invalid in ["A colleague", "body", "hi", "AX Message body", "AX\nPrivate", "AX发送者", "AX", String(repeating: "AX", count: 100)] {
            structure.record(role: invalid, subrole: invalid)
        }
        structure.recordSource(.hi); structure.recordSource(.other); structure.recordSource(.unparsed)
        XCTAssertEqual(structure.roles, ["AXGroup": 2])
        XCTAssertEqual(structure.subroles, ["AXNotificationCenterBanner": 2])
        XCTAssertEqual(structure.hi, 1)
        XCTAssertEqual(structure.other, 1)
        XCTAssertEqual(structure.unparsed, 1)
        XCTAssertFalse(structure.summary.contains("Private"))
        XCTAssertFalse(structure.summary.contains("colleague"))
    }

    func testRoleDictionariesHaveFixedCapacity() {
        var structure = HiAXDiagnosticStructure()
        for index in 0..<100 { structure.record(role: "AXRole\(index)", subrole: "AXSubrole\(index)") }
        XCTAssertEqual(structure.roles.count, HiAXDiagnosticStructure.nameLimit)
        XCTAssertEqual(structure.subroles.count, HiAXDiagnosticStructure.nameLimit)
    }
}
