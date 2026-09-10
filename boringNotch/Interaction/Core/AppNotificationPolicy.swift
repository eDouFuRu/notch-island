import Foundation

/// Decides whether a banner from a given application may be mirrored, and how much of it is shown.
///
/// Sources are allowed by default so that a freshly installed build behaves like a Dynamic Island:
/// a notification from an application the user has never configured still reaches the notch.
/// An explicit per-application choice always wins over the default, which is what makes turning a
/// noisy application off durable even if the default policy changes later.
public struct AppNotificationPolicy: Equatable, Sendable {
    public var overrides: [String: Bool]
    public var allowsUnconfiguredSources: Bool
    /// Applications excluded unless the user explicitly opts them in. Only the notch app itself,
    /// so that its own notifications do not get mirrored back onto the notch.
    public var builtInExclusions: Set<String>

    public init(overrides: [String: Bool] = [:], allowsUnconfiguredSources: Bool = true,
                builtInExclusions: Set<String> = []) {
        self.overrides = overrides
        self.allowsUnconfiguredSources = allowsUnconfiguredSources
        self.builtInExclusions = builtInExclusions
    }

    public func allows(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return allowsUnconfiguredSources }
        if let explicit = overrides[bundleID] { return explicit }
        if builtInExclusions.contains(bundleID) { return false }
        return allowsUnconfiguredSources
    }

    /// True when the source has never been configured, i.e. it is currently riding on the default.
    public func isUnconfigured(_ bundleID: String) -> Bool {
        overrides[bundleID] == nil
    }

    /// Whether anything at all could be mirrored. Used to decide if the AX observer is worth running.
    public var allowsAnySource: Bool {
        allowsUnconfiguredSources || overrides.values.contains(true)
    }
}
