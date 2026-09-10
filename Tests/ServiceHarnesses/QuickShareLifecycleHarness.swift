// Dependency doubles and assertions only; production source is assembled at test time.
import AppKit
import Foundation
func L(_ key: String) -> String { key }
final class ShareServiceFinder {
    @MainActor func findApplicableServices(for items: [Any]) async -> [NSSharingService] { [] }
}
enum TempFileType { case text(String) }
final class TemporaryFileStorageService {
    static let shared = TemporaryFileStorageService()
    func createTempFile(for type: TempFileType) async -> URL? { nil }
    func removeTemporaryFileIfNeeded(at url: URL) { try? FileManager.default.removeItem(at: url) }
}
struct ShelfItem {}
@MainActor final class ShelfStateViewModel {
    static let shared = ShelfStateViewModel()
    var items: [ShelfItem] = []
    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? { nil }
}
extension NSItemProvider {
    func extractURL() async -> URL? { nil }
    func extractText() async -> String? { nil }
    func extractItem() async -> URL? { nil }
}


extension QuickShareService {
    @MainActor func diagnosticRetain(_ url: URL, picker: Bool = false) -> SharingLifecycleDelegate {
        let requestID = UUID()
        let delegate = SharingStateManager.shared.makeDelegate { [weak self] in self?.finishSharing(requestID) }
        activeShares[requestID] = ActiveShare(accessingURLs: [], temporaryURLs: [url], delegate: delegate, service: nil, picker: nil)
        if picker { delegate.markPickerBegan() } else { delegate.markServiceBegan() }
        return delegate
    }
}
@main struct ShareLifecycleHarness {
    @MainActor static func main() async throws {
        var checks = 0
        let root = URL(fileURLWithPath: "/private/tmp/notch-share-harness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func makeFile(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("test fixture".utf8).write(to: url)
            return url
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            checks += 1
            print("PASS " + label)
        }
        let service = NSSharingService(title: "Harness only", image: NSImage(size: NSSize(width: 1, height: 1)), alternateImage: nil, handler: {})
        let share = QuickShareService.shared
        let slowURL = try makeFile("slow.txt")
        let slow = share.diagnosticRetain(slowURL)
        try await Task.sleep(for: .milliseconds(2200))
        check(exists(slowURL) && SharingStateManager.shared.preventNotchClose, "pending share retains file and delegate beyond two seconds")
        slow.sharingService(service, didShareItems: [slowURL])
        check(!exists(slowURL) && !SharingStateManager.shared.preventNotchClose, "success releases file and sharing hold")
        slow.sharingService(service, didFailToShareItems: [], error: NSError(domain: "Harness", code: 1))
        check(!SharingStateManager.shared.preventNotchClose, "duplicate completion is harmless")
        let cancelURL = try makeFile("cancel.txt")
        let cancelled = share.diagnosticRetain(cancelURL, picker: true)
        cancelled.sharingServicePicker(NSSharingServicePicker(items: []), didChoose: nil)
        check(!exists(cancelURL) && !SharingStateManager.shared.preventNotchClose, "picker cancellation releases file")
        let failedURL = try makeFile("failed.txt")
        let failed = share.diagnosticRetain(failedURL)
        failed.sharingService(service, didFailToShareItems: [failedURL], error: NSError(domain: "Harness", code: 2))
        check(!exists(failedURL) && !SharingStateManager.shared.preventNotchClose, "service failure releases file")
        let firstURL = try makeFile("first.txt")
        let secondURL = try makeFile("second.txt")
        let first = share.diagnosticRetain(firstURL)
        let second = share.diagnosticRetain(secondURL)
        first.sharingService(service, didShareItems: [firstURL])
        check(!exists(firstURL) && exists(secondURL) && SharingStateManager.shared.preventNotchClose, "finishing one request preserves the other request's resources")
        second.sharingService(service, didShareItems: [secondURL])
        check(!exists(secondURL) && !SharingStateManager.shared.preventNotchClose, "last request releases remaining resources")
        print("Quick Share lifecycle checks: \(checks) passed")
    }
}
