// Custom changes for 工位充电岛: what the clipboard should contribute to the shelf.
import Foundation

/// What, if anything, the clipboard should put on the shelf.
///
/// Files come first and this is not a preference — it is a correctness rule. Copying a
/// document in Finder leaves *both* the file URL and a bitmap of that document's icon on the
/// pasteboard, so asking "is there an image?" first answers yes for a `.md` or a `.swift` and
/// stages a PNG of its icon under a `Clipboard-<date>.png` name. The original file, its
/// bytes and its extension are all lost.
public enum ClipboardStagingDecision: String, Equatable, Sendable {
    /// Copy the declared files verbatim, each keeping its own name and extension.
    case files
    /// Nothing but pixels — a screenshot or an image copied out of an app. Encoding it as PNG
    /// is the only option, and is correct here.
    case bitmap
    case nothing

    public static func decide(hasFileURLs: Bool, hasBitmap: Bool) -> Self {
        if hasFileURLs { return .files }
        return hasBitmap ? .bitmap : .nothing
    }

    /// The background watcher only ever handles a bare bitmap. Files are left to the explicit
    /// button so that copying something in Finder does not silently fill the shelf, and —
    /// more importantly — so an icon bitmap is never mistaken for the document itself.
    public static func watcherImportsBitmap(hasFileURLs: Bool, hasBitmap: Bool) -> Bool {
        decide(hasFileURLs: hasFileURLs, hasBitmap: hasBitmap) == .bitmap
    }

    /// The name a staged file keeps. Deliberately the source's own last path component: the
    /// staged copy must be openable by the same app that made it.
    public static func stagedFileName(source: String, fallback: @autoclosure () -> String) -> String {
        source.isEmpty ? fallback() : source
    }
}
