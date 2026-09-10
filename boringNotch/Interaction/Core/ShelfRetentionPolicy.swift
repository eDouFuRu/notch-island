// Custom changes for 工位充电岛: shelf items expire on their own clock.
import Foundation

/// How long a staged item stays on the shelf before it is cleared automatically.
///
/// Each item ages from the moment it was staged, not from when the sweep runs, so a file
/// added minutes before a sweep still gets its full lifetime.
public enum ShelfRetentionPolicy: String, CaseIterable, Sendable {
    case off
    case hours12
    case day1
    case day3
    case week1

    /// `nil` means "never expires", which is deliberately distinct from a lifetime of zero.
    public var lifetime: TimeInterval? {
        switch self {
        case .off: return nil
        case .hours12: return 12 * 3600
        case .day1: return 24 * 3600
        case .day3: return 3 * 24 * 3600
        case .week1: return 7 * 24 * 3600
        }
    }

    /// Items persisted before this feature existed carry no timestamp. They are treated as
    /// fresh rather than expired: the alternative would wipe someone's shelf on first launch
    /// after updating, which is exactly the kind of silent data loss this policy exists to
    /// bound. The store backfills the missing timestamp so this only applies once.
    public static func isExpired(addedAt: Date?, now: Date, policy: ShelfRetentionPolicy) -> Bool {
        guard let lifetime = policy.lifetime, let addedAt else { return false }
        return now.timeIntervalSince(addedAt) >= lifetime
    }
}
