// Dependency doubles and assertions only; production source is assembled at test time.
import Cocoa
import Combine
import Foundation

enum Defaults {
    enum Key { case showPowerStatusNotifications, hudReplacement }
    static var enabled = true
    /// The notice is drawn with the system HUD's chrome, so turning that replacement off is
    /// the only other thing that suppresses it.
    static var hudReplacement = true
    static subscript(key: Key) -> Bool {
        switch key {
        case .showPowerStatusNotifications: return enabled
        case .hudReplacement: return hudReplacement
        }
    }
}
final class BoringViewCoordinator: ObservableObject {
    static let shared = BoringViewCoordinator()
    enum ContentType { case battery }
    var deliveries = 0
    func toggleExpandingView(status: Bool, type: ContentType) { if status { deliveries += 1 } }
}
@MainActor final class IslandVisibility {
    static let shared = IslandVisibility()
    var isAvailable = true
}
struct BatteryInfo {
    var currentCapacity: Float = 80
    var maxCapacity: Float = 100
    var isPluggedIn = false
    var isCharging = false
    var isInLowPowerMode = false
    var timeToFullCharge = 0
}
final class BatteryActivityManager {
    static let shared = BatteryActivityManager()
    enum BatteryEvent {
        case powerSourceChanged(isPluggedIn: Bool), batteryLevelChanged(level: Float)
        case lowPowerModeChanged(isEnabled: Bool), isChargingChanged(isCharging: Bool)
        case timeToFullChargeChanged(time: Int), maxCapacityChanged(capacity: Float), error(description: String)
    }
    func initializeBatteryInfo() -> BatteryInfo { BatteryInfo() }
    func addObserver(_ observer: @escaping (BatteryEvent) -> Void) -> Int { 0 }
    func removeObserver(byId: Int) {}
}


extension BatteryStatusViewModel {
    func diagnosticNotify(after delay: Double = 0) { notifyImportanChangeStatus(delay: delay) }
}
@main struct BatteryGateHarness {
    @MainActor static func main() async throws {
        var checks = 0
        let model = BatteryStatusViewModel.shared
        let coordinator = BoringViewCoordinator.shared
        let visibility = IslandVisibility.shared
        func check(_ expected: Int, _ label: String) {
            precondition(coordinator.deliveries == expected, label)
            checks += 1
            print("PASS " + label)
        }
        Defaults.enabled = false
        model.diagnosticNotify()
        try await Task.sleep(for: .milliseconds(30))
        check(0, "disabled notification leaves shared presentation untouched")
        Defaults.enabled = true
        model.diagnosticNotify()
        try await Task.sleep(for: .milliseconds(30))
        check(1, "enabled visible notification delivers")
        visibility.isAvailable = false
        model.diagnosticNotify()
        try await Task.sleep(for: .milliseconds(30))
        check(1, "hidden or locked application does not deliver")
        visibility.isAvailable = true
        model.diagnosticNotify(after: 0.08)
        try await Task.sleep(for: .milliseconds(20))
        Defaults.enabled = false
        try await Task.sleep(for: .milliseconds(100))
        check(1, "disabling during delay cancels delivery")
        Defaults.enabled = true
        model.diagnosticNotify(after: 0.08)
        try await Task.sleep(for: .milliseconds(20))
        visibility.isAvailable = false
        try await Task.sleep(for: .milliseconds(100))
        check(1, "hiding or locking during delay cancels delivery")
        visibility.isAvailable = true
        model.diagnosticNotify()
        try await Task.sleep(for: .milliseconds(30))
        check(2, "new event after restore delivers once")
        Defaults.hudReplacement = false
        model.diagnosticNotify()
        try await Task.sleep(for: .milliseconds(30))
        check(2, "turning off the system HUD replacement suppresses the power notice")
        Defaults.hudReplacement = true
        model.diagnosticNotify()
        try await Task.sleep(for: .milliseconds(30))
        check(3, "restoring the HUD replacement brings the power notice back")
        print("Battery notification checks: \(checks) passed")
    }
}
