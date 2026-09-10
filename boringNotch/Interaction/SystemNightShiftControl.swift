import Combine
import Darwin
import Foundation
import ObjectiveC

protocol NightShiftControlling: Sendable {
    func execute(_ command: NightShiftCommand) async -> NightShiftResult
}

/// Experimental compatibility with a private macOS API. Only the verified
/// enabled/status methods are used; no temperature or schedule is read into
/// application state or changed. Unsupported symbols/ABIs fail closed.
final class CoreBrightnessNightShiftDevice: NightShiftControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dongfengrui.NotchIsland.night-shift", qos: .userInitiated)

    func execute(_ command: NightShiftCommand) async -> NightShiftResult {
        await withCheckedContinuation { continuation in
            queue.async {
                // Build and use the client on this same serial queue. Neither
                // opening a tile nor initializing the controller performs writes.
                let runtime = NightShiftRuntime.load()
                let result = NightShiftTransaction.execute(command, read: {
                    runtime?.read() ?? .init(enabled: nil, availability: .unsupportedABI)
                }, write: { target in
                    runtime?.setEnabled(target) ?? false
                }, wait: {
                    Thread.sleep(forTimeInterval: NightShiftTransaction.readbackInterval)
                })
                continuation.resume(returning: result)
            }
        }
    }
}

private final class NightShiftRuntime {
    private typealias SupportMethod = @convention(c) (AnyClass, Selector) -> Bool
    private typealias NewMethod = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    private typealias ReadMethod = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias SetMethod = @convention(c) (AnyObject, Selector, Bool) -> Bool

    private let clientClass: AnyClass
    private let client: AnyObject?
    private let supportMethod: SupportMethod
    private let readMethod: ReadMethod
    private let setMethod: SetMethod
    private static let getter = NSSelectorFromString("getBlueLightStatus:")
    private static let setter = NSSelectorFromString("setEnabled:")
    private static let support = NSSelectorFromString("supportsBlueLightReduction")

    // Keep the framework loaded for the lifetime of its Objective-C classes.
    private static let framework = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL)

    private init(clientClass: AnyClass, client: AnyObject?, supportMethod: @escaping SupportMethod,
                 readMethod: @escaping ReadMethod, setMethod: @escaping SetMethod) {
        self.clientClass = clientClass
        self.client = client
        self.supportMethod = supportMethod
        self.readMethod = readMethod
        self.setMethod = setMethod
    }

    static func load() -> NightShiftRuntime? {
        guard framework != nil, let cls = NSClassFromString("CBBlueLightClient"),
              let getterMethod = class_getInstanceMethod(cls, getter),
              let setterMethod = class_getInstanceMethod(cls, setter),
              let supportMethod = class_getClassMethod(cls, support),
              let factoryMethod = class_getClassMethod(cls, NSSelectorFromString("new")),
              NightShiftRuntimeABI.accepts(getter: encoding(getterMethod), setter: encoding(setterMethod),
                                          support: encoding(supportMethod), factory: encoding(factoryMethod)) else { return nil }
        var size = 0
        var alignment = 0
        _ = NSGetSizeAndAlignment(NightShiftRuntimeABI.statusType, &size, &alignment)
        guard size == NightShiftRuntimeABI.statusBytes, alignment == NightShiftRuntimeABI.statusAlignment else { return nil }
        let supports = unsafeBitCast(method_getImplementation(supportMethod), to: SupportMethod.self)
        let factory = unsafeBitCast(method_getImplementation(factoryMethod), to: NewMethod.self)
        // Factory construction is unnecessary on unsupported hardware.
        let client = supports(cls, support) ? factory(cls, NSSelectorFromString("new"))?.takeRetainedValue() : nil
        return NightShiftRuntime(clientClass: cls, client: client, supportMethod: supports,
                                 readMethod: unsafeBitCast(method_getImplementation(getterMethod), to: ReadMethod.self),
                                 setMethod: unsafeBitCast(method_getImplementation(setterMethod), to: SetMethod.self))
    }

    func read() -> NightShiftReading {
        guard supportMethod(clientClass, Self.support) else {
            return .init(enabled: nil, availability: .unsupportedHardware)
        }
        guard let client else { return .init(enabled: nil, availability: .temporarilyUnavailable) }
        let bytes = NightShiftRuntimeABI.statusBytes
        let storage = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: NightShiftRuntimeABI.statusAlignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        guard readMethod(client, Self.getter, storage) else {
            return .init(enabled: nil, availability: .temporarilyUnavailable)
        }
        // Inspect only these two verified BOOL fields. Schedule/temperature are
        // neither interpreted nor exposed; a failed read never means "off".
        let enabled = storage.load(fromByteOffset: NightShiftRuntimeABI.enabledOffset, as: UInt8.self)
        let available = storage.load(fromByteOffset: NightShiftRuntimeABI.availableOffset, as: UInt8.self)
        guard enabled <= 1, available == 1 else {
            return .init(enabled: nil, availability: .temporarilyUnavailable)
        }
        return .init(enabled: enabled == 1, availability: .available)
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        guard let client else { return false }
        return setMethod(client, Self.setter, enabled)
    }

    private static func encoding(_ method: Method) -> String? {
        method_getTypeEncoding(method).map { String(cString: $0) }
    }
}

@MainActor
final class SystemNightShiftControl: ObservableObject {
    static let shared = SystemNightShiftControl()
    @Published private(set) var enabled: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?
    @Published private(set) var availability: NightShiftAvailability = .unknown
    var supported: Bool? { availability.supported }

    private let device: any NightShiftControlling
    private var state = NightShiftPresentationState()

    init(device: any NightShiftControlling = CoreBrightnessNightShiftDevice()) { self.device = device }

    func refresh() async { await submit(.refresh) }

    func toggle() async {
        guard !isBusy else { return }
        guard availability == .available, let expected = enabled else { await refresh(); return }
        await submit(.toggle(expectedEnabled: expected))
    }

    private func submit(_ command: NightShiftCommand) async {
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
