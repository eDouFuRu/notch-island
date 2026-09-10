import Foundation

/// hi shipped before per-application notification preferences existed and kept its own two keys.
/// Once the whole feature became application-agnostic those keys had to fold into the shared
/// dictionaries, but the old ones must survive untouched so a downgrade still reads the user's
/// original choice.
public enum AppNotificationMigration {
    public struct Outcome: Equatable, Sendable {
        public let enabled: [String: Bool]
        public let detailed: [String: Bool]
    }

    /// An explicit value already present in the shared dictionary always wins: the user may have
    /// changed it after the migration flag was lost, and re-importing the legacy value would
    /// silently undo that.
    public static func migratingLegacyHi(bundleID: String, legacyEnabled: Bool, legacyDetailed: Bool,
                                         enabled: [String: Bool], detailed: [String: Bool]) -> Outcome {
        guard !bundleID.isEmpty else { return Outcome(enabled: enabled, detailed: detailed) }
        var mergedEnabled = enabled
        var mergedDetailed = detailed
        if mergedEnabled[bundleID] == nil { mergedEnabled[bundleID] = legacyEnabled }
        if mergedDetailed[bundleID] == nil { mergedDetailed[bundleID] = legacyDetailed }
        return Outcome(enabled: mergedEnabled, detailed: mergedDetailed)
    }
}
