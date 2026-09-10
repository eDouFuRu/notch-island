import Foundation

/// Decides which display names may be used to attribute a banner to a source application.
///
/// A name is rejected when a *different* application is currently running under it, because
/// borrowing another app's banner would misattribute someone else's message. Helper processes
/// that live inside the source's own bundle are not different applications: WeChat ships
/// `com.tencent.flue.WeChatAppEx` inside `WeChat.app` under the very same localized name
/// "微信", and treating it as a rival is what silently removed the only name real WeChat
/// banners are ever attributed to.
public enum AppNotificationNameFilter {
    public struct RunningApplication: Equatable, Sendable {
        public let bundleID: String?
        public let bundlePath: String?
        public let localizedName: String?

        public init(bundleID: String?, bundlePath: String?, localizedName: String?) {
            self.bundleID = bundleID
            self.bundlePath = bundlePath
            self.localizedName = localizedName
        }
    }

    public static let notificationCenterBundleID = "com.apple.notificationcenterui"

    public static func attributableNames(candidates: Set<String>, sourceBundleID: String,
                                         sourceBundlePath: String,
                                         running: [RunningApplication]) -> Set<String> {
        let rivals = running.filter { isRival($0, sourceBundleID: sourceBundleID, sourceBundlePath: sourceBundlePath) }
        return candidates.filter { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return !rivals.contains { $0.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame }
        }
    }

    private static func isRival(_ application: RunningApplication, sourceBundleID: String,
                                sourceBundlePath: String) -> Bool {
        guard let bundleID = application.bundleID,
              bundleID != sourceBundleID, bundleID != notificationCenterBundleID else { return false }
        guard let path = application.bundlePath else { return true }
        return !isBundlePath(path, containedIn: sourceBundlePath)
    }

    /// Path containment only; no symlink resolution, because a helper's bundle may be replaced
    /// during an update and `resolvingSymlinksInPath()` is undefined for a vanished path.
    public static func isBundlePath(_ path: String, containedIn container: String) -> Bool {
        let normalized = normalize(path)
        let root = normalize(container)
        guard !root.isEmpty else { return false }
        return normalized == root || normalized.hasPrefix(root + "/")
    }

    private static func normalize(_ path: String) -> String {
        var value = (path as NSString).standardizingPath
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
