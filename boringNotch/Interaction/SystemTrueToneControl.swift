import Combine
import Darwin
import Foundation
import ObjectiveC

protocol TrueToneControlling: Sendable {
    func execute(_ command: TrueToneCommand) async -> TrueToneResult
}

/// Experimental compatibility with CoreBrightness. It changes only the user's
/// True Tone enabled preference, and only after an explicit toggle command.
final class CoreBrightnessTrueToneDevice: TrueToneControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dongfengrui.NotchIsland.true-tone", qos: .userInitiated)

    func execute(_ command: TrueToneCommand) async -> TrueToneResult {
        await withCheckedContinuation { continuation in
            queue.async {
                let runtime = TrueToneRuntime.load()
                let result = TrueToneTransaction.execute(command, read: {
                    runtime?.read() ?? .init(enabled: nil, availability: .unsupportedABI)
                }, write: { target in
                    runtime?.setEnabled(target) ?? false
                }, wait: {
                    Thread.sleep(forTimeInterval: TrueToneTransaction.readbackInterval)
                })
                continuation.resume(returning: result)
            }
        }
    }
}

private final class TrueToneRuntime {
    private typealias NewMethod = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Bool

    private let client: AnyObject?
    private let supportedMethod: Getter
    private let availableMethod: Getter
    private let enabledMethod: Getter
    private let setMethod: Setter
    private static let supported = NSSelectorFromString("supported")
    private static let available = NSSelectorFromString("available")
    private static let enabled = NSSelectorFromString("enabled")
    private static let setter = NSSelectorFromString("setEnabled:")
    private static let factory = NSSelectorFromString("new")
    // Objective-C classes remain registered; retain the framework handle.
    private static let framework = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL)

    private init(client: AnyObject?, supported: @escaping Getter, available: @escaping Getter,
                 enabled: @escaping Getter, setter: @escaping Setter) {
        self.client = client
        supportedMethod = supported
        availableMethod = available
        enabledMethod = enabled
        setMethod = setter
    }

    static func load() -> TrueToneRuntime? {
        guard framework != nil, let cls = NSClassFromString("CBTrueToneClient"),
              let factoryMethod = class_getClassMethod(cls, factory),
              let supportedMethod = class_getInstanceMethod(cls, supported),
              let availableMethod = class_getInstanceMethod(cls, available),
              let enabledMethod = class_getInstanceMethod(cls, enabled),
              let setterMethod = class_getInstanceMethod(cls, setter),
              TrueToneRuntimeABI.accepts(factory: encoding(factoryMethod), supported: encoding(supportedMethod),
                                         available: encoding(availableMethod), enabled: encoding(enabledMethod),
                                         setter: encoding(setterMethod)) else { return nil }
        let new = unsafeBitCast(method_getImplementation(factoryMethod), to: NewMethod.self)
        return TrueToneRuntime(client: new(cls, factory)?.takeRetainedValue(),
                               supported: unsafeBitCast(method_getImplementation(supportedMethod), to: Getter.self),
                               available: unsafeBitCast(method_getImplementation(availableMethod), to: Getter.self),
                               enabled: unsafeBitCast(method_getImplementation(enabledMethod), to: Getter.self),
                               setter: unsafeBitCast(method_getImplementation(setterMethod), to: Setter.self))
    }

    func read() -> TrueToneReading {
        guard let client else { return .init(enabled: nil, availability: .temporarilyUnavailable) }
        let supportedBefore = supportedMethod(client, Self.supported)
        let availableBefore = availableMethod(client, Self.available)
        guard supportedBefore, availableBefore else {
            // These BOOL methods cannot distinguish transport failure from an
            // unsupported display. Do not turn an unconfirmed false into "off".
            return .init(enabled: nil, availability: .temporarilyUnavailable)
        }
        let first = enabledMethod(client, Self.enabled)
        let second = enabledMethod(client, Self.enabled)
        return TrueToneReadPolicy.resolve(supportedBefore: supportedBefore, availableBefore: availableBefore,
                                          firstEnabled: first, secondEnabled: second,
                                          supportedAfter: supportedMethod(client, Self.supported),
                                          availableAfter: availableMethod(client, Self.available))
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        guard let client else { return false }
        // No activate/deactivate, mode, strength or display override methods.
        return setMethod(client, Self.setter, enabled)
    }

    private static func encoding(_ method: Method) -> String? {
        method_getTypeEncoding(method).map { String(cString: $0) }
    }
}

@MainActor
final class SystemTrueToneControl: ObservableObject {
    static let shared = SystemTrueToneControl()
    @Published private(set) var enabled: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?
    @Published private(set) var availability: TrueToneAvailability = .unknown
    var supported: Bool? { availability.supported }

    private let device: any TrueToneControlling
    private var state = TrueTonePresentationState()

    init(device: any TrueToneControlling = CoreBrightnessTrueToneDevice()) { self.device = device }

    func refresh() async { await submit(.refresh) }

    func toggle() async {
        guard !isBusy else { return }
        guard availability == .available, let expected = enabled else { await refresh(); return }
        await submit(.toggle(expectedEnabled: expected))
    }

    private func submit(_ command: TrueToneCommand) async {
        guard !Task.isCancelled, let generation = state.begin() else { return }
        publish()
        let result = await device.execute(command)
        guard state.receive(result, generation: generation) else { return }
        publish()
    }

    private func publish() {
        enabled = state.enabled
        availability = state.availability
        isBusy = state.isBusy
        errorKey = state.failure?.messageKey
    }
}
