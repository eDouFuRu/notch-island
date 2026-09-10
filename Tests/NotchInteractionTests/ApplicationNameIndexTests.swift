import XCTest
@testable import NotchInteractionCore

final class ApplicationNameIndexTests: XCTestCase {
    private func entry(_ id: String, _ path: String, _ names: Set<String>, running: Bool = false)
        -> ApplicationNameIndex.Entry {
        .init(bundleID: id, bundlePath: path, displayNames: names, isRunning: running)
    }

    private let weChat = ApplicationNameIndex.Entry(bundleID: "com.tencent.xinWeChat",
                                                    bundlePath: "/Applications/WeChat.app",
                                                    displayNames: ["WeChat", "微信"], isRunning: true)
    private let weChatHelper = ApplicationNameIndex.Entry(
        bundleID: "com.tencent.flue.WeChatAppEx",
        bundlePath: "/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app",
        displayNames: ["微信"], isRunning: true)

    /// Strings measured from real macOS 15 banners.
    func testResolvesRealBannerDescriptions() {
        let index = ApplicationNameIndex(entries: [
            weChat,
            entry("com.electron.redcity", "/Applications/hi.app", ["REDcity", "hi"]),
            entry("com.apple.ScriptEditor2", "/System/Applications/Utilities/Script Editor.app",
                  ["Script Editor", "脚本编辑器"])
        ])
        let wechat = index.resolve(bannerDescription: "微信 张三, 你好啊")
        XCTAssertEqual(wechat?.bundleID, "com.tencent.xinWeChat")
        XCTAssertEqual(wechat?.displayName, "微信")
        XCTAssertEqual(wechat?.remainder, "张三, 你好啊")

        let hi = index.resolve(bannerDescription: "REDcity 李四, 开会了")
        XCTAssertEqual(hi?.bundleID, "com.electron.redcity")
        XCTAssertEqual(hi?.remainder, "李四, 开会了")

        let script = index.resolve(bannerDescription: "脚本编辑器 标题B, 副B, 正文B")
        XCTAssertEqual(script?.bundleID, "com.apple.ScriptEditor2")
        XCTAssertEqual(script?.remainder, "标题B, 副B, 正文B")
    }

    func testHelperInsideTheSameBundleDoesNotMakeTheNameAmbiguous() {
        let index = ApplicationNameIndex(entries: [weChatHelper, weChat])
        XCTAssertEqual(index.resolve(bannerDescription: "微信 张三, 你好")?.bundleID, "com.tencent.xinWeChat")
    }

    func testLongestInstalledNameWins() {
        let index = ApplicationNameIndex(entries: [
            weChat,
            entry("com.tencent.weread", "/Applications/WeRead.app", ["微信读书"])
        ])
        XCTAssertEqual(index.resolve(bannerDescription: "微信读书 每日一读, 正文")?.bundleID, "com.tencent.weread")
        XCTAssertEqual(index.resolve(bannerDescription: "微信 张三, 你好")?.bundleID, "com.tencent.xinWeChat")
    }

    func testRunningApplicationBreaksAnOtherwiseEqualTie() {
        let index = ApplicationNameIndex(entries: [
            entry("com.example.one", "/Applications/One.app", ["Duplicate"]),
            entry("com.example.two", "/Applications/Two.app", ["Duplicate"], running: true)
        ])
        XCTAssertEqual(index.resolve(bannerDescription: "Duplicate 标题, 正文")?.bundleID, "com.example.two")
    }

    func testUnbreakableTieRefusesToGuess() {
        let index = ApplicationNameIndex(entries: [
            entry("com.example.one", "/Applications/One.app", ["Duplicate"], running: true),
            entry("com.example.two", "/Applications/Two.app", ["Duplicate"], running: true)
        ])
        XCTAssertNil(index.resolve(bannerDescription: "Duplicate 标题, 正文"))
    }

    func testNamesContainingSpacesAndBodyOnlyBanners() {
        let index = ApplicationNameIndex(entries: [
            entry("com.google.Chrome", "/Applications/Google Chrome.app", ["Google Chrome"]),
            entry("com.google.Drive", "/Applications/Google Drive.app", ["Google Drive"])
        ])
        XCTAssertEqual(index.resolve(bannerDescription: "Google Chrome 下载完成")?.bundleID, "com.google.Chrome")
        XCTAssertEqual(index.resolve(bannerDescription: "Google Drive, 同步完成")?.remainder, "同步完成")
        XCTAssertNil(index.resolve(bannerDescription: "Google 下载完成"))
    }

    func testNoClaimAndDegenerateInput() {
        let index = ApplicationNameIndex(entries: [weChat])
        XCTAssertNil(index.resolve(bannerDescription: "a message mentioning 微信"))
        XCTAssertNil(index.resolve(bannerDescription: ""))
        XCTAssertNil(ApplicationNameIndex().resolve(bannerDescription: "微信 张三, 你好"))
    }

    func testNameOnlyBannerHasAnEmptyRemainder() {
        let index = ApplicationNameIndex(entries: [weChat])
        let resolution = index.resolve(bannerDescription: "  微信  ")
        XCTAssertEqual(resolution?.bundleID, "com.tencent.xinWeChat")
        XCTAssertEqual(resolution?.remainder, "")
    }
}

final class BannerNamePrefixTests: XCTestCase {
    func testBoundaryRules() {
        XCTAssertEqual(BannerNamePrefix.matchLength(of: "微信", in: "微信 张三, 你好"), 2)
        XCTAssertEqual(BannerNamePrefix.matchLength(of: "微信", in: "微信, 你好"), 2)
        XCTAssertEqual(BannerNamePrefix.matchLength(of: "wechat", in: "WeChat Zhang, hi"), 6)
        XCTAssertNil(BannerNamePrefix.matchLength(of: "微信", in: "微信读书 每日一读"))
        XCTAssertNil(BannerNamePrefix.matchLength(of: "", in: "微信 张三"))
        XCTAssertNil(BannerNamePrefix.matchLength(of: String(repeating: "a", count: 81),
                                                  in: String(repeating: "a", count: 90)))
    }

    func testRemainderStripsEveryLeadingSeparator() {
        XCTAssertEqual(BannerNamePrefix.remainder(of: "微信 张三, 你好", afterNameOfLength: 2), "张三, 你好")
        XCTAssertEqual(BannerNamePrefix.remainder(of: "微信,  你好", afterNameOfLength: 2), "你好")
        XCTAssertEqual(BannerNamePrefix.remainder(of: "微信", afterNameOfLength: 2), "")
        XCTAssertEqual(BannerNamePrefix.remainder(of: "微信", afterNameOfLength: 99), "")
    }
}
