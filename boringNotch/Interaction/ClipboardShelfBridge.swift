import AppKit
import Combine
import CryptoKit
import Defaults

/// Moves images between the system clipboard and the file shelf, in both directions.
///
/// Writing: a capture is copied to the clipboard as well as saved, matching what the
/// system's own "copy picture to clipboard" screenshot shortcuts do.
///
/// Reading: images copied by *any* app are pulled onto the shelf, so a screenshot taken
/// with a third-party tool ends up there too. The pasteboard publishes no change
/// notification, so this has to poll `changeCount`; the poll only inspects the declared
/// types and reads pixel data solely once an image type is actually present.
@MainActor
final class ClipboardShelfBridge: ObservableObject {
    static let shared = ClipboardShelfBridge()

    /// Slow enough to be negligible, quick enough that a screenshot reaches the shelf
    /// before the user goes looking for it.
    private static let pollInterval: TimeInterval = 0.8

    private let pasteboard = NSPasteboard.general
    private var gate: ClipboardImportGate
    private var timer: Timer?
    private var observation: Set<AnyCancellable> = []

    /// Digest of the last image actually staged, so copying the same picture again — which
    /// people do repeatedly while pasting it around — does not pile up one shelf entry and
    /// one temporary file per copy. Each copy is a new `changeCount`, and the entries are
    /// keyed by file path, so nothing else deduplicates them.
    private var lastImportedImageDigest: Data?

    /// Set by `CaptureTools` so an imported clipboard image reaches the shelf through the
    /// same bookmark/temporary-file path as every other capture.
    var importImage: ((NSImage) -> Bool)?

    private init() {
        gate = ClipboardImportGate(initialChangeCount: NSPasteboard.general.changeCount)
    }

    func start() {
        Defaults.publisher(.importClipboardImagesToShelf)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.syncTimer() } }
            .store(in: &observation)
        syncTimer()
    }

    /// Copies a captured image to the clipboard and marks that generation as ours, so the
    /// watcher does not read it straight back and add a duplicate to the shelf.
    func copyCaptureToClipboard(_ image: NSImage) {
        guard Defaults[.copyCaptureToClipboard] else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        gate.suppress(changeCount: pasteboard.changeCount)
    }

    func copyCaptureToClipboard(contentsOf url: URL) {
        guard Defaults[.copyCaptureToClipboard] else { return }
        // Reading a full-screen capture off disk is unbounded work — the file may sit on a
        // slow or network volume — and this runs right after a capture, while the island is
        // still animating. Only the read moves off the main actor; the write has to stay on
        // it so it remains ordered with `gate.suppress`, otherwise the watcher could read
        // our own image back and stage a duplicate.
        Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return }
            await MainActor.run {
                guard let image = NSImage(data: data) else { return }
                ClipboardShelfBridge.shared.copyCaptureToClipboard(image)
            }
        }
    }

    private func syncTimer() {
        // The timer runs only while the feature is on, so switching it off stops the app
        // touching the pasteboard at all rather than merely ignoring what it reads.
        guard Defaults[.importClipboardImagesToShelf] else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardShelfBridge.shared.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        // Type inspection only; pixel data is read below and solely when it is an image.
        // The files-before-bitmap rule lives in `ClipboardStagingDecision` so the watcher and
        // the explicit button cannot drift apart; see it for why the order matters.
        let hasImage = ClipboardStagingDecision.watcherImportsBitmap(
            hasFileURLs: pasteboard.canReadObject(forClasses: [NSURL.self],
                                                  options: [.urlReadingFileURLsOnly: true]),
            hasBitmap: pasteboard.canReadObject(forClasses: [NSImage.self], options: nil))
        guard gate.shouldImport(changeCount: changeCount, hasImage: hasImage,
                                enabled: Defaults[.importClipboardImagesToShelf]) else { return }
        // Compared before decoding, and taken from the declared bytes rather than a
        // re-encoded `tiffRepresentation`, so repeat copies cost a hash and nothing more.
        let digest = currentImageDigest()
        if let digest, digest == lastImportedImageDigest { return }
        guard let image = NSImage(pasteboard: pasteboard) else { return }
        if importImage?(image) == true { lastImportedImageDigest = digest }
    }

    /// Hash of the clipboard's raw image bytes, without decoding them into an image.
    private func currentImageDigest() -> Data? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) {
                return Data(SHA256.hash(data: data))
            }
        }
        return nil
    }
}
