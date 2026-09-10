import XCTest
@testable import NotchInteractionCore

final class HiNotificationStateTests: XCTestCase {
    private func candidate(_ id: String = "opaque-1", sender: String? = "A colleague", body: String? = "A test message") -> HiNotificationCandidate {
        HiNotificationCandidate(identity: id, sender: sender, body: body)
    }

    private func enabled(detailed: Bool = false) -> HiNotificationState {
        var state = HiNotificationState()
        state.setEnabled(true)
        state.setApplicationAvailable(true)
        state.setDetailed(detailed)
        return state
    }

    func testDefaultOffAndUnavailableEachRejectDelivery() {
        var state = HiNotificationState()
        XCTAssertFalse(state.receive(candidate(), now: 1))
        state.setApplicationAvailable(true)
        XCTAssertFalse(state.receive(candidate(), now: 2))
        state.setApplicationAvailable(false)
        state.setEnabled(true)
        XCTAssertFalse(state.receive(candidate(), now: 3))
        XCTAssertNil(state.current)
        XCTAssertEqual(state.recentIdentityCount, 0)
    }

    func testPrivacyModeNeverStoresSenderOrBody() throws {
        var state = enabled()
        XCTAssertTrue(state.receive(candidate(), now: 1))
        let notice = try XCTUnwrap(state.current)
        XCTAssertNil(notice.sender)
        XCTAssertNil(notice.body)
        XCTAssertEqual(notice.count, 1)
        XCTAssertEqual(notice.sourceBundleID, "com.electron.redcity")
    }

    func testSwitchingToPrivateErasesTextWithoutReplayingOrResurrectingIt() throws {
        var state = enabled(detailed: true)
        state.receive(candidate(), now: 4)
        let original = try XCTUnwrap(state.current)
        XCTAssertEqual(original.sender, "A colleague")
        state.setDetailed(false)
        XCTAssertNil(state.current?.sender)
        XCTAssertNil(state.current?.body)
        XCTAssertEqual(state.current?.id, original.id)
        XCTAssertEqual(state.current?.receivedAt, 4)
        state.setDetailed(true)
        XCTAssertNil(state.current?.body, "Opting in later must not resurrect previously discarded content")
        state.receive(candidate("opaque-2"), now: 5)
        XCTAssertEqual(state.current?.body, "A test message")
    }

    func testDuplicateAXCallbacksDoNotRecountOrExtendPresentation() throws {
        var state = enabled(detailed: true)
        state.receive(candidate(), now: 100)
        let original = try XCTUnwrap(state.current)
        for time in [100.01, 100.2, 105, 130] {
            XCTAssertFalse(state.receive(candidate(), now: time))
            XCTAssertEqual(state.current, original)
        }
    }

    func testAXCardHydrationUpdatesContentWithoutCountingOrExtending() {
        var state = enabled(detailed: true)
        state.receive(candidate("card", sender: nil, body: nil), now: 10)
        state.refreshCurrentContent(candidate("card", sender: "Sender", body: "Loaded text"))
        XCTAssertEqual(state.current?.body, "Loaded text")
        XCTAssertEqual(state.current?.count, 1)
        XCTAssertEqual(state.current?.receivedAt, 10)
        XCTAssertEqual(state.current?.id, "card")
        state.setDetailed(false)
        state.refreshCurrentContent(candidate("card", body: "Must stay private"))
        XCTAssertNil(state.current?.body)
        state.dismiss()
        state.refreshCurrentContent(candidate("card"))
        XCTAssertNil(state.current)
    }

    func testBurstKeepsLatestMessageAndNewIdentityWithBoundedWindow() {
        var state = enabled(detailed: true)
        state.receive(candidate("first", body: "First"), now: 10)
        state.receive(candidate("second", body: "Latest"), now: 14.9)
        XCTAssertEqual(state.current?.id, "second")
        XCTAssertEqual(state.current?.count, 2)
        XCTAssertEqual(state.current?.body, "Latest")
        XCTAssertEqual(state.current?.receivedAt, 14.9)
        state.receive(candidate("third"), now: 20)
        XCTAssertEqual(state.current?.count, 1)
    }

