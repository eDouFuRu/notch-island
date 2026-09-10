// CoreAudio volume control with checked writes and actual readback.
import AppKit
import Combine
import CoreAudio
import Foundation

struct VolumeDeviceReading: Equatable {
    let deviceID: AudioObjectID
    let volume: Float32
    /// nil means the device has no hardware mute property.
    let hardwareMuted: Bool?
}

@MainActor
protocol VolumeDeviceControlling: AnyObject {
    func read() -> VolumeDeviceReading?
    func writeVolume(_ value: Float32, deviceID: AudioObjectID) -> Bool
    /// nil means hardware mute is unsupported; false means a real write failed.
    func writeMute(_ muted: Bool, deviceID: AudioObjectID) -> Bool?
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
}

@MainActor
final class VolumeManager: ObservableObject {
    static let shared = VolumeManager(device: CoreAudioVolumeDevice())
    @Published private(set) var rawVolume: Float = 0
    @Published private(set) var isMuted = false
    @Published private(set) var lastChangeAt: Date = .distantPast
    @Published private(set) var lastError: String?
    let visibleDuration: TimeInterval = 2

    private let device: VolumeDeviceControlling
    private var softwareMuted = false
    private var previousVolumeBeforeMute: Float32 = 0.2
    private var currentDeviceID: AudioObjectID?
    private let step: Float32 = 1 / 16

    init(device: VolumeDeviceControlling, observeSystem: Bool = true) {
        self.device = device
        if observeSystem { device.startObserving { [weak self] in self?.refresh() } }
        refresh()
    }

    var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < visibleDuration }

    func increase(stepDivisor: Float = 1) { adjustRelative(delta: step / max(stepDivisor, 0.25)) }
    func decrease(stepDivisor: Float = 1) { adjustRelative(delta: -step / max(stepDivisor, 0.25)) }

    func adjustRelative(delta: Float32) {
        guard let current = readActual() else { fail("Audio output volume is unavailable."); return }
        changeVolume(current.volume + delta, from: current)
    }

    func setAbsolute(_ value: Float32) {
        guard let current = readActual() else { fail("Audio output volume is unavailable."); return }
        changeVolume(value, from: current)
    }

    func toggleMuteAction() {
        guard let current = readActual() else { fail("Audio output volume is unavailable."); return }
        if let muted = current.hardwareMuted {
            guard device.writeMute(!muted, deviceID: current.deviceID) == true else {
                fail("Unable to change audio mute."); return
            }
        } else {
            let willMute = !softwareMuted
            if willMute && current.volume > 0.001 { previousVolumeBeforeMute = current.volume }
            let target: Float32 = willMute ? 0 : previousVolumeBeforeMute
            guard device.writeVolume(target, deviceID: current.deviceID) else {
                fail("Unable to change audio volume."); return
            }
            // Set the software intent only after a successful write. readActual verifies its effect.
            softwareMuted = willMute
        }
        finish(expectedDevice: current.deviceID)
    }

    func refresh() {
        guard let actual = readActual() else { lastError = "Audio output volume is unavailable."; return }
        publish(actual)
        lastError = nil
    }

    func showCurrent() {
        guard let actual = readActual() else { fail("Audio output volume is unavailable."); return }
        publish(actual)
        present(actual: actual, error: nil)
    }

    private func changeVolume(_ value: Float32, from current: VolumeDeviceReading) {
        guard value.isFinite else { fail("Invalid audio volume."); return }
        let target = min(1, max(0, value))
        if current.hardwareMuted == true && target > 0 {
            guard device.writeMute(false, deviceID: current.deviceID) == true else {
                fail("Unable to change audio mute."); return
            }
        }
        guard device.writeVolume(target, deviceID: current.deviceID) else {
            fail("Unable to change audio volume."); return
        }
        finish(expectedDevice: current.deviceID)
    }

    private func readActual() -> VolumeDeviceReading? {
        guard let actual = device.read(), actual.volume.isFinite, (0...1).contains(actual.volume) else { return nil }
        if currentDeviceID != actual.deviceID {
            currentDeviceID = actual.deviceID
            softwareMuted = false
            previousVolumeBeforeMute = 0.2
        }
        if actual.volume > 0.001 { softwareMuted = false }
        return actual
    }

    private func finish(expectedDevice: AudioObjectID) {
        guard let actual = readActual() else { fail("Unable to read audio volume after changing it."); return }
        publish(actual)
        present(actual: actual, error: actual.deviceID == expectedDevice ? nil : "Audio output changed during the adjustment.")
    }

    private func fail(_ error: String) {
        let actual = readActual()
        if let actual { publish(actual) }
        present(actual: actual, error: error)
    }

    private func publish(_ actual: VolumeDeviceReading) {
        rawVolume = actual.volume
        isMuted = actual.hardwareMuted ?? softwareMuted
    }

    private func present(actual: VolumeDeviceReading?, error: String?) {
        lastError = error
        lastChangeAt = Date()
        HUDStateManager.shared.recordControlResult(kind: .volume, actualValue: actual.map { Double($0.volume) },
                                                   isMuted: actual.map { $0.hardwareMuted ?? softwareMuted }, error: error)
        SystemHUDPresentation.shared.show(kind: .volume, value: Double(isMuted ? 0 : rawVolume), error: error)
    }
}

