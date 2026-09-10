// Custom changes for 工位充电岛: clipboard-to-shelf import gating.
import Foundation

/// Decides which clipboard generations should be pulled onto the shelf.
///
/// The pasteboard has no change notification, so the caller polls `changeCount`. Two things
/// have to be filtered out before an import happens:
///
/// - Generations already seen, so a poll that finds nothing new imports nothing.
/// - The app's own writes. A capture is put on the clipboard *and* added to the shelf
///   directly, so without suppression the watcher would see that write and add a second
///   copy of the same screenshot.
public struct ClipboardImportGate: Equatable {
    private var lastSeenChangeCount: Int
    private var suppressedChangeCount: Int?

    public init(initialChangeCount: Int) {
        lastSeenChangeCount = initialChangeCount
    }

    /// Records that the app itself just wrote this generation, so the next poll ignores it.
    public mutating func suppress(changeCount: Int) {
        suppressedChangeCount = changeCount
        // A write is also something "seen": without this, a suppressed generation that is
        // never polled would leave `lastSeenChangeCount` behind and let a later poll treat
        // the app's own write as new.
        lastSeenChangeCount = max(lastSeenChangeCount, changeCount)
    }

    /// - Returns: whether this poll should import the clipboard's image.
    public mutating func shouldImport(changeCount: Int, hasImage: Bool, enabled: Bool) -> Bool {
        guard changeCount != lastSeenChangeCount else { return false }
        let wasOwnWrite = changeCount == suppressedChangeCount
        lastSeenChangeCount = changeCount
        if wasOwnWrite {
            suppressedChangeCount = nil
            return false
        }
        // Checked last so that a disabled watcher still advances the counter and does not
        // import a backlog the moment it is switched on.
        return enabled && hasImage
    }
}