    func testDismissalKeepsDedupButStartsNextRealNoticeAtOne() {
        var state = enabled()
        state.receive(candidate("first"), now: 1)
        state.dismiss()
        XCTAssertNil(state.current)
        XCTAssertFalse(state.receive(candidate("first"), now: 2))
        XCTAssertTrue(state.receive(candidate("second"), now: 3))
        XCTAssertEqual(state.current?.count, 1)
    }

    func testHiddenDropsLateCallbacksAndRestoringDoesNotReplay() {
        var state = enabled(detailed: true)
        state.receive(candidate(), now: 2)
        state.setApplicationAvailable(false)
        XCTAssertNil(state.current)
        XCTAssertFalse(state.receive(candidate("while-hidden"), now: 3))
        state.setApplicationAvailable(true)
        XCTAssertNil(state.current)
        XCTAssertFalse(state.receive(candidate(), now: 4))
        XCTAssertTrue(state.receive(candidate("new"), now: 5))
        XCTAssertEqual(state.current?.count, 1)
    }

    func testDisableClearsAllEphemeralStateAndRejectsDelivery() {
        var state = enabled(detailed: true)
        state.receive(candidate(), now: 1)
        state.setEnabled(false)
        XCTAssertNil(state.current)
        XCTAssertEqual(state.recentIdentityCount, 0)
        XCTAssertFalse(state.receive(candidate(), now: 2))
    }

    func testDedupMemoryIsBoundedAndExpires() {
        var state = enabled()
        for index in 0..<100 { state.receive(candidate("opaque-\(index)"), now: Double(index) / 100) }
        XCTAssertLessThanOrEqual(state.recentIdentityCount, HiNotificationState.maxRecentIdentities)
        state.receive(candidate("after-ttl"), now: 32)
        XCTAssertEqual(state.recentIdentityCount, 1)
    }

