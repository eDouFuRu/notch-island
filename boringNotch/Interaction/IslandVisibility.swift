// Custom changes for 工位充电岛. One gate for every notch surface.
import AppKit
import Combine

@MainActor
final class IslandVisibility: ObservableObject {
    static let shared = IslandVisibility()
    static let hiddenKey = "island.notchHidden"
    @Published var isHidden: Bool {
        didSet { UserDefaults.standard.set(isHidden, forKey: Self.hiddenKey) }
    }
    @Published var screenUnavailable = false
    @Published var isChecking = false
    @Published var captureInProgress = false
    var isAvailable: Bool { !isHidden && !screenUnavailable && !captureInProgress }
    private init() { isHidden = UserDefaults.standard.bool(forKey: Self.hiddenKey) }
}
