// Custom changes for 工位充电岛: containment check in front of a destructive delete.
import Foundation

/// Decides whether a path is safely inside the temporary directory before anything deletes it.
public enum TemporaryFilePathGuard {

    /// Both sides are resolved before comparing, because the two APIs that produce these
    /// paths disagree: `NSTemporaryDirectory()` reports `/var/folders/…` while a resolved
    /// security-scoped bookmark reports the canonical `/private/var/folders/…`. Comparing
    /// them raw makes the guard reject every real file, which silently turned cleanup into
    /// a no-op and let staged files accumulate forever.
    public static func isInsideTemporaryDirectory(_ url: URL, temporaryRoot: URL) -> Bool {
        let root = normalised(temporaryRoot)
        let target = normalised(url)
        guard target != root else { return false }
        // The separator matters: without it `/var/folders/ab` would look like a child of
        // `/var/folders/a`.
        return target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// `resolvingSymlinksInPath()` is deliberately not used: it only rewrites paths that
    /// currently exist, so the answer would change depending on whether the file had already
    /// been deleted. Stripping the `/private` prefix is the same normalisation macOS applies
    /// and it is decidable from the string alone.
    private static func normalised(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard path == "/private" || path.hasPrefix("/private/") else { return path }
        let trimmed = String(path.dropFirst("/private".count))
        return trimmed.isEmpty ? "/" : trimmed
    }
}
