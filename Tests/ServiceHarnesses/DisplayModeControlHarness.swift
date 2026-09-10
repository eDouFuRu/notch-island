// Fake-service validation only. Does not construct the native display backend.
import Foundation

private let oldMode = DisplayModeOption(id: 1, width: 1000, height: 700, pixelWidth: 2000, pixelHeight: 1400, refreshRate: 60, usableForDesktop: true)
private let nextMode = DisplayModeOption(id: 2, width: 1200, height: 800, pixelWidth: 2400, pixelHeight: 1600, refreshRate: 120, usableForDesktop: true)
private func display(_ current: Int32) -> DisplayModeDisplay {
    .init(id: "test-display-A", ordinal: 1, isBuiltIn: true, isMirrored: false,
          currentModeID: current, modes: [oldMode, nextMode])
}

actor FakeDisplayDevice: DisplayModeControlling {
    private var commands: [DisplayModeCommand] = []
    private var fail = false
    private var pause = false
    private var waiting: CheckedContinuation<DisplayModeResult, Never>?
    func execute(_ command: DisplayModeCommand) async -> DisplayModeResult {
        commands.append(command)
        if pause { return await withCheckedContinuation { waiting = $0 } }
        if fail { return .init(displays: nil, failure: .unavailable) }
        switch command {
        case .refresh: return .init(displays: [display(1)], failure: nil)
        case .select(let request): return .init(displays: [display(request.mode.id)], failure: nil)
        }
    }
    func history() -> [DisplayModeCommand] { commands }
    func failReads() { fail = true }
    func pauseNext() { pause = true }
    func isWaiting() -> Bool { waiting != nil }
    func finish() { waiting?.resume(returning: .init(displays: nil, failure: .readbackUnavailable)); waiting = nil }
}

@main struct DisplayModeControlHarness {
    static func check(_ valid: Bool, _ message: String) {
        guard valid else { fatalError(message) }
        print("PASS \(message)")
    }
    @MainActor static func main() async {
        let device = FakeDisplayDevice()
        let control = SystemDisplayModeControl(device: device)
        check(await device.history().isEmpty && control.displays.isEmpty && !control.isBusy, "construction does not query or change a display")
        check(!(await control.select(displayID: "missing", modeID: 2)), "missing menu display rejected")
        check(await device.history().isEmpty, "missing menu choice does not reach device")
        check(await control.refresh(), "refresh succeeds with actual fake snapshot")
        check(await device.history() == [.refresh], "refresh issues read command only")
        check(control.displays == [display(1)] && !control.isBusy, "refresh publishes actual current mode")
        check(!(await control.select(displayID: "test-display-A", modeID: 99)), "missing menu mode rejected")
        check(await device.history() == [.refresh], "missing mode cannot reach device")
        check(await control.select(displayID: "test-display-A", mode: nextMode), "explicit selection completes")
        check(await device.history().last == .select(.init(displayID: "test-display-A", mode: nextMode)), "menu selection carries UUID and complete displayed mode snapshot")
        check(control.displays.first?.currentModeID == 2, "selection publishes returned state")
        await device.pauseNext()
        let selection = Task { await control.select(displayID: "test-display-A", mode: oldMode) }
        while !(await device.isWaiting()) { await Task.yield() }
        check(control.isBusy, "in-flight action exposes busy")
        let count = await device.history().count
        let duplicateRefresh = await control.refresh()
        let duplicateSelection = await control.select(displayID: "test-display-A", mode: oldMode)
        check(!duplicateRefresh && !duplicateSelection, "refresh and duplicate selection are rejected while busy")
        check(await device.history().count == count, "duplicate requests never reach device")
        await device.finish()
        check(!(await selection.value), "readback failure is not success")
        check(!control.isBusy && control.displays.isEmpty && control.errorKey != nil, "failure releases busy and discards stale checkmark")
    }
}
