import XCTest
@testable import NotchInteractionCore

final class AppNotificationNameFilterTests: XCTestCase {
    private typealias Filter = AppNotificationNameFilter
    private typealias App = AppNotificationNameFilter.RunningApplication

    private let weChatPath = "/Applications/WeChat.app"

    /// Measured on a real machine: WeChat.app ships a mini-program host inside its own bundle
    /// that runs under a different bundle ID but the very same localized name. Dropping "微信"
    /// because of it removes the only name real WeChat banners are attributed to.
    func testHelperInsideTheSourceBundleDoesNotDisqualifyItsName() {
        let helper = App(bundleID: "com.tencent.flue.WeChatAppEx",
                         bundlePath: "/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app",
                         localizedName: "微信")
        let itself = App(bundleID: "com.tencent.xinWeChat", bundlePath: weChatPath, localizedName: "微信")
        let names = Filter.attributableNames(candidates: ["WeChat", "微信"],
                                             sourceBundleID: "com.tencent.xinWeChat",
                                             sourceBundlePath: weChatPath,
                                             running: [itself, helper])
        XCTAssertEqual(names, ["WeChat", "微信"])
    }

    func testAnUnrelatedApplicationUnderTheSameNameStillDisqualifiesIt() {
        let impostor = App(bundleID: "com.example.fake", bundlePath: "/Applications/Fake.app", localizedName: "微信")
        let names = Filter.attributableNames(candidates: ["WeChat", "微信"],
                                             sourceBundleID: "com.tencent.xinWeChat",
                                             sourceBundlePath: weChatPath,
                                             running: [impostor])
        XCTAssertEqual(names, ["WeChat"])
    }

    func testSiblingPathsAreNotTreatedAsContained() {
        let sibling = App(bundleID: "com.example.other", bundlePath: "/Applications/WeChat.app.backup/Other.app",
                          localizedName: "微信")
        let names = Filter.attributableNames(candidates: ["微信"], sourceBundleID: "com.tencent.xinWeChat",
                                             sourceBundlePath: weChatPath, running: [sibling])
        XCTAssertTrue(names.isEmpty)
    }

    func testTrailingSlashesAndRelativeSegmentsDoNotChangeContainment() {
        let helper = App(bundleID: "com.tencent.flue.WeChatAppEx",
                         bundlePath: "/Applications/./WeChat.app/Contents/MacOS/WeChatAppEx.app/",
                         localizedName: "微信")
        let names = Filter.attributableNames(candidates: ["微信"], sourceBundleID: "com.tencent.xinWeChat",
                                             sourceBundlePath: "/Applications/WeChat.app/", running: [helper])
        XCTAssertEqual(names, ["微信"])
    }

    func testNotificationCentreAndUnknownBundlesAreHandled() {
        let centre = App(bundleID: AppNotificationNameFilter.notificationCenterBundleID,
                         bundlePath: "/System/Library/CoreServices/NotificationCenter.app", localizedName: "微信")
        XCTAssertEqual(Filter.attributableNames(candidates: ["微信"], sourceBundleID: "com.tencent.xinWeChat",
                                                sourceBundlePath: weChatPath, running: [centre]), ["微信"])
        let anonymous = App(bundleID: nil, bundlePath: nil, localizedName: "微信")
        XCTAssertEqual(Filter.attributableNames(candidates: ["微信"], sourceBundleID: "com.tencent.xinWeChat",
                                                sourceBundlePath: weChatPath, running: [anonymous]), ["微信"])
        // A rival we cannot locate on disk is assumed to be a separate application.
        let unlocatable = App(bundleID: "com.example.other", bundlePath: nil, localizedName: "微信")
        XCTAssertTrue(Filter.attributableNames(candidates: ["微信"], sourceBundleID: "com.tencent.xinWeChat",
                                               sourceBundlePath: weChatPath, running: [unlocatable]).isEmpty)
    }

    func testBlankCandidatesAreNeverAttributable() {
        XCTAssertTrue(Filter.attributableNames(candidates: ["", "   "], sourceBundleID: "com.tencent.xinWeChat",
                                               sourceBundlePath: weChatPath, running: []).isEmpty)
    }
}
