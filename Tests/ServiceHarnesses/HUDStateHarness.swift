// Dependency doubles and assertions only; production source is assembled at test time.
private enum FakeEnvironment { static var authorized = false; static var prompts = 0 }
func AXIsProcessTrusted() -> Bool { FakeEnvironment.authorized }
func AXIsProcessTrustedWithOptions(_ options: CFDictionary) -> Bool {
    FakeEnvironment.prompts += 1
    return FakeEnvironment.authorized
}
enum Defaults {
    enum Key { case hudReplacement }
    static var enabled = true
    static let changes = PassthroughSubject<Bool, Never>()
    static subscript(_ key: Key) -> Bool { get { enabled } set { enabled = newValue; changes.send(newValue) } }
    static func publisher(_ key: Key) -> PassthroughSubject<Bool, Never> { changes }
}
final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()
    enum StartResult: Equatable, Sendable { case running, permissionRequired, failed(String) }
    var onRuntimeStateChange: ((StartResult) -> Void)?
    var onMediaEvent: ((SystemMediaKeyEvent, Bool, UInt) -> Void)?
    var isTapEnabled = false
    var nextResult = StartResult.running
    var starts = 0; var stops = 0
    func start() -> StartResult { starts += 1; isTapEnabled = nextResult == .running; return nextResult }
    func stop() { stops += 1; isTapEnabled = false }
}
@MainActor final class SystemHUDPresentation {
    static let shared = SystemHUDPresentation()
    var available = false
    func setApplicationAvailable(_ value: Bool) { available = value }
}
@main struct Harness {
    @MainActor static func main() async {
        var checks = 0
        @MainActor func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        let manager = HUDStateManager.shared
        let tap = MediaKeyInterceptor.shared
        manager.start()
        expect(manager.status == .temporarilySuspended, "initial availability stays suspended")
        expect(FakeEnvironment.prompts == 0, "startup must not prompt")
        manager.setApplicationAvailable(true)
        expect(manager.status == .permissionRequired, "untrusted main process is identified")
        expect(Defaults.enabled, "missing access does not erase user choice")
        expect(tap.starts == 0, "no tap is attempted without trust")
        FakeEnvironment.authorized = true
        manager.refresh()
        expect(manager.status == .running && manager.accessibilityAuthorized, "trust starts tap")
        expect(manager.eventTapEnabled && SystemHUDPresentation.shared.available, "only a live tap enables custom HUD")
        tap.onMediaEvent?(SystemMediaKeyEvent(subtype: 8, data1: 0x0a00)!, true, 0)
        expect(manager.lastMediaEventAt != nil && manager.lastMediaEventDescription.contains("consumed=true"), "real event callback updates diagnostics")
        expect(manager.diagnosticsSummary.contains(Bundle.main.bundleURL.path), "diagnostics identify current process path")
        let keys = [0, 1, 2, 3, 7]
        for index in 0..<24 {
            let data = (keys[index % keys.count] << 16) | (index.isMultiple(of: 2) ? 0x0a00 : 0x0b00) | (index.isMultiple(of: 3) ? 1 : 0)
            tap.onMediaEvent?(SystemMediaKeyEvent(subtype: 8, data1: data)!, index.isMultiple(of: 2), UInt(100 + index))
        }
        expect(manager.recentMediaEvents.count == 20 && manager.recentMediaEvents.first?.modifierFlags == 104 && manager.recentMediaEvents.last?.modifierFlags == 123,
               "event diagnostics bound storage and evict oldest events")
        expect(manager.diagnosticsSummary.contains("brightness.decrease up repeat=false consumed=false") &&
               manager.diagnosticsSummary.contains("volume.decrease down repeat=true consumed=true") &&
               manager.recentMediaEvents.first!.timestamp <= manager.recentMediaEvents.last!.timestamp,
               "diagnostics preserve direction, transitions, repeats, consumption and ordered timestamps")
        for (subtype, data1) in [(1, 0x0a00), (8, (16 << 16) | 0x0a00)] {
            if let event = SystemMediaKeyEvent(subtype: subtype, data1: data1) { tap.onMediaEvent?(event, true, 999) }
        }
        expect(manager.recentMediaEvents.count == 20 && manager.recentMediaEvents.last?.modifierFlags == 123,
               "unsupported and ordinary events never enter media diagnostics")
        manager.recordControlResult(kind: .volume, actualValue: 0.625, isMuted: false, error: nil)
        expect(manager.lastControlResult?.succeeded == true && manager.lastControlResult?.actualValue == 0.625 &&
               manager.diagnosticsSummary.contains("actual=0.6250 muted=false outcome=success"), "confirmed control result includes actual value and success")
        let successTime = manager.lastControlResult!.timestamp
        manager.recordControlResult(kind: .brightness, actualValue: nil, error: "Unable to read brightness after changing it.")
        expect(manager.lastControlResult?.succeeded == false && manager.lastControlResult!.timestamp >= successTime &&
               manager.lastControlError == "Unable to read brightness after changing it." &&
               manager.diagnosticsSummary.contains("actual=Unavailable outcome=failure"), "missing readback explicitly replaces old successful result")
        tap.isTapEnabled = false
        tap.onRuntimeStateChange?(.failed("runtime failure"))
        expect(manager.status == .failed && !SystemHUDPresentation.shared.available, "runtime tap loss clears HUD synchronously")
        tap.nextResult = .failed("injected tap creation failure")
        manager.refresh()
        expect(manager.status == .failed, "tap failure remains distinct from authorization")
        expect(manager.accessibilityAuthorized, "tap failure must not report denied access")
        expect(manager.errorMessage == "injected tap creation failure", "tap failure is surfaced")
        expect(Defaults.enabled, "tap failure preserves preference")
        manager.setApplicationAvailable(false)
        expect(manager.status == .temporarilySuspended, "hidden/locked suspends")
        expect(Defaults.enabled, "hidden/locked preserves preference")
        expect(!manager.eventTapEnabled && !SystemHUDPresentation.shared.available, "unavailable panel disables tap and HUD")
        tap.nextResult = .running
        manager.setApplicationAvailable(true)
        expect(manager.status == .running, "unhide/unlock resumes")
        FakeEnvironment.authorized = false
        manager.refresh()
        expect(manager.status == .permissionRequired && !manager.accessibilityAuthorized, "revocation stops runtime")
        manager.requestPermission()
        expect(FakeEnvironment.prompts == 1, "only explicit request prompts")
        Defaults[.hudReplacement] = false
        manager.refresh()
        expect(manager.status == .disabled, "user disable stops runtime")
        expect(!Defaults.enabled, "user preference stays disabled")
        manager.stop()
        expect(manager.status == .disabled, "shutdown stops runtime")
        expect(tap.onRuntimeStateChange == nil, "shutdown releases callback")
        expect(tap.onMediaEvent == nil && !SystemHUDPresentation.shared.available, "shutdown releases diagnostics and presentation")
        print("HUD fault-injection checks: \(checks) passed")
    }
}
