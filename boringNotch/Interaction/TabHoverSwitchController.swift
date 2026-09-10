import Combine
import Defaults
import Foundation

/// Drives `TabHoverSwitchMachine` from SwiftUI hover callbacks.
///
/// The machine is pure and only reports what should happen at a given instant, so this
/// owns the one thing it cannot: waking back up when the dwell time has elapsed with no
/// further pointer movement to drive it.
@MainActor
final class TabHoverSwitchController<Tab: Equatable>: ObservableObject {
    private var machine: TabHoverSwitchMachine<Tab>
    private var pendingTask: Task<Void, Never>?
    private var hovered: Tab?
    private var observation: Set<AnyCancellable> = []
    private let onSwitch: (Tab) -> Void

    init(onSwitch: @escaping (Tab) -> Void) {
        self.onSwitch = onSwitch
        machine = TabHoverSwitchMachine(delay: Defaults[.tabHoverSwitchDelay])
        Defaults.publisher(.tabHoverSwitchDelay)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] change in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.cancel()
                    self.machine = TabHoverSwitchMachine(delay: change.newValue)
                }
            }
            .store(in: &observation)
    }

    func hover(_ tab: Tab?, isHovering: Bool, current: Tab) {
        guard Defaults[.tabSwitchOnHover] else { return }
        // A leave callback for a tab the pointer has already moved past would otherwise
        // cancel the switch the newly entered tab just scheduled.
        if !isHovering {
            guard let tab, let hovered, hovered == tab else { return }
            self.hovered = nil
        } else {
            hovered = tab
        }
        advance(current: current)
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        hovered = nil
        machine.cancel()
    }

    private func advance(current: Tab) {
        if let target = machine.update(hovered: hovered, current: current,
                                       now: ProcessInfo.processInfo.systemUptime) {
            pendingTask?.cancel()
            pendingTask = nil
            onSwitch(target)
            return
        }
        pendingTask?.cancel()
        pendingTask = nil
        guard let pending = machine.pending else { return }
        let wait = max(0, pending.deadline - ProcessInfo.processInfo.systemUptime)
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.pendingTask = nil
            self.advance(current: current)
        }
    }
}
