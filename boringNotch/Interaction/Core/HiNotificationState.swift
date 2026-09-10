import Foundation

/// Only the currently displayed notification may carry text. Nothing here is persisted.
public struct HiNotificationNotice: Equatable, Identifiable, Sendable {
    public let id: String
    public let sender: String?
    public let body: String?
    public let count: Int
    public let receivedAt: TimeInterval
    public let sourceBundleID: String
    /// The name the system itself signed the banner with. Kept on the notice because a banner
    /// whose application could not be identified still has to render something sensible.
    public var sourceName: String = ""
}

public struct HiNotificationCandidate: Equatable, Sendable {
    /// A process-local, opaque AX-card/content identity; never a raw message string.
    public let identity: String
    public let sender: String?
    public let body: String?
    public let sourceBundleID: String
    public let sourceName: String

    public init(identity: String, sender: String?, body: String?,
                sourceBundleID: String = HiNotificationSourceEvidence.hiBundleID,
                sourceName: String = "") {
        self.identity = identity
        self.sender = sender
        self.body = body
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
    }
}

/// Attribution must come from the system banner's metadata, never its message body.
public struct HiNotificationSourceEvidence: Equatable, Sendable {
    public static let hiBundleID = "com.electron.redcity"
    public var sourceBundleIDs: Set<String>
    /// The banner's whole AXAttributedDescription, not a pre-sliced application name.
    public var bannerDescriptions: Set<String>
    public var hasGroupedContent: Bool
    public var hasMultipleCards: Bool

    public init(sourceBundleIDs: Set<String> = [], bannerDescriptions: Set<String> = [],
                hasGroupedContent: Bool = false, hasMultipleCards: Bool = false) {
        self.sourceBundleIDs = sourceBundleIDs
        self.bannerDescriptions = bannerDescriptions
        self.hasGroupedContent = hasGroupedContent
        self.hasMultipleCards = hasMultipleCards
    }

    public func isUnambiguouslyHi(knownDisplayNames: Set<String>) -> Bool {
        isUnambiguouslySource(bundleID: Self.hiBundleID, knownDisplayNames: knownDisplayNames)
    }

    public func isUnambiguouslySource(bundleID: String, knownDisplayNames: Set<String>) -> Bool {
        guard !bundleID.isEmpty, !hasGroupedContent, !hasMultipleCards else { return false }
        guard sourceBundleIDs.isSubset(of: [bundleID]) else { return false }
        guard !bannerDescriptions.isEmpty else { return sourceBundleIDs == [bundleID] }
        return bannerDescriptions.allSatisfy { Self.matchedDisplayName(in: $0, candidates: knownDisplayNames) != nil }
    }

