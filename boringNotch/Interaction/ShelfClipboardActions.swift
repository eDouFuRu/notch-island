import AppKit

/// Copy / cut / paste for the shelf, in one place.
///
/// Three entry points reach these: the shelf's context menu, the ⌘C/⌘X/⌘V chord monitor, and
/// — for paste — the quick-tools button. They must not drift apart, and in particular paste
/// must always go through `CaptureTools.importClipboardFiles()`, which copies declared files
/// byte for byte instead of re-encoding whatever bitmap the pasteboard happens to expose.
@MainActor
enum ShelfClipboardActions {
    /// Security-scoped access has to stay open for as long as the clipboard references the
    /// files, so the URLs outlive the call that wrote them.
    private static var accessedURLs: [URL] = []

    /// Whether pasting would do anything. Only consulted to decide whether to offer the
    /// command; the paste itself re-reads the pasteboard.
    static var clipboardHasStageableContent: Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.canReadObject(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Stages the clipboard's contents. Returns how many items landed.
    @discardableResult
    static func paste() -> Int {
        CaptureTools.shared.importClipboardFiles()
    }

    static func copy(_ items: [ShelfItem]) {
        Task { await write(items) }
    }

    /// Writes first, removes second: the clipboard holds file URLs, so the files have to
    /// still exist when the user pastes. The removal is the undoable kind, which keeps them
    /// on disk for the length of the undo window rather than deleting them outright.
    static func cut(_ items: [ShelfItem]) {
        Task {
            guard await write(items) else { return }
            ShelfStateViewModel.shared.removeAfterCut(items)
        }
    }

    @discardableResult
    private static func write(_ items: [ShelfItem]) async -> Bool {
        guard !items.isEmpty else { return false }
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let fileURLs = items.compactMap { item -> URL? in
            guard case .file = item.kind else { return nil }
            return ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item)
        }
        if !fileURLs.isEmpty {
            accessedURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
            pasteboard.writeObjects(fileURLs as [NSURL])
            return true
        }

        let names = items.map(\.displayName)
        guard !names.isEmpty else { return false }
        pasteboard.setString(names.joined(separator: "\n"), forType: .string)
        return true
    }
}
