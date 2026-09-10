import Combine
import CoreWLAN
import Foundation

protocol WifiPowerControlling: Sendable {
    func execute(_ command: WifiPowerCommand) async -> WifiPowerResult
}

/// No network names, scan results, BSSIDs, or saved configurations are read. All
/// CoreWLAN transactions run off the main thread and are serialized on one queue.
final class CoreWLANPowerDevice: WifiPowerControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dongfengrui.NotchIsland.wifi-power", qos: .userInitiated)

    func execute(_ command: WifiPowerCommand) async -> WifiPowerResult {
        await withCheckedContinuation { continuation in
            queue.async {
                let client = CWWiFiClient()
                let result = WifiPowerTransaction.execute(command, read: {
                    Self.read(client)
                }, write: { target, interfaceID in
                    guard let interface = client.interface(withName: interfaceID),
                          interface.interfaceName == interfaceID else { return false }
                    do {
                        try interface.setPower(target)
                        return true
                    } catch {
                        // Never log a raw CoreWLAN error that might include network data.
                        return false
                    }
                })
                continuation.resume(returning: result)
            }
        }
    }

    private static func read(_ client: CWWiFiClient) -> WifiPowerReading? {
        guard let interface = client.interface(), let name = interface.interfaceName,
              !name.isEmpty, client.interfaceNames()?.contains(name) == true else { return nil }
        // CoreWLAN's public powerOn method reports the current radio state. Its API
        // returns false on an internal read error as well; no private preference is
        // consulted to manufacture certainty beyond this public hardware interface.
        return .init(interfaceID: name, enabled: interface.powerOn())
    }
}

@MainActor
final class SystemWifiControl: ObservableObject {
    static let shared = SystemWifiControl()
    @Published private(set) var enabled: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?

    private let device: any WifiPowerControlling
    private var state = WifiPowerPresentationState()

    init(device: any WifiPowerControlling = CoreWLANPowerDevice()) {
        self.device = device
        // Instantiating a tile or opening Settings never changes radio power.
    }

    func refresh() async { await submit(.refresh) }

    /// Only the explicit user-click handler calls this. A missing initial reading
    /// triggers a read only, and a pending transaction rejects duplicate clicks.
    func toggle() async {
        guard !isBusy else { return }
        guard let expected = enabled else { await refresh(); return }
        await submit(.toggle(expectedEnabled: expected))
    }

    private func submit(_ command: WifiPowerCommand) async {
        let generation = state.begin()
        publish()
        let result = await device.execute(command)
        guard state.receive(result, generation: generation) else { return }
        publish()
    }

    private func publish() {
        enabled = state.enabled
        isBusy = state.isBusy
        errorKey = state.failure?.messageKey
    }
}
