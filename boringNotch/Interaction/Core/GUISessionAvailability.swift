// Pure availability policy for startup snapshots and subsequent workspace events.
// GUI session information is required; optional lock information supplements it.
public struct GUISessionAvailability: Equatable, Sendable {
    public private(set) var consoleSessionReady = false
    public private(set) var sessionResignedActive = false
    public private(set) var screenLocked = false
    public private(set) var screenSleeping = false

    public init() {}

    public var isUnavailable: Bool {
        !consoleSessionReady || sessionResignedActive || screenLocked || screenSleeping
    }

    public mutating func refreshSession(onConsole: Bool?, loginDone: Bool?, locked: Bool?) {
        // Unknown GUI state must never enable a panel or its media-key tap.
        consoleSessionReady = onConsole == true && loginDone == true
        // The private optional field can disappear. Retain a known lock event
        // rather than interpreting its absence as an unlock operation.
        if let locked { screenLocked = locked }
    }

    public mutating func setSessionActive(_ active: Bool) {
        sessionResignedActive = !active
    }

    public mutating func setScreenLocked(_ locked: Bool) { screenLocked = locked }
    public mutating func setScreenSleeping(_ sleeping: Bool) { screenSleeping = sleeping }
}