@MainActor
final class CoreAudioVolumeDevice: VolumeDeviceControlling {
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var listeners: [Listener] = []

    func read() -> VolumeDeviceReading? {
        let id = systemOutputDeviceID()
        guard id != kAudioObjectUnknown else { return nil }
        let volume: Float32
        if let master = readScalar(deviceID: id, element: kAudioObjectPropertyElementMain) {
            volume = master
        } else {
            let channels = (1...4).compactMap { readScalar(deviceID: id, element: UInt32($0)) }
            guard !channels.isEmpty else { return nil }
            volume = channels.reduce(0, +) / Float32(channels.count)
        }
        var address = property(kAudioDevicePropertyMute)
        var muted: Bool?
        if AudioObjectHasProperty(id, &address) {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
            muted = value != 0
        }
        return .init(deviceID: id, volume: volume, hardwareMuted: muted)
    }

    func writeVolume(_ value: Float32, deviceID: AudioObjectID) -> Bool {
        if writeScalar(value, deviceID: deviceID, element: kAudioObjectPropertyElementMain) { return true }
        var wrote = false
        var failed = false
        for element in UInt32(1)...4 {
            var address = property(kAudioDevicePropertyVolumeScalar, element: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            if writeScalar(value, deviceID: deviceID, element: element) { wrote = true }
            else { failed = true }
        }
        return wrote && !failed
    }

    func writeMute(_ muted: Bool, deviceID: AudioObjectID) -> Bool? {
        var address = property(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        guard isSettable(deviceID, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
        listeners.removeAll()
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        addListener(object: AudioObjectID(kAudioObjectSystemObject), address: &outputAddress) { [weak self] in
            self?.observeCurrentDevice(onChange)
            onChange()
        }
        observeCurrentDevice(onChange)
    }

    private func observeCurrentDevice(_ onChange: @escaping @MainActor () -> Void) {
        // Keep the default-device listener installed while replacing only the old device's listeners.
        for var listener in listeners where listener.object != AudioObjectID(kAudioObjectSystemObject) {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
        listeners.removeAll { $0.object != AudioObjectID(kAudioObjectSystemObject) }
        let id = systemOutputDeviceID()
        guard id != kAudioObjectUnknown else { return }
        for element in [kAudioObjectPropertyElementMain, 1, 2, 3, 4] {
            var address = property(kAudioDevicePropertyVolumeScalar, element: element)
            addListener(object: id, address: &address, action: onChange)
        }
        var muteAddress = property(kAudioDevicePropertyMute)
        addListener(object: id, address: &muteAddress, action: onChange)
    }

    private func addListener(object: AudioObjectID, address: inout AudioObjectPropertyAddress, action: @escaping @MainActor () -> Void) {
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { action() } }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append(.init(object: object, address: address, block: block))
        }
    }

    private func systemOutputDeviceID() -> AudioObjectID {
        var id = kAudioObjectUnknown
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return kAudioObjectUnknown }
        return id
    }

    private func property(_ selector: AudioObjectPropertySelector, element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    private func readScalar(deviceID: AudioObjectID, element: UInt32) -> Float32? {
        var address = property(kAudioDevicePropertyVolumeScalar, element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr,
              volume.isFinite, (0...1).contains(volume) else { return nil }
        return volume
    }

    private func isSettable(_ id: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    private func writeScalar(_ value: Float32, deviceID: AudioObjectID, element: UInt32) -> Bool {
        var address = property(kAudioDevicePropertyVolumeScalar, element: element)
        guard AudioObjectHasProperty(deviceID, &address), isSettable(deviceID, &address) else { return false }
        var scalar = value
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr
    }
}
