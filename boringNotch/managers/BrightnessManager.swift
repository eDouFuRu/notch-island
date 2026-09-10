// Serialized hardware brightness controls. Values are published only after actual readback.
import AppKit

@MainActor
class HardwareBrightnessManager: ObservableObject {
    @Published private(set) var rawBrightness: Float = 0
    @Published private(set) var animatedBrightness: Float = 0
    @Published private(set) var lastChangeAt: Date = .distantPast
    @Published private(set) var lastError: String?

    private let kind: SystemHUDKind
    private let read: @MainActor () async -> Float?
    private let write: @MainActor (Float) async -> Bool
    private var requestGenerations: [UInt64] = []
    private lazy var control = SerialScalarControl(read: read, write: write) { [weak self] result in
        self?.receive(result)
    }

    init(
        kind: SystemHUDKind,
        read: @escaping @MainActor () async -> Float?,
        write: @escaping @MainActor (Float) async -> Bool,
        refreshOnInit: Bool = true
    ) {
        self.kind = kind
        self.read = read
        self.write = write
        if refreshOnInit { refresh() }
    }

    var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < 2 }
    func refresh() { enqueue(.refresh) }
    func showCurrent() { enqueue(.showCurrent) }
    func setRelative(delta: Float) { enqueue(.relative(delta)) }
    func setAbsolute(value: Float) { enqueue(.absolute(value)) }
    func waitUntilIdle() async { await control.waitUntilIdle() }

    private func enqueue(_ command: ScalarControlCommand) {
        let generation = HUDStateManager.shared.controlGeneration
        requestGenerations.append(generation)
        control.enqueue(command) {
            command == .refresh || HUDStateManager.shared.controlGeneration == generation
        }
    }

    private func receive(_ result: ScalarControlResult) {
        let generation = requestGenerations.removeFirst()
        if let actual = result.value {
            rawBrightness = actual
            animatedBrightness = actual
        }
        switch result.failure {
        case .cancelled: return
        case .invalidValue: lastError = "Invalid brightness value."
        case .readUnavailable: lastError = "Brightness is unavailable."
        case .writeFailed: lastError = "Unable to change brightness."
        case .readbackUnavailable: lastError = "Unable to read brightness after changing it."
        case nil: lastError = nil
        }
        if result.shouldPresent && HUDStateManager.shared.controlGeneration == generation {
            lastChangeAt = Date()
            HUDStateManager.shared.recordControlResult(kind: kind, actualValue: result.value.map(Double.init), error: lastError)
            SystemHUDPresentation.shared.show(kind: kind, value: Double(rawBrightness), error: lastError)
        }
    }
}

@MainActor
final class BrightnessManager: HardwareBrightnessManager {
    static let shared = BrightnessManager()
    private init() {
        super.init(
            kind: .brightness,
            read: { await XPCHelperClient.shared.currentScreenBrightness() },
            write: { await XPCHelperClient.shared.setScreenBrightness($0) }
        )
    }
}

@MainActor
final class KeyboardBacklightManager: HardwareBrightnessManager {
    static let shared = KeyboardBacklightManager()
    private init() {
        super.init(
            kind: .backlight,
            read: { await XPCHelperClient.shared.currentKeyboardBrightness() },
            write: { await XPCHelperClient.shared.setKeyboardBrightness($0) }
        )
    }
}
