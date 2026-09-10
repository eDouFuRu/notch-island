import AppKit
import Combine

/// Supplies `ApplicationNameIndex` with the names this Mac can actually attribute a banner to.
///
/// Two layers are needed. Running applications are cheap and cover almost every real sender, but
/// they are not enough on their own: `osascript -e 'display notification …'` posts a banner signed
/// "脚本编辑器" while Script Editor is not running at all. The on-disk scan covers that case and is
/// therefore not optional — it is just kept off the hot path.
@MainActor
final class InstalledApplicationCatalog: ObservableObject {
    static let shared = InstalledApplicationCatalog()

    /// A full disk scan is far too expensive to run per banner, and the set of installed
    /// applications barely changes; refresh it lazily instead.
    private static let fullScanInterval: TimeInterval = 600
    private static let searchPaths: [String] = [
        "/Applications", "/System/Applications", "/System/Applications/Utilities",
        "/System/Library/CoreServices", "/System/Library/CoreServices/Applications",
        NSHomeDirectory() + "/Applications"
    ]

    @Published private(set) var index = ApplicationNameIndex()

    private var installed: [String: ApplicationNameIndex.Entry] = [:]
    private var bundleURLs: [String: URL] = [:]
    private var icons: [String: NSImage] = [:]
    private var lastFullScan: Date?
    private var scanning = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rebuildIndex() }
            })
        }
        rebuildIndex()
        scanInstalledApplications(force: true)
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver(_:))
        observers.removeAll()
    }

    func bundleURL(for bundleID: String) -> URL? {
        if let url = bundleURLs[bundleID] { return url }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        bundleURLs[bundleID] = url
        return url
    }

    /// `NSWorkspace.icon(forFile:)` rebuilds a bitmap every call, which is far too heavy for a
    /// view body that re-renders while the notch animates.
    func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard let url = bundleURL(for: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    /// Called when a banner could not be attributed: the sender may simply be an application
    /// installed after the last scan.
    func refreshIfStale() {
        scanInstalledApplications(force: false)
    }

    private func rebuildIndex() {
        var merged = installed
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { continue }
            let path = app.bundleURL?.path ?? merged[bundleID]?.bundlePath ?? ""
            var names = merged[bundleID]?.displayNames ?? []
            if let name = app.localizedName, !name.isEmpty { names.insert(name) }
            guard !names.isEmpty, !path.isEmpty else { continue }
            if let url = app.bundleURL { bundleURLs[bundleID] = url }
            merged[bundleID] = .init(bundleID: bundleID, bundlePath: path, displayNames: names, isRunning: true)
        }
        index = ApplicationNameIndex(entries: Array(merged.values))
    }

    private func scanInstalledApplications(force: Bool) {
        guard !scanning else { return }
        if !force, let last = lastFullScan, Date().timeIntervalSince(last) < Self.fullScanInterval { return }
        scanning = true
        let paths = Self.searchPaths
        Task.detached(priority: .utility) {
            let started = Date()
            let found = Self.scan(paths: paths)
            let elapsed = Date().timeIntervalSince(started)
            await MainActor.run {
                let catalog = InstalledApplicationCatalog.shared
                catalog.installed = Dictionary(found.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
                for entry in found where catalog.bundleURLs[entry.bundleID] == nil {
                    catalog.bundleURLs[entry.bundleID] = URL(fileURLWithPath: entry.bundlePath)
                }
                catalog.lastFullScan = Date()
                catalog.scanning = false
                catalog.rebuildIndex()
                NSLog("[NotchIsland] application catalog: %d bundles in %.0f ms", found.count, elapsed * 1000)
            }
        }
    }

    private nonisolated static func scan(paths: [String]) -> [ApplicationNameIndex.Entry] {
        let manager = FileManager.default
        var bundles: [URL] = []
        for path in paths {
            let root = URL(fileURLWithPath: path)
            guard let children = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles]) else { continue }
            for child in children where child.pathExtension == "app" { bundles.append(child) }
            // One level down only: /Applications/<Vendor>/<App>.app is common, deeper nesting is not.
            for child in children where child.pathExtension.isEmpty {
                guard let nested = try? manager.contentsOfDirectory(at: child, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles]) else { continue }
                for candidate in nested where candidate.pathExtension == "app" { bundles.append(candidate) }
            }
        }
        var entries: [String: ApplicationNameIndex.Entry] = [:]
        for url in bundles {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty,
                  entries[bundleID] == nil else { continue }
            var names: Set<String> = [url.deletingPathExtension().lastPathComponent]
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty {
                    names.insert(value)
                }
            }
            entries[bundleID] = .init(bundleID: bundleID, bundlePath: url.path,
                                      displayNames: names, isRunning: false)
        }
        return Array(entries.values)
    }
}
