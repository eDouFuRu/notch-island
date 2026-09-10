// Custom changes for 工位充电岛: shelf items expire on their own clock.
import XCTest
@testable import NotchInteractionCore

final class ShelfRetentionPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    // MARK: - Lifetimes

    func testOffHasNoLifetime() {
        XCTAssertNil(ShelfRetentionPolicy.off.lifetime)
    }

    func testLifetimesMatchTheirLabels() {
        XCTAssertEqual(ShelfRetentionPolicy.hours12.lifetime, 12 * 3600)
        XCTAssertEqual(ShelfRetentionPolicy.day1.lifetime, 86_400)
        XCTAssertEqual(ShelfRetentionPolicy.day3.lifetime, 3 * 86_400)
        XCTAssertEqual(ShelfRetentionPolicy.week1.lifetime, 7 * 86_400)
    }

    func testLifetimesAreStrictlyIncreasing() {
        let ordered: [ShelfRetentionPolicy] = [.hours12, .day1, .day3, .week1]
        let lifetimes = ordered.compactMap(\.lifetime)
        XCTAssertEqual(lifetimes.count, ordered.count)
        XCTAssertEqual(lifetimes, lifetimes.sorted())
        XCTAssertEqual(Set(lifetimes).count, lifetimes.count)
    }

    // MARK: - Expiry

    func testOffNeverExpiresHoweverOldTheItemIs() {
        XCTAssertFalse(ShelfRetentionPolicy.isExpired(addedAt: ago(10 * 365 * 86_400),
                                                      now: now, policy: .off))
    }

    func testFreshItemIsNotExpired() {
        XCTAssertFalse(ShelfRetentionPolicy.isExpired(addedAt: now, now: now, policy: .hours12))
    }

    func testItemJustShyOfItsLifetimeSurvives() {
        XCTAssertFalse(ShelfRetentionPolicy.isExpired(addedAt: ago(12 * 3600 - 1),
                                                      now: now, policy: .hours12))
    }

    func testItemExactlyAtItsLifetimeExpires() {
        XCTAssertTrue(ShelfRetentionPolicy.isExpired(addedAt: ago(12 * 3600),
                                                     now: now, policy: .hours12))
    }

    func testItemPastItsLifetimeExpires() {
        XCTAssertTrue(ShelfRetentionPolicy.isExpired(addedAt: ago(86_400 * 2),
                                                     now: now, policy: .day1))
    }

    func testEachItemAgesOnItsOwnClock() {
        // The whole point of storing a per-item timestamp: one sweep, different verdicts.
        let old = ago(4 * 86_400)
        let young = ago(3600)
        XCTAssertTrue(ShelfRetentionPolicy.isExpired(addedAt: old, now: now, policy: .day3))
        XCTAssertFalse(ShelfRetentionPolicy.isExpired(addedAt: young, now: now, policy: .day3))
    }

    // MARK: - Items persisted before the feature existed

    func testMissingTimestampIsTreatedAsFreshNotExpired() {
        // Treating nil as expired would wipe an existing shelf on the first launch after
        // updating, which is the exact failure this feature is supposed to bound.
        for policy in ShelfRetentionPolicy.allCases {
            XCTAssertFalse(ShelfRetentionPolicy.isExpired(addedAt: nil, now: now, policy: policy),
                           "nil timestamp must survive under \(policy.rawValue)")
        }
    }

    // MARK: - Clock going backwards

    func testItemStagedInTheFutureDoesNotExpire() {
        // A clock correction can leave a timestamp ahead of "now"; that must not delete data.
        XCTAssertFalse(ShelfRetentionPolicy.isExpired(addedAt: now.addingTimeInterval(3600),
                                                      now: now, policy: .hours12))
    }
}
