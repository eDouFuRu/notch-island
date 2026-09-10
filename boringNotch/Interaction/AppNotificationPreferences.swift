import AppKit
import Defaults

extension Defaults.Keys {
    /// Explicit per-application choices. Absence means "follow the default policy", which is why
    /// this stays a sparse dictionary instead of a materialised list of every installed app.
    static let enabledAppNotificationSources = Key<[String: Bool]>("enabledAppNotificationSources", default: [:])
    static let detailedAppNotificationSources = Key<[String: Bool]>("detailedAppNotificationSources", default: [:])
    static let appNotificationAllowsNewSources = Key<Bool>("appNotificationAllowsNewSources", default: true)
    static let appNotificationDetailsNewSources = Key<Bool>("appNotificationDetailsNewSources", default: true)
    /// bundleID -> display name for every application that has actually posted a banner here.
    /// Only these two fields; never any message content.
    static let seenAppNotificationSources = Key<[String: String]>("seenAppNotificationSources", default: [:])
    static let appNotificationLegacyHiMigrated = Key<Bool>("appNotificationLegacyHiMigrated", default: false)
}

/// A row in the settings list. Sources are discovered from what has actually notified this Mac,
/// not from a hard-coded allow list.
struct AppNotificationSourceInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let applicationURL: URL?
    var isInstalled: Bool { applicationURL != nil }
}

enum AppNotificationSourcePreferences {
    /// hi predates the shared dictionaries and owns three keys of its own. Move its values across
    /// exactly once; the old keys are deliberately left untouched so they remain a rollback record.
    @MainActor static func migrateLegacyHiKeysIfNeeded() {
        guard !Defaults[.appNotificationLegacyHiMigrated] else { return }
        let id = HiNotificationSourceEvidence.hiBundleID
        let outcome = AppNotificationMigration.migratingLegacyHi(
            bundleID: id,
            legacyEnabled: Defaults[.enableHiNotifications],
            legacyDetailed: Defaults[.hiNotificationDetail],
            enabled: Defaults[.enabledAppNotificationSources],
            detailed: Defaults[.detailedAppNotificationSources])
        Defaults[.enabledAppNotificationSources] = outcome.enabled
        Defaults[.detailedAppNotificationSources] = outcome.detailed
        Defaults[.appNotificationLegacyHiMigrated] = true
    }

    @MainActor static func enabledPolicy() -> AppNotificationPolicy {
        AppNotificationPolicy(overrides: Defaults[.enabledAppNotificationSources],
                              allowsUnconfiguredSources: Defaults[.appNotificationAllowsNewSources],
                              builtInExclusions: builtInExclusions)
    }

    @MainActor static func detailPolicy() -> AppNotificationPolicy {
        AppNotificationPolicy(overrides: Defaults[.detailedAppNotificationSources],
                              allowsUnconfiguredSources: Defaults[.appNotificationDetailsNewSources])
    }

    /// Only the notch app itself, so its own notifications are not mirrored back onto the notch.
    /// It still appears in the settings list and can be switched on deliberately.
    static let builtInExclusions: Set<String> = Set([Bundle.main.bundleIdentifier].compactMap { $0 })

    @MainActor static func remember(bundleID: String, displayName: String) {
        guard !bundleID.isEmpty, !displayName.isEmpty else { return }
        guard Defaults[.seenAppNotificationSources][bundleID] != displayName else { return }
        Defaults[.seenAppNotificationSources][bundleID] = displayName
    }
}
