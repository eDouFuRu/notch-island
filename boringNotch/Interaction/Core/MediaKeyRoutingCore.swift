import Foundation

public enum SystemMediaKey: Int, Equatable, Sendable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
}

/// NSEvent systemDefined subtype 8 stores the key in the high word and its state in bits 8...15.
public struct SystemMediaKeyEvent: Equatable, Sendable {
    public let key: SystemMediaKey
    public let isKeyDown: Bool
    public let isRepeat: Bool

    public init?(subtype: Int, data1: Int) {
        let bits = UInt32(truncatingIfNeeded: data1)
        guard subtype == 8,
              let key = SystemMediaKey(rawValue: Int((bits >> 16) & 0xffff)) else { return nil }
        let state = (bits >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        self.key = key
        self.isKeyDown = state == 0x0a
        self.isRepeat = bits & 1 != 0
    }
}

public enum MediaKeyDisposition: Equatable, Sendable {
    case passThrough
    case consume(performAction: Bool)
}

/// Own a whole down/up pair. A repeat without a captured initial down belongs to macOS.
public struct MediaKeyRoutingState: Sendable {
    private var pressed: Set<Int> = []
    public private(set) var generation: UInt64 = 0
    public init() {}

    public mutating func process(_ event: SystemMediaKeyEvent, canHandle: Bool) -> MediaKeyDisposition {
        if !event.isKeyDown {
            return pressed.remove(event.key.rawValue) == nil ? .passThrough : .consume(performAction: false)
        }
        if pressed.contains(event.key.rawValue) {
            return .consume(performAction: canHandle && event.isRepeat && event.key != .mute)
        }
        guard canHandle, !event.isRepeat else { return .passThrough }
        pressed.insert(event.key.rawValue)
        return .consume(performAction: true)
    }

    public mutating func reset() { pressed.removeAll(); generation &+= 1 }
}
