// Actual production managers, with only hardware and presentation endpoints substituted.
@MainActor final class SystemHUDPresentation {
    static let shared = SystemHUDPresentation()
    var available = true
    var values: [(SystemHUDKind, Double, String?)] = []
    func show(kind: SystemHUDKind, value: Double, error: String? = nil, icon: String = "") {
        guard available else { return }
        values.append((kind, value, error))
    }
}
@MainActor final class HUDStateManager {
    static let shared = HUDStateManager()
    var error: String?
    var results: [(kind: SystemHUDKind, actual: Double?, muted: Bool?, error: String?)] = []
    var controlGeneration: UInt64 = 0
    func recordControlError(_ value: String?) { error = value }
    func recordControlResult(kind: SystemHUDKind, actualValue: Double?, isMuted: Bool? = nil, error: String?) {
        self.error = error
        results.append((kind, actualValue, isMuted, error))
    }
}
@MainActor final class XPCHelperClient {
    static let shared = XPCHelperClient()
    func currentScreenBrightness() async -> Float? { nil }
    func setScreenBrightness(_ value: Float) async -> Bool { false }
    func currentKeyboardBrightness() async -> Float? { nil }
    func setKeyboardBrightness(_ value: Float) async -> Bool { false }
}
@MainActor final class FakeAudioDevice: VolumeDeviceControlling {
    var reading = VolumeDeviceReading(deviceID: 1, volume: 0.5, hardwareMuted: false)
    var readUnavailable = false
    var failReadAfterWrite = false
    var writeSucceeds = true
    var muteSucceeds = true
    var quantized: Float?
    var writes: [Float] = []
    func read() -> VolumeDeviceReading? { readUnavailable ? nil : reading }
    func writeVolume(_ value: Float32, deviceID: AudioObjectID) -> Bool {
        writes.append(value)
        guard writeSucceeds else { return false }
        reading = .init(deviceID: deviceID, volume: quantized ?? value, hardwareMuted: reading.hardwareMuted)
        if failReadAfterWrite { readUnavailable = true }
        return true
    }
    func writeMute(_ muted: Bool, deviceID: AudioObjectID) -> Bool? {
        guard reading.hardwareMuted != nil else { return nil }
        guard muteSucceeds else { return false }
        reading = .init(deviceID: deviceID, volume: reading.volume, hardwareMuted: muted)
        return true
    }
    func startObserving(_ onChange: @escaping @MainActor () -> Void) {}
}
@main struct Harness {
    @MainActor static func main() async {
        var checks = 0
        func expect(_ result: @autoclosure () -> Bool, _ message: String) {
            precondition(result(), message); checks += 1
        }
        let hud = SystemHUDPresentation.shared
        let diagnostics = HUDStateManager.shared
        let audio = FakeAudioDevice()
        let volume = VolumeManager(device: audio, observeSystem: false)
        volume.increase()
        expect(volume.rawVolume == 0.5625 && hud.values.last?.1 == 0.5625, "volume step publishes actual readback")
        audio.quantized = 0.625
        volume.setAbsolute(0.61)
        expect(volume.rawVolume == 0.625 && hud.values.last?.1 == 0.625, "quantized result replaces requested target")
        expect(diagnostics.results.last?.kind == .volume && diagnostics.results.last?.actual == 0.625 && diagnostics.results.last?.error == nil,
               "volume diagnostics use actual quantized readback rather than target")
        audio.writeSucceeds = false
        volume.setAbsolute(0.9)
        expect(volume.rawVolume == 0.625 && hud.values.last?.2 != nil, "failed write does not fake target")
        audio.writeSucceeds = true
        audio.quantized = nil
        audio.failReadAfterWrite = true
        volume.setAbsolute(0.9)
        expect(volume.rawVolume == 0.625 && hud.values.last?.2 != nil, "missing audio readback retains previous confirmed value with error")
        expect(diagnostics.results.last?.actual == nil && diagnostics.results.last?.error == "Unable to read audio volume after changing it.",
               "volume diagnostics do not label cached level as a fresh readback")
        let writes = audio.writes.count
        volume.setAbsolute(0.8)
        expect(audio.writes.count == writes, "missing initial audio reading prevents blind write")
        audio.readUnavailable = false
        audio.failReadAfterWrite = false
        audio.reading = .init(deviceID: 1, volume: 0.5, hardwareMuted: false)
        volume.toggleMuteAction()
        expect(volume.isMuted && hud.values.last?.1 == 0, "successful hardware mute is read back")
        volume.toggleMuteAction()
        expect(!volume.isMuted && hud.values.last?.1 == 0.5, "unmute reads actual retained volume")
        audio.muteSucceeds = false
        volume.toggleMuteAction()
        expect(!volume.isMuted && hud.values.last?.2 != nil, "failed mute does not flip displayed state")
        let software = FakeAudioDevice()
        software.reading = .init(deviceID: 2, volume: 0.4, hardwareMuted: nil)
        let softwareVolume = VolumeManager(device: software, observeSystem: false)
        softwareVolume.toggleMuteAction()
        expect(softwareVolume.isMuted && softwareVolume.rawVolume == 0, "unsupported hardware mute uses verified volume-zero fallback")
        softwareVolume.toggleMuteAction()
        expect(!softwareVolume.isMuted && softwareVolume.rawVolume == 0.4, "software mute restores confirmed previous level")
        software.writeSucceeds = false
        softwareVolume.toggleMuteAction()
        expect(!softwareVolume.isMuted && softwareVolume.lastError != nil, "failed software mute preserves state")

        var value: Float = 0.25
        var canRead = true, writeOK = true, loseReadback = false
        var fixedResult: Float?
        let brightness = HardwareBrightnessManager(kind: .brightness, read: { canRead ? value : nil }, write: { target in
            guard writeOK else { return false }
            try? await Task.sleep(for: .milliseconds(1))
            value = fixedResult ?? target
            if loseReadback { canRead = false }
            return true
        }, refreshOnInit: false)
        for _ in 0..<4 { brightness.setRelative(delta: 1 / 16) }
        await brightness.waitUntilIdle()
        expect(brightness.rawBrightness == 0.5 && hud.values.last?.1 == 0.5, "rapid brightness commands use latest confirmed value")
        fixedResult = 0.7
        brightness.setAbsolute(value: 0.9)
        await brightness.waitUntilIdle()
        expect(brightness.rawBrightness == 0.7 && hud.values.last?.1 == Double(Float(0.7)), "brightness publishes actual hardware quantization")
        expect(diagnostics.results.last?.kind == .brightness && diagnostics.results.last?.actual == Double(Float(0.7)) && diagnostics.results.last?.error == nil,
               "brightness diagnostics use actual quantized value rather than requested target")
        writeOK = false
        brightness.setAbsolute(value: 0.1)
        await brightness.waitUntilIdle()
        expect(brightness.rawBrightness == 0.7 && hud.values.last?.2 != nil, "brightness write failure keeps actual value")
        writeOK = true
        fixedResult = nil
        loseReadback = true
        brightness.setAbsolute(value: 0.9)
        await brightness.waitUntilIdle()
        expect(brightness.rawBrightness == 0.7 && brightness.lastError != nil, "brightness readback failure never publishes requested target")
        expect(diagnostics.results.last?.actual == nil && diagnostics.results.last?.error == "Unable to read brightness after changing it.",
               "brightness diagnostics distinguish unavailable readback from cached state")
        brightness.showCurrent()
        await brightness.waitUntilIdle()
        expect(brightness.lastError == "Brightness is unavailable.", "show-current reports unavailable reading")
        let presentations = hud.values.count
        hud.available = false
        brightness.showCurrent()
        await brightness.waitUntilIdle()
        expect(hud.values.count == presentations, "unavailable presentation suppresses delayed results")
        hud.available = true
        let beforeLateResults = hud.values.count
        let beforeLateDiagnostics = diagnostics.results.count
        var lateValue: Float = 0.4
        var lateWrites = 0
        var finishWrite: CheckedContinuation<Void, Never>?
        let lateBrightness = HardwareBrightnessManager(kind: .brightness, read: { lateValue }, write: { target in
            lateWrites += 1
            await withCheckedContinuation { finishWrite = $0 }
            lateValue = target
            return true
        }, refreshOnInit: false)
        lateBrightness.setAbsolute(value: 0.8)
        lateBrightness.setAbsolute(value: 0.2)
        while finishWrite == nil { await Task.yield() }
        // Hide then restore before the old hardware reply arrives.
        HUDStateManager.shared.controlGeneration += 2
        finishWrite?.resume()
        await lateBrightness.waitUntilIdle()
        expect(lateWrites == 1 && lateBrightness.rawBrightness == 0.8 && hud.values.count == beforeLateResults && diagnostics.results.count == beforeLateDiagnostics,
               "old lifecycle cancels queued writes and cannot present or diagnose late readback after restore")
        print("Production hardware control checks: \(checks) passed")
    }
}
