import XCTest
@testable import NotchInteractionCore

final class NotificationStructureDiagnosticsTests: XCTestCase {
    func testOnlyAttributePresenceIsReportedAndUnknownNamesCannotLeakIdentifiers() {
        var report = NotificationStructureDiagnostics()
        report.recordNode(role: "AXStaticText", subrole: nil,
                          attributeNames: ["AXIdentifier", "AXValue", "AXAttributedDescription", "private-message-123", "AXIdentifier_secretTask"])
        XCTAssertEqual(report.identifierAttributeNodes, 1)
        XCTAssertEqual(report.attributes["AXValue"], 1)
        XCTAssertEqual(report.otherAttributeCount, 2)
        XCTAssertFalse(report.summary.contains("private-message-123"))
        XCTAssertFalse(report.summary.contains("secretTask"))
        XCTAssertTrue(report.summary.contains("values not read"))
    }

    func testRolesSizesAndErrorsAreBoundedAndDoNotAcceptFreeformText() {
        var report = NotificationStructureDiagnostics()
        report.recordNode(role: "A private notification title", subrole: "sender, message", attributeNames: [])
        XCTAssertTrue(report.roles.isEmpty)
        XCTAssertTrue(report.subroles.isEmpty)
        for index in 0..<50 {
            report.recordNode(role: "AXRole\(index)", subrole: "AXNotificationCenterBanner", attributeNames: [])
            report.recordWindowSize(width: 380, height: 90)
        }
        report.recordWindowSize(width: .infinity, height: 90)
        report.recordError(0)
        report.recordError(-25202)
        XCTAssertEqual(report.roles.count, 24)
        XCTAssertEqual(report.sizes.count, 16)
        XCTAssertEqual(report.errors, [-25202: 1])
        XCTAssertFalse(report.summary.contains("private notification"))
    }

    func testBannerGeometrySeparatesFullScreenHostFromCardAndOnlyEmitsPresenceBits() {
        var report = NotificationStructureDiagnostics()
        let window = NotificationStructureDiagnostics.BannerNode(number: 0, parent: nil, depth: 0,
            role: "AXWindow", subrole: "AXSystemDialog", width: 1512, height: 982, onScreen: true,
            attributeNames: ["AXTitle", "AXPosition", "AXSize"])
        let card = NotificationStructureDiagnostics.BannerNode(number: 4, parent: 3, depth: 4,
            role: "AXGroup", subrole: "AXNotificationCenterBanner", width: 344, height: 92, onScreen: true,
            attributeNames: ["AXAttributedDescription", "AXIdentifier", "AXSize", "AXPosition", "private-identifier-value"])
        report.recordBannerWindow(number: 0, window: window, focused: false, bannerCount: 1, stackCount: 0, cards: [card])
        let summary = report.summary
        XCTAssertTrue(summary.contains("AXSystemDialog size=1512x982"))
        XCTAssertTrue(summary.contains("node=4 parent=3 depth=4"))
        XCTAssertTrue(summary.contains("AXNotificationCenterBanner size=344x92"))
        XCTAssertTrue(summary.contains("focusedWindow=false banners=1 stacks=0"))
        XCTAssertTrue(summary.contains("AXAttributedDescription=1"))
        XCTAssertFalse(summary.contains("private-identifier-value"))
    }

    func testBannerGeometryRecordsHaveAnOverallLimitAndUnknownMeasurementsStayUnknown() {
        var report = NotificationStructureDiagnostics()
        let node = NotificationStructureDiagnostics.BannerNode(number: 1, parent: 0, depth: 1,
            role: "AXGroup", subrole: "AXNotificationCenterBanner", width: .infinity, height: 92,
            onScreen: nil, attributeNames: [])
        for index in 0..<40 {
            report.recordBannerWindow(number: index, window: node, focused: nil,
                                      bannerCount: 8, stackCount: 0, cards: Array(repeating: node, count: 8))
        }
        XCTAssertTrue(report.truncated)
        XCTAssertLessThanOrEqual(report.bannerWindows.count, 16)
        XCTAssertLessThanOrEqual(report.bannerWindows.joined().count, 8_000)
        XCTAssertTrue(report.summary.contains("size=unknown onScreen=unknown"))
        XCTAssertTrue(report.summary.contains("focusedWindow=unknown"))
    }
}