    /// Matches a known application name against the banner description prefix.
    /// The boundary rules live in `BannerNamePrefix` and are shared with `ApplicationNameIndex`.
    public static func matchedDisplayName(in description: String, candidates: Set<String>) -> String? {
        var best: String?
        var bestLength = 0
        var ambiguous = false
        for candidate in candidates {
            guard let length = BannerNamePrefix.matchLength(of: candidate, in: description) else { continue }
            let name = normalized(candidate)
            guard let current = best else { best = name; bestLength = length; continue }
            if length > bestLength { best = name; bestLength = length; ambiguous = false }
            else if length == bestLength, name != current { ambiguous = true }
        }
        return ambiguous ? nil : best
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Deterministic privacy/dedup reducer. Presentation duration and hover belong to the shell.
public struct HiNotificationState: Equatable, Sendable {
    public static let burstWindow: TimeInterval = 5
    public static let dedupLifetime: TimeInterval = 30
    public static let maxRecentIdentities = 64
    public private(set) var current: HiNotificationNotice?
    /// Sources are no longer an enumerable allow list: any application may post a banner, so the
    /// decision has to be a policy evaluated per bundle identifier instead of a set membership test.
    public private(set) var enabledPolicy = AppNotificationPolicy(allowsUnconfiguredSources: false)
    public private(set) var detailPolicy = AppNotificationPolicy(allowsUnconfiguredSources: false)
    public var isEnabled: Bool { enabledPolicy.allowsAnySource }
    public private(set) var applicationAvailable = false
    public var isDetailed: Bool { detailPolicy.allows(HiNotificationSourceEvidence.hiBundleID) }
    private var recentIdentities: [String: TimeInterval] = [:]
    public var recentIdentityCount: Int { recentIdentities.count }

    public init() {}

    private var explicitlyEnabledSources: Set<String> { Set(enabledPolicy.overrides.filter(\.value).keys) }
    private var explicitlyDetailedSources: Set<String> { Set(detailPolicy.overrides.filter(\.value).keys) }

    public mutating func setEnabled(_ enabled: Bool) {
        configure(enabled: enabled ? [HiNotificationSourceEvidence.hiBundleID] : [],
                  detailed: explicitlyDetailedSources)
    }

    public mutating func setApplicationAvailable(_ available: Bool) {
        applicationAvailable = available
        if !available { dismiss() }
    }

    public mutating func setDetailed(_ detailed: Bool) {
        var sources = explicitlyDetailedSources
        if detailed { sources.insert(HiNotificationSourceEvidence.hiBundleID) }
        else { sources.remove(HiNotificationSourceEvidence.hiBundleID) }
        configure(enabled: explicitlyEnabledSources, detailed: sources)
    }

    /// Convenience for an explicit, closed set of sources; nothing outside it is allowed.
    public mutating func configure(enabled: Set<String>, detailed: Set<String>) {
        configure(enabled: Self.closedPolicy(allowing: enabled), detailed: Self.closedPolicy(allowing: detailed))
    }

    public mutating func configure(enabled: AppNotificationPolicy, detailed: AppNotificationPolicy) {
        enabledPolicy = enabled
        detailPolicy = detailed
        if !enabled.allowsAnySource { clear(); return }
        guard let old = current else { return }
        if !enabled.allows(old.sourceBundleID) { dismiss(); return }
        if !detailed.allows(old.sourceBundleID) {
            current = HiNotificationNotice(id: old.id, sender: nil, body: nil,
                                           count: old.count, receivedAt: old.receivedAt,
                                           sourceBundleID: old.sourceBundleID, sourceName: old.sourceName)
        }
    }

    private static func closedPolicy(allowing sources: Set<String>) -> AppNotificationPolicy {
        AppNotificationPolicy(overrides: Dictionary(uniqueKeysWithValues: sources.map { ($0, true) }),
                              allowsUnconfiguredSources: false)
    }

    @discardableResult
    public mutating func receive(_ candidate: HiNotificationCandidate, now: TimeInterval) -> Bool {
        guard enabledPolicy.allows(candidate.sourceBundleID), applicationAvailable, now.isFinite, !candidate.identity.isEmpty else { return false }
        recentIdentities = recentIdentities.filter { now >= $0.value && now - $0.value <= Self.dedupLifetime }
        let dedupIdentity = candidate.sourceBundleID + "\u{0}" + candidate.identity
        guard recentIdentities[dedupIdentity] == nil else { return false }
        recentIdentities[dedupIdentity] = now
        if recentIdentities.count > Self.maxRecentIdentities,
           let oldest = recentIdentities.min(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value })?.key {
            recentIdentities.removeValue(forKey: oldest)
        }
        let count: Int
        if let old = current, old.sourceBundleID == candidate.sourceBundleID, now >= old.receivedAt, now - old.receivedAt <= Self.burstWindow {
            count = min(999, old.count + 1)
        } else {
            count = 1
        }
        let detailed = detailPolicy.allows(candidate.sourceBundleID)
        current = HiNotificationNotice(id: candidate.identity,
                                       sender: detailed ? Self.displayText(candidate.sender, limit: 80) : nil,
                                       body: detailed ? Self.displayText(candidate.body, limit: 240) : nil,
                                       count: count, receivedAt: now,
                                       sourceBundleID: candidate.sourceBundleID, sourceName: candidate.sourceName)
        return true
    }

    /// A system card can populate title/body after its AX-created event. Refreshing that
    /// same card must not count another message, extend its lifetime, or restore private text.
    public mutating func refreshCurrentContent(_ candidate: HiNotificationCandidate) {
        guard enabledPolicy.allows(candidate.sourceBundleID), applicationAvailable, detailPolicy.allows(candidate.sourceBundleID),
              let old = current, old.id == candidate.identity, old.sourceBundleID == candidate.sourceBundleID else { return }
        current = HiNotificationNotice(id: old.id,
                                       sender: Self.displayText(candidate.sender, limit: 80),
                                       body: Self.displayText(candidate.body, limit: 240),
                                       count: old.count, receivedAt: old.receivedAt,
                                       sourceBundleID: old.sourceBundleID, sourceName: old.sourceName)
    }

    /// Keep opaque recent identities so a delayed AX callback cannot replay a dismissed card.
    public mutating func dismiss() { current = nil }

    public mutating func clear() {
        current = nil
        recentIdentities.removeAll(keepingCapacity: false)
    }

    private static func displayText(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let cleaned = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" })
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return cleaned.isEmpty ? nil : String(cleaned.prefix(limit))
    }
}
