import Combine
import Foundation

@MainActor
final class SystemHUDPresentation: ObservableObject {
    static let shared = SystemHUDPresentation()
    @Published private(set) var state = SystemHUDState()
    var activeKind: SystemHUDKind? { state.activeKind }
    var value: Double { state.value }
    var error: String? { state.error }
    var expiration: TimeInterval? { state.expiration }
    private var expirationTask: Task<Void, Never>?

    private init() {}
    deinit { expirationTask?.cancel() }

    func setApplicationAvailable(_ available: Bool) {
        state.setApplicationAvailable(available)
        if !available { expirationTask?.cancel(); expirationTask = nil }
    }

    func show(kind: SystemHUDKind, value: Double, error: String? = nil, icon: String = "") {
        state.show(kind: kind, value: value, error: error, icon: icon,
                   now: ProcessInfo.processInfo.systemUptime)
        guard let deadline = state.expiration else { return }
        expirationTask?.cancel()
        expirationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(SystemHUDState.visibleDuration)) } catch { return }
            guard let self, self.state.expiration == deadline else { return }
            self.state.expire(now: max(deadline, ProcessInfo.processInfo.systemUptime))
            self.expirationTask = nil
        }
    }

    func clear() {
        expirationTask?.cancel()
        expirationTask = nil
        state.clear()
    }
}
