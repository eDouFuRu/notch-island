import AppKit
import Combine
import Darwin
import Foundation

protocol AccessibilityDisplayControlling: Sendable {
    func read() async -> AccessibilityDisplaySnapshot
    /// Returns whether the setter was invoked, not whether it succeeded.
    func request(_ feature: AccessibilityDisplayFeature, enabled: Bool) async -> Bool
}

/// Experimental UniversalAccessCore compatibility, verified against the arm64
/// macOS 26 image: the two getters normalize w0 to 0/1; the setters consume w0
/// and return void. Do not assume these private ABIs on unverified OS versions.
/// No defaults writes, preference-file reads, permission requests, or UI scripts.
final class NativeAccessibilityDisplayDevice: AccessibilityDisplayControlling, @unchecked Sendable {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void
    private let queue = DispatchQueue(label: "com.dongfengrui.NotchIsland.accessibility-display", qos: .userInitiated)
    private let handle: UnsafeMutableRawPointer?
    private let getters: [AccessibilityDisplayFeature: Getter]
    private let setters: [AccessibilityDisplayFeature: Setter]

    init() {
        var loaded: UnsafeMutableRawPointer?
        var readers: [AccessibilityDisplayFeature: Getter] = [:]
        var writers: [AccessibilityDisplayFeature: Setter] = [:]
        #if arch(arm64)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 {
            let path = "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Frameworks/UniversalAccessCore.framework/UniversalAccessCore"
            loaded = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
            if let loaded {
                let prefixes: [AccessibilityDisplayFeature: String] = [
                    .reduceTransparency: "UAReduceTransparency", .increaseContrast: "UAIncreaseContrast"
                ]
                for (feature, prefix) in prefixes {
                    guard let getter = dlsym(loaded, prefix + "IsEnabled"),
                          let setter = dlsym(loaded, prefix + "SetEnabled") else { continue }
                    readers[feature] = unsafeBitCast(getter, to: Getter.self)
                    writers[feature] = unsafeBitCast(setter, to: Setter.self)
                }
            }
        }
        #endif
        handle = loaded
        getters = readers
        setters = writers
        // Hold the framework for this controller's lifetime: the native contrast
        // setter remembers/restores the earlier transparency state in process.
    }

    func read() async -> AccessibilityDisplaySnapshot {
        let raw: [AccessibilityDisplayFeature: Bool] = await withCheckedContinuation { continuation in
            queue.async { [self] in
                var result: [AccessibilityDisplayFeature: Bool] = [:]
                for (feature, getter) in getters {
                    switch getter() { case 0: result[feature] = false; case 1: result[feature] = true; default: break }
                }
                continuation.resume(returning: result)
            }
        }
        let effective: [AccessibilityDisplayFeature: Bool] = await MainActor.run {
            [ .reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              .increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ]
        }
        let confirmed = raw.filter { effective[$0.key] == $0.value }
        return .init(supportedFeatures: Set(getters.keys), states: confirmed)
    }

    func request(_ feature: AccessibilityDisplayFeature, enabled: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard handle != nil, let setter = setters[feature] else {
                    continuation.resume(returning: false); return
                }
                setter(enabled ? 1 : 0)
                continuation.resume(returning: true)
            }
        }
    }
}

@MainActor
final class SystemAccessibilityDisplayControl: ObservableObject {
    static let shared = SystemAccessibilityDisplayControl()
    @Published private(set) var states: [AccessibilityDisplayFeature: Bool] = [:]
    @Published private(set) var supportedFeatures: Set<AccessibilityDisplayFeature> = []
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?
    private let device: any AccessibilityDisplayControlling

    init(device: any AccessibilityDisplayControlling = NativeAccessibilityDisplayDevice()) {
        self.device = device
    }

    @discardableResult
    func refresh() async -> AccessibilityDisplayResult { await perform(.refresh) }

    @discardableResult
    func toggle(_ feature: AccessibilityDisplayFeature) async -> AccessibilityDisplayResult {
        guard let expected = states[feature] else { return await refresh() }
        return await toggle(feature: feature, expectedEnabled: expected)
    }

    @discardableResult
    func toggle(feature: AccessibilityDisplayFeature, expectedEnabled: Bool) async -> AccessibilityDisplayResult {
        await perform(.toggle(feature: feature, expectedEnabled: expectedEnabled))
    }

    private func perform(_ command: AccessibilityDisplayCommand) async -> AccessibilityDisplayResult {
        guard !isBusy else {
            return .init(snapshot: .init(supportedFeatures: supportedFeatures, states: states), failure: .busy)
        }
        isBusy = true
        errorKey = nil
        defer { isBusy = false }
        let result = await AccessibilityDisplayTransaction.execute(command, read: { [device] in await device.read() },
            write: { [device] feature, target in await device.request(feature, enabled: target) },
            pause: { try? await Task.sleep(nanoseconds: 100_000_000) })
        states = result.snapshot.states
        supportedFeatures = result.snapshot.supportedFeatures
        errorKey = result.failure?.messageKey
        return result
    }
}
