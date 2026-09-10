//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit
import Defaults

/// Why an item left the shelf. Recorded on every physical delete because three unrelated
/// paths can make an item vanish, and telling them apart after the fact used to be guesswork.
enum ShelfRemovalReason: String {
    case user
    case dragPolicy
    case retention
    case invalidSweep
}

/// A removal that can still be taken back.
struct ShelfUndoableRemoval: Identifiable {
    /// Decides which wording the undo chip shows and which reason the eventual file discard is
    /// booked under; the two kinds are otherwise handled identically.
    enum Kind { case draggedOut, cleared, cut }
    let id = UUID()
    let items: [ShelfItem]
    let kind: Kind

    /// Which path the log should blame once the window lapses and the backing files really go.
    /// Clearing is an explicit user action, so it must not borrow the drag-out policy's name —
    /// telling these paths apart after the fact is the whole point of `ShelfRemovalReason`.
    var expiryReason: ShelfRemovalReason {
        switch kind {
        case .draggedOut: return .dragPolicy
        case .cleared, .cut: return .user
        }
    }
}

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    /// How long a drag-out removal stays undoable, and therefore how long its backing file
    /// outlives the shelf entry.
    static let undoWindow: Duration = .seconds(10)

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { ShelfPersistenceService.shared.save(items) }
    }

    @Published var isLoading: Bool = false

    /// Non-nil while the last drag-out removal can still be undone.
    @Published private(set) var undoableRemoval: ShelfUndoableRemoval?

    var isEmpty: Bool { items.isEmpty }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?
    private var undoExpiryTask: Task<Void, Never>?

    private init() {
        var backfilled = false
        items = ShelfPersistenceService.shared.load().map {
            var item = $0
            // Pre-retention items carry no timestamp. Stamping them now starts their clock
            // at this launch rather than expiring them the moment the feature turns on.
            if item.addedAt == nil {
                item.addedAt = Date()
                backfilled = true
            }
            return item
        }
        // Property observers do not run for assignments made inside an initialiser, so the
        // `didSet` above never fires here and the stamps would live in memory only: every
        // launch would re-stamp them, and a user who quits the app daily would keep
        // pre-retention items forever. Persist the backfill explicitly, once.
        if backfilled { ShelfPersistenceService.shared.save(items) }
    }


    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identityKey while preserving order (existing first)
        var index: [String: Int] = [:]
        for (i, existing) in merged.enumerated() { index[existing.identityKey] = i }
        for it in newItems {
            let key = it.identityKey
            if let existing = index[key] {
                // Re-staging the same file is a fresh intent to keep it, so restart its clock.
                merged[existing].addedAt = it.addedAt ?? Date()
            } else {
                index[key] = merged.count
                merged.append(it)
            }
        }
        items = merged
    }

    func remove(_ item: ShelfItem, reason: ShelfRemovalReason) {
        discardStoredData(of: item, reason: reason)
        items.removeAll { $0.id == item.id }
    }

    /// Drops the entries now but keeps their backing files until the undo window lapses.
    ///
    /// Whether a drop was genuinely received is not knowable from the drag source — a
    /// Chromium window reports acceptance for its whole frame even when the payload is
    /// discarded — so the removal is made reversible instead of pretending it is certain.
    func removeAfterDragOut(_ dragged: [ShelfItem]) {
        let removed = dragged.filter { candidate in items.contains { $0.id == candidate.id } }
        guard !removed.isEmpty else { return }
        items.removeAll { item in removed.contains { $0.id == item.id } }

        // A second drag-out supersedes the first; the older one's files are freed now.
        finaliseUndoWindow()
        openUndoWindow(with: removed, kind: .draggedOut)
    }

    /// Empties the shelf in one go, on the same terms as a drag-out: the entries go now,
    /// their files stay until the undo window lapses.
    func clearAll() {
        guard !items.isEmpty else { return }
        let cleared = items
        items.removeAll()
        // Settle any open window first, so one undo never restores two unrelated batches.
        finaliseUndoWindow()
        openUndoWindow(with: cleared, kind: .cleared)
    }

    /// Removes items that were just written to the clipboard. Reversible on the same terms
    /// as a drag-out, which matters more here than elsewhere: the clipboard holds file URLs,
    /// so deleting the files immediately would leave the user with an unpasteable clipboard.
    func removeAfterCut(_ cut: [ShelfItem]) {
        let removed = cut.filter { candidate in items.contains { $0.id == candidate.id } }
        guard !removed.isEmpty else { return }
        items.removeAll { item in removed.contains { $0.id == item.id } }
        finaliseUndoWindow()
        openUndoWindow(with: removed, kind: .cut)
    }

    private func openUndoWindow(with removed: [ShelfItem], kind: ShelfUndoableRemoval.Kind) {
        let pending = ShelfUndoableRemoval(items: removed, kind: kind)
        undoableRemoval = pending
        undoExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            guard let self, self.undoableRemoval?.id == pending.id else { return }
            self.finaliseUndoWindow()
        }
    }

    func undoLastRemoval() {
        guard let pending = undoableRemoval else { return }
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        undoableRemoval = nil
        // Files were deliberately left in place, so the entries can go straight back.
        add(pending.items)
    }

    /// Closes an open undo window at quit time.
    ///
    /// The entries are already gone from the persisted list, so quitting inside the ten
    /// seconds would otherwise leave their files behind with nothing left referencing them —
    /// exactly the orphaning that made shelf temp files accumulate before the path guard was
    /// fixed. Not undoing within the window means the move-out stands, so the files go.
    func finaliseUndoWindowBeforeTermination() {
        finaliseUndoWindow()
    }

    /// Frees the files held for undo and closes the window.
    private func finaliseUndoWindow() {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        guard let pending = undoableRemoval else { return }
        undoableRemoval = nil
        for item in pending.items {
            discardStoredData(of: item, reason: pending.expiryReason)
        }
    }

    private func discardStoredData(of item: ShelfItem, reason: ShelfRemovalReason) {
        if item.isTemporary, let url = resolveFileURL(for: item) {
            NSLog("🗑️ Shelf discarding temporary file (\(reason.rawValue)): \(url.path)")
        }
        item.cleanupStoredData()
    }

    /// Clears items whose retention window has lapsed. Only files this app created are
    /// deleted; anything dragged in from Finder just loses its shelf entry.
    func sweepExpiredItems(now: Date = Date()) {
        let policy = Defaults[.shelfRetention].corePolicy
        guard policy != .off else { return }
        let expired = items.filter {
            ShelfRetentionPolicy.isExpired(addedAt: $0.addedAt, now: now, policy: policy)
        }
        guard !expired.isEmpty else { return }
        for item in expired { discardStoredData(of: item, reason: .retention) }
        items.removeAll { item in expired.contains { $0.id == item.id } }
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
        }
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            
            guard let self = self else { return }
            
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                if let idx = self.items.firstIndex(where: { $0.id == itemID }),
                   case .file = self.items[idx].kind {
                    self.items[idx].kind = .file(bookmark: bookmarkData)
                }
            }
            
            self.pendingBookmarkUpdates.removeAll()
        }
    }


    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        isLoading = true
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers)
            await MainActor.run {
                self?.add(dropped)
                self?.isLoading = false
            }
        }
    }

    func cleanupInvalidItems() {
        Task { [weak self] in
            guard let self else { return }
            var keep: [ShelfItem] = []
            for item in self.items {
                switch item.kind {
                case .file(let data):
                    let bookmark = Bookmark(data: data)
                    if await bookmark.validate() {
                        keep.append(item)
                    } else {
                        self.discardStoredData(of: item, reason: .invalidSweep)
                    }
                default:
                    keep.append(item)
                }
            }
            await MainActor.run { self.items = keep }
        }
    }


    func resolveFileURL(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = resolveFileURL(for: it) { urls.append(u) }
        }
        return urls
    }
}
