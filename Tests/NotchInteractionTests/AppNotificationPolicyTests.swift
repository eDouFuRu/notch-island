import XCTest
@testable import NotchInteractionCore

final class AppNotificationPolicyTests: XCTestCase {
    private let island = "com.dongfengrui.NotchIsland"

    func testUnconfiguredSourcesFollowTheDefault() {
        XCTAssertTrue(AppNotificationPolicy().allows("com.tencent.xinWeChat"))
        XCTAssertFalse(AppNotificationPolicy(allowsUnconfiguredSources: false).allows("com.tencent.xinWeChat"))
    }

    func testAnExplicitChoiceAlwaysWins() {
        let blocked = AppNotificationPolicy(overrides: ["com.apple.Music": false])
        XCTAssertFalse(blocked.allows("com.apple.Music"))
        XCTAssertTrue(blocked.allows("com.apple.Mail"))

        let allowed = AppNotificationPolicy(overrides: ["com.apple.Music": true], allowsUnconfiguredSources: false)
        XCTAssertTrue(allowed.allows("com.apple.Music"))
        XCTAssertFalse(allowed.allows("com.apple.Mail"))
    }

    func testTheNotchAppItselfIsExcludedUntilExplicitlyOptedIn() {
        let policy = AppNotificationPolicy(builtInExclusions: [island])
        XCTAssertFalse(policy.allows(island), "mirroring our own notifications back onto the notch")
        let optedIn = AppNotificationPolicy(overrides: [island: true], builtInExclusions: [island])
        XCTAssertTrue(optedIn.allows(island))
    }

    /// An unidentified sender must not be silently dropped; it rides on the default like any other.
    func testUnidentifiedSourceFollowsTheDefault() {
        XCTAssertTrue(AppNotificationPolicy(builtInExclusions: [island]).allows(""))
        XCTAssertFalse(AppNotificationPolicy(allowsUnconfiguredSources: false).allows(""))
    }

    func testAllowsAnySourceDecidesWhetherObservingIsWorthIt() {
        XCTAssertTrue(AppNotificationPolicy().allowsAnySource)
        XCTAssertFalse(AppNotificationPolicy(overrides: ["a": false], allowsUnconfiguredSources: false).allowsAnySource)
        XCTAssertTrue(AppNotificationPolicy(overrides: ["a": true], allowsUnconfiguredSources: false).allowsAnySource)
    }

    func testUnconfiguredReportsWhetherTheUserHasDecided() {
        let policy = AppNotificationPolicy(overrides: ["a": false])
        XCTAssertFalse(policy.isUnconfigured("a"))
        XCTAssertTrue(policy.isUnconfigured("b"))
    }
}

final class AppNotificationMigrationTests: XCTestCase {
    private let hi = "com.electron.redcity"

    func testLegacyHiValuesMoveIntoTheSharedDictionaries() {
        let outcome = AppNotificationMigration.migratingLegacyHi(
            bundleID: hi, legacyEnabled: true, legacyDetailed: false, enabled: [:], detailed: [:])
        XCTAssertEqual(outcome.enabled, [hi: true])
        XCTAssertEqual(outcome.detailed, [hi: false])
    }

    /// Re-running the migration must never overwrite a choice made after it.
    func testAnExistingSharedValueIsNeverOverwritten() {
        let outcome = AppNotificationMigration.migratingLegacyHi(
            bundleID: hi, legacyEnabled: true, legacyDetailed: true,
            enabled: [hi: false], detailed: [hi: false])
        XCTAssertEqual(outcome.enabled, [hi: false])
        XCTAssertEqual(outcome.detailed, [hi: false])
    }

    func testOtherSourcesAreLeftAlone() {
        let outcome = AppNotificationMigration.migratingLegacyHi(
            bundleID: hi, legacyEnabled: false, legacyDetailed: false,
            enabled: ["com.xingin.valos": true], detailed: [:])
        XCTAssertEqual(outcome.enabled, ["com.xingin.valos": true, hi: false])
        XCTAssertEqual(outcome.detailed, [hi: false])
    }

    func testAnEmptyBundleIDIsARefusalRatherThanABlankKey() {
        let outcome = AppNotificationMigration.migratingLegacyHi(
            bundleID: "", legacyEnabled: true, legacyDetailed: true, enabled: [:], detailed: [:])
        XCTAssertTrue(outcome.enabled.isEmpty)
        XCTAssertTrue(outcome.detailed.isEmpty)
    }
}

final class BannerCardSelectionTests: XCTestCase {
    func testTopmostCardIsTheOneWithTheSmallestY() {
        let positions: [CGPoint?] = [CGPoint(x: 1560, y: 130), CGPoint(x: 1560, y: 46), CGPoint(x: 1560, y: 220)]
        XCTAssertEqual(BannerCardSelection.topmostIndex(positions: positions), 1)
    }

    func testTiesFallBackToTheLeftmostCard() {
        let positions: [CGPoint?] = [CGPoint(x: 900, y: 46), CGPoint(x: 400, y: 46)]
        XCTAssertEqual(BannerCardSelection.topmostIndex(positions: positions), 1)
    }

    func testUnreadablePositionsAreSkippedButASoleCardIsKept() {
        XCTAssertEqual(BannerCardSelection.topmostIndex(positions: [nil, CGPoint(x: 0, y: 46)]), 1)
        XCTAssertEqual(BannerCardSelection.topmostIndex(positions: [nil]), 0)
        XCTAssertNil(BannerCardSelection.topmostIndex(positions: []))
        XCTAssertNil(BannerCardSelection.topmostIndex(positions: [nil, nil]))
    }

    func testNonFiniteCoordinatesAreRejected() {
        XCTAssertEqual(BannerCardSelection.topmostIndex(
            positions: [CGPoint(x: CGFloat.nan, y: CGFloat.nan), CGPoint(x: 10, y: 90)]), 1)
    }
}
