//
//  QuickShareService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Dynamic representation of a sharing provider discovered at runtime
struct QuickShareProvider: Identifiable, Hashable, Sendable {
    var id: String
    var imageData: Data?
    var supportsRawText: Bool
}

class QuickShareService: ObservableObject {
    static let shared = QuickShareService()
    
    @Published var availableProviders: [QuickShareProvider] = []
    @Published var isPickerOpen = false
    private var cachedServices: [String: NSSharingService] = [:]
    // Each request owns its resources until its real sharing callback completes.
    private struct ActiveShare {
        let accessingURLs: [URL]
        let temporaryURLs: [URL]
        let delegate: SharingLifecycleDelegate
        let service: NSSharingService?
        let picker: NSSharingServicePicker?
    }
    private var activeShares: [UUID: ActiveShare] = [:]
   
    init() {
        Task {
            await discoverAvailableProviders()
        }
    }
    
    // MARK: - Provider Discovery
    
    @MainActor
    func discoverAvailableProviders() async {
        let finder = ShareServiceFinder()

        // Use simple test items without creating actual temp files
        // This avoids issues with the Share Sheet retaining references to deleted files
        let testItems: [Any] = [
            URL(string:"http://example.com") ?? URL(fileURLWithPath: "/"),
            "Test Text" as NSString
        ]

        let services = await finder.findApplicableServices(for: testItems)

        var providers: [QuickShareProvider] = []

        for svc in services {
            let title = svc.title
            let imgData = svc.image.tiffRepresentation
            let supportsRawText = svc.canPerform(withItems: ["Test Text"])
            let provider = QuickShareProvider(id: title, imageData: imgData, supportsRawText: supportsRawText)
            if !providers.contains(provider) {
                providers.append(provider)
                cachedServices[title] = svc
            }
        }
        
        if let idx = providers.firstIndex(where: { $0.id == "AirDrop" }) {
            let ad = providers.remove(at: idx)
            providers.insert(ad, at: 0)
        }

        if !providers.contains(where: { $0.id == "System Share Menu" }) {
            providers.append(QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true))
        }

        self.availableProviders = providers

    }
    
    // MARK: - File Picker
    @MainActor
    func showFilePicker(for provider: QuickShareProvider, from view: NSView?) async {
        guard !isPickerOpen else {
            print("⚠️ QuickShareService: File picker already open")
            return
        }

        isPickerOpen = true
        SharingStateManager.shared.beginInteraction()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = String(format: L("Select Files for %@"), provider.id)
        panel.message = String(format: L("Choose files to share via %@"), provider.id)

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            defer {
                self?.isPickerOpen = false
                SharingStateManager.shared.endInteraction()
            }

            if response == .OK && !panel.urls.isEmpty {
                Task {
                    await self?.shareFilesOrText(panel.urls, using: provider, from: view)
                }
            }
        }

        let response = panel.runModal()
        completion(response)
    }
    
    // MARK: - Sharing
    @MainActor
    func shareFilesOrText(_ items: [Any], using provider: QuickShareProvider, from view: NSView?, temporaryURLs: [URL] = []) async {
        let service = cachedServices[provider.id].flatMap { $0.canPerform(withItems: items) ? $0 : nil }
        // A picker needs an anchor, and the same cached service cannot own two delegates.
        guard service != nil || view != nil,
              !activeShares.values.contains(where: { $0.service != nil && $0.service === service }) else {
            temporaryURLs.forEach { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: $0) }
            return
        }
        let fileURLs = items.compactMap { $0 as? URL }.filter { $0.isFileURL }
        let accessingURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
        let requestID = UUID()

        // Setup lifecycle delegate to keep notch open during picker/service
        let delegate = SharingStateManager.shared.makeDelegate { [weak self] in
            self?.finishSharing(requestID)
        }

        if let svc = service {
            activeShares[requestID] = ActiveShare(accessingURLs: accessingURLs, temporaryURLs: temporaryURLs,
                                                  delegate: delegate, service: svc, picker: nil)
            // For direct service path, explicitly mark service interaction start
            delegate.markServiceBegan()
            svc.delegate = delegate
            svc.perform(withItems: items)
        } else {
            let picker = NSSharingServicePicker(items: items)
            activeShares[requestID] = ActiveShare(accessingURLs: accessingURLs, temporaryURLs: temporaryURLs,
                                                  delegate: delegate, service: nil, picker: picker)
            picker.delegate = delegate
            delegate.markPickerBegan()
            if let view {
                picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
            }
        }
    }

    @MainActor
    private func finishSharing(_ requestID: UUID) {
        guard let request = activeShares.removeValue(forKey: requestID) else { return }
        for url in request.accessingURLs {
            url.stopAccessingSecurityScopedResource()
        }
        request.temporaryURLs.forEach { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: $0) }
    }
// MARK: - SharingServiceDelegate

private class SharingServiceDelegate: NSObject {}
    
    func shareDroppedFiles(_ providers: [NSItemProvider], using shareProvider: QuickShareProvider, from view: NSView?) async {
        var itemsToShare: [Any] = []
        var foundText: String?

        for provider in providers {
            if let webURL = await provider.extractURL() {
                itemsToShare.append(webURL)
            } else if foundText == nil, let text = await provider.extractText() {
                foundText = text
            } else if let itemFileURL = await provider.extractItem() {
                let resolvedURL = await resolveShelfItemBookmark(for: itemFileURL) ?? itemFileURL
                itemsToShare.append(resolvedURL)
            }
        }

        // If text was found, prioritize sharing it.
        if let text = foundText {
            if shareProvider.supportsRawText {
                await shareFilesOrText([text], using: shareProvider, from: view)
            } else {
                if let tempTextURL = await TemporaryFileStorageService.shared.createTempFile(for: .text(text)) {
                    await shareFilesOrText([tempTextURL], using: shareProvider, from: view, temporaryURLs: [tempTextURL])
                } else {
                    await shareFilesOrText([text], using: shareProvider, from: view)
                }
            }
        } else if !itemsToShare.isEmpty {
            await shareFilesOrText(itemsToShare, using: shareProvider, from: view)
        }
    }

    private func resolveShelfItemBookmark(for fileURL: URL) async -> URL? {
        let items = await ShelfStateViewModel.shared.items

        for itm in items {
            if let resolved = await ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: itm) {
                if resolved.standardizedFileURL.path == fileURL.standardizedFileURL.path {
                    return resolved
                }
            }
        }
        print("❌ Failed to resolve bookmark for shelf item")
        return nil
    }
}

// MARK: - App Storage Extension for Provider Selection

extension QuickShareProvider {
    static var defaultProvider: QuickShareProvider {
        let svc = QuickShareService.shared

        if let airdrop = svc.availableProviders.first(where: { $0.id == "AirDrop" }) {
            return airdrop
        }
        return svc.availableProviders.first ?? QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true)
    }
}