    func testInvalidTimesAndEmptyIdentityCannotCreateNotices() {
        var state = enabled()
        XCTAssertFalse(state.receive(candidate(""), now: 1))
        for now in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(state.receive(candidate(), now: now))
        }
        XCTAssertNil(state.current)
    }

    func testDetailedTextIsBoundedAndControlCharactersRemoved() {
        var state = enabled(detailed: true)
        state.receive(candidate(sender: String(repeating: "人", count: 150), body: "\u{0000}\n  A\t message  \n"), now: 1)
        XCTAssertEqual(state.current?.sender?.count, 80)
        XCTAssertEqual(state.current?.body, "A message")
        state.receive(candidate("second", body: String(repeating: "薯", count: 500)), now: 2)
        XCTAssertEqual(state.current?.body?.count, 240)
    }

    func testOnlyExactAttributedHiNamesOrBundleCanMatch() {
        let names: Set<String> = ["hi"]
        XCTAssertTrue(HiNotificationSourceEvidence(bannerDescriptions: [" Hi "]).isUnambiguouslyHi(knownDisplayNames: names))
        XCTAssertTrue(HiNotificationSourceEvidence(bannerDescriptions: ["hi 张三, 你好"]).isUnambiguouslyHi(knownDisplayNames: names))
        XCTAssertTrue(HiNotificationSourceEvidence(sourceBundleIDs: ["com.electron.redcity"]).isUnambiguouslyHi(knownDisplayNames: names))
        for description in ["Mail, hi, a message", "high 张三, 你好", "a message mentioning hi", ""] {
            XCTAssertFalse(HiNotificationSourceEvidence(bannerDescriptions: [description]).isUnambiguouslyHi(knownDisplayNames: names))
        }
        XCTAssertFalse(HiNotificationSourceEvidence().isUnambiguouslyHi(knownDisplayNames: names))
        XCTAssertFalse(HiNotificationSourceEvidence(bannerDescriptions: ["hi"]).isUnambiguouslyHi(knownDisplayNames: []))
    }

    func testMixedAttributionAndStacksAreRejectedEvenWithHiPresent() {
        let names: Set<String> = ["hi"]
        for evidence in [
            HiNotificationSourceEvidence(sourceBundleIDs: ["com.electron.redcity", "com.apple.mail"]),
            HiNotificationSourceEvidence(sourceBundleIDs: ["com.electron.redcity"], bannerDescriptions: ["Mail 提醒, 正文"]),
            HiNotificationSourceEvidence(bannerDescriptions: ["hi 张三, 你好", "Mail 提醒, 正文"]),
            HiNotificationSourceEvidence(bannerDescriptions: ["hi"], hasGroupedContent: true),
            HiNotificationSourceEvidence(bannerDescriptions: ["hi"], hasMultipleCards: true)
        ] {
            XCTAssertFalse(evidence.isUnambiguouslyHi(knownDisplayNames: names))
        }
    }

    /// Strings measured from real macOS 15 banners: the application name is separated from the
    /// title by a plain space (U+0020), and only the remaining fields are separated by ", ".
    func testAttributionMatchesRealBannerDescriptionPrefix() {
        let match = HiNotificationSourceEvidence.matchedDisplayName
        XCTAssertEqual(match("脚本编辑器 标题B, 副B, 正文B", ["Script Editor", "脚本编辑器"]), "脚本编辑器")
        XCTAssertEqual(match("微信 张三, 你好啊", ["WeChat", "微信"]), "微信")
        XCTAssertEqual(match("微信 你好啊", ["WeChat", "微信"]), "微信")
        XCTAssertEqual(match("微信, 你好啊", ["WeChat", "微信"]), "微信")
        XCTAssertEqual(match("WeChat  Zhang San, hello", ["WeChat", "微信"]), "wechat")
        XCTAssertEqual(match(" hi ", ["hi"]), "hi")
        // A longer installed name wins over one of its own shorter prefixes.
        XCTAssertEqual(match("微信读书 每日一读, 正文", ["微信读书", "微信"]), "微信读书")
        XCTAssertNil(match("微信读书 每日一读, 正文", ["微信"]))
        XCTAssertNil(match("Codex task finished, details", ["ChatGPT"]))
        XCTAssertNil(match("a message mentioning 微信", ["微信"]))
        XCTAssertNil(match("", ["微信"]))
        XCTAssertNil(match("微信 你好", []))
        XCTAssertNil(match("微信 你好", [" ", ""]))
    }

    func testNewAppSourcesRequireTheirOwnOptInAndDoNotInheritHiPrivacy() {
        var state = enabled(detailed: true)
        let valos = HiNotificationCandidate(identity: "v1", sender: "Task", body: "Ready to review",
                                            sourceBundleID: "com.xingin.valos")
        XCTAssertFalse(state.receive(valos, now: 1))
        state.configure(enabled: ["com.electron.redcity", "com.xingin.valos"], detailed: ["com.electron.redcity"])
        XCTAssertTrue(state.receive(valos, now: 2))
        XCTAssertEqual(state.current?.sourceBundleID, "com.xingin.valos")
        XCTAssertNil(state.current?.sender)
        XCTAssertNil(state.current?.body)
        XCTAssertTrue(state.receive(candidate("hi1"), now: 3))
        XCTAssertEqual(state.current?.body, "A test message")
        XCTAssertEqual(state.current?.count, 1, "Different applications must not be counted as a single burst")
    }

    func testDistinctApplicationsWithSameOpaqueIdentityDoNotDeduplicateEachOther() {
        var state = HiNotificationState()
        state.configure(enabled: ["com.coral.desktop", "com.openai.codex"], detailed: ["com.openai.codex"])
        state.setApplicationAvailable(true)
        let lobi = HiNotificationCandidate(identity: "card", sender: "Task", body: "Working",
                                           sourceBundleID: "com.coral.desktop")
        let codex = HiNotificationCandidate(identity: "card", sender: "Needs input", body: "Please choose an option",
                                            sourceBundleID: "com.openai.codex")
        XCTAssertTrue(state.receive(lobi, now: 1))
        XCTAssertTrue(state.receive(codex, now: 2))
        XCTAssertEqual(state.current?.sourceBundleID, "com.openai.codex")
        XCTAssertEqual(state.current?.sender, "Needs input", "An AI-app notification is not necessarily task completion")
        XCTAssertEqual(state.current?.count, 1)
        XCTAssertEqual(state.recentIdentityCount, 2)
        XCTAssertFalse(state.receive(codex, now: 3))
        XCTAssertFalse(state.receive(lobi, now: 4))
    }

    func testAppBurstKeepsLatestSourceAndDisablingThatSourceDismissesImmediately() {
        let id = "com.coral.desktop"
        var state = HiNotificationState()
        state.configure(enabled: [id, "com.openai.codex"], detailed: [id])
        state.setApplicationAvailable(true)
        for index in 1...3 {
            state.receive(HiNotificationCandidate(identity: "card-\(index)", sender: "Lobi task", body: "Update \(index)",
                                                   sourceBundleID: id), now: Double(index))
        }
        XCTAssertEqual(state.current?.count, 3)
        XCTAssertEqual(state.current?.body, "Update 3")
        state.configure(enabled: ["com.openai.codex"], detailed: [id])
        XCTAssertNil(state.current)
        XCTAssertTrue(state.isEnabled)
        XCTAssertFalse(state.receive(HiNotificationCandidate(identity: "late", sender: nil, body: "Late callback",
                                                             sourceBundleID: id), now: 4))
    }

    func testPerSourcePrivacyErasesOnlyCurrentMatchingSourceAndNeverRestoresOldPayload() {
        let id = "com.xingin.valos"
        var state = HiNotificationState()
        state.configure(enabled: [id, "com.electron.redcity"], detailed: [id])
        state.setApplicationAvailable(true)
        state.receive(HiNotificationCandidate(identity: "card", sender: "Task", body: "Private result", sourceBundleID: id), now: 4)
        state.configure(enabled: [id, "com.electron.redcity"], detailed: ["com.electron.redcity"])
        XCTAssertEqual(state.current?.sourceBundleID, id)
        XCTAssertNil(state.current?.body)
        state.configure(enabled: [id, "com.electron.redcity"], detailed: [id])
        XCTAssertNil(state.current?.body)
        state.refreshCurrentContent(candidate("card", body: "Wrong source must never hydrate the matching card ID"))
        XCTAssertNil(state.current?.body)
        state.setApplicationAvailable(false)
        XCTAssertNil(state.current)
    }

    func testSourceAttributionNeedsExactInstalledNamesAndRejectsMixedMetadata() {
        for (id, name) in [("com.xingin.valos", "ValOS"), ("com.coral.desktop", "Lobi"),
                           ("com.openai.codex", "ChatGPT"), ("com.tencent.xinWeChat", "微信")] {
            let banner = "\(name) 标题, 正文"
            XCTAssertTrue(HiNotificationSourceEvidence(bannerDescriptions: [banner]).isUnambiguouslySource(bundleID: id, knownDisplayNames: [name]))
            XCTAssertFalse(HiNotificationSourceEvidence(bannerDescriptions: [banner]).isUnambiguouslySource(bundleID: id, knownDisplayNames: []))
            XCTAssertFalse(HiNotificationSourceEvidence(bannerDescriptions: ["Other \(name), 正文"]).isUnambiguouslySource(bundleID: id, knownDisplayNames: [name]))
            XCTAssertFalse(HiNotificationSourceEvidence(sourceBundleIDs: ["com.apple.mail"], bannerDescriptions: [banner]).isUnambiguouslySource(bundleID: id, knownDisplayNames: [name]))
            XCTAssertFalse(HiNotificationSourceEvidence(bannerDescriptions: [banner], hasGroupedContent: true).isUnambiguouslySource(bundleID: id, knownDisplayNames: [name]))
        }
    }
}
