import AppKit
import Combine

/// Shared deadlines across all screens. Payloads remain in the source adapters only.
@MainActor
final class BriefPresentationCoordinator: ObservableObject {
    static let shared = BriefPresentationCoordinator()
    @Published private(set) var state = BriefPresentationState()
    private var expiryTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var hoveredSources = Set<UUID>()

    private init() {
        HiNotificationManager.shared.$current.sink { [weak self] notice in
            guard let self else { return }
            if let notice {
                self.state.receiveHi(id: notice.sourceBundleID + ":" + notice.id, now: self.now)
            } else {
                self.state.dismissHi()
                self.hoveredSources.removeAll()
            }
            self.scheduleExpiry()
        }.store(in: &subscriptions)
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func setApplicationAvailable(_ available: Bool) {
        state.setApplicationAvailable(available)
        if !available { hoveredSources.removeAll() }
        scheduleExpiry()
    }

    func showSong(duration: TimeInterval) {
        state.receiveSongChange(id: UUID().uuidString, now: now, duration: duration)
        scheduleExpiry()
    }
    func dismissSong() { state.dismissSongChange(); scheduleExpiry() }

    func setHovered(sourceID: UUID, hovered: Bool) {
        let wasHovered = !hoveredSources.isEmpty
        if hovered { hoveredSources.insert(sourceID) } else { hoveredSources.remove(sourceID) }
        guard wasHovered != !hoveredSources.isEmpty else { return }
        state.setHovered(!hoveredSources.isEmpty, now: now)
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let deadline = state.nextDeadline else { return }
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.001, deadline - ProcessInfo.processInfo.systemUptime))) }
            catch { return }
            guard let self else { return }
            let hiID = self.state.hi?.id
            self.state.expire(now: self.now)
            if hiID != nil && self.state.hi == nil {
                HiNotificationManager.shared.dismiss()
            }
            self.scheduleExpiry()
        }
    }
}
