import Foundation

enum NightShiftAvailability: String, Equatable, Sendable {
    case unknown, available, unsupportedABI, unsupportedHardware, temporarilyUnavailable

    var supported: Bool? {
        switch self {
        case .unknown, .unsupportedABI: nil
        case .unsupportedHardware: false
        case .available, .temporarilyUnavailable: true
        }
    }
}

struct NightShiftReading: Equatable, Sendable {
    let enabled: Bool?
    let availability: NightShiftAvailability
}

enum NightShiftCommand: Equatable, Sendable {
    case refresh
    case toggle(expectedEnabled: Bool)
}

enum NightShiftFailure: String, Equatable, Sendable {
    case unsupportedABI, unsupportedHardware, readFailed, changedBeforeWrite
    case writeFailed, readbackUnavailable, unconfirmed

    var messageKey: String {
        switch self {
        case .unsupportedABI: "Night Shift direct control is not compatible with this macOS version. Open Displays settings instead."
        case .unsupportedHardware: "Night Shift is not supported by this Mac."
        case .readFailed: "Night Shift status is temporarily unavailable. Refresh or check Displays settings."
        case .changedBeforeWrite: "Night Shift changed since it was displayed. Check the current state and try again."
        case .writeFailed: "macOS did not accept the Night Shift change. Check Displays settings and try again."
        case .readbackUnavailable: "The Night Shift change was requested, but its resulting state could not be read."
        case .unconfirmed: "macOS did not confirm the requested Night Shift change."
        }
    }
}

struct NightShiftResult: Equatable, Sendable {
    let enabled: Bool?
    let availability: NightShiftAvailability
    let failure: NightShiftFailure?
}

enum NightShiftTransaction {
    static let readbackAttempts = 6
    static let readbackInterval: TimeInterval = 0.15

    /// One serialized transaction: inspect the expected state, issue one write,
    /// then require both its BOOL success and a confirmed current-state read.
    static func execute(_ command: NightShiftCommand,
                        read: () -> NightShiftReading,
                        write: (Bool) -> Bool,
                        wait: () -> Void = {}) -> NightShiftResult {
        let current = read()
        guard current.availability == .available, let enabled = current.enabled else {
            return result(current, failure: failure(for: current.availability))
        }
        guard case let .toggle(expectedEnabled) = command else { return result(current) }
        guard expectedEnabled == enabled else { return result(current, failure: .changedBeforeWrite) }
        let target = !enabled
        guard write(target) else {
            // A rejected write never becomes success even if someone else
            // happened to change the same setting during our request.
            return result(read(), failure: .writeFailed)
        }
        var actual = current
        for attempt in 0..<readbackAttempts {
            if attempt > 0 { wait() }
            actual = read()
            if actual.availability == .available, actual.enabled == target { return result(actual) }
            if actual.availability == .unsupportedABI || actual.availability == .unsupportedHardware {
                return result(actual, failure: .readbackUnavailable)
            }
        }
        return result(actual, failure: actual.availability == .available && actual.enabled != nil ? .unconfirmed : .readbackUnavailable)
    }

    private static func result(_ reading: NightShiftReading, failure: NightShiftFailure? = nil) -> NightShiftResult {
        // Even a malformed backend response cannot expose an unavailable value
        // as "off" or leave a stale on/off value available to a future click.
        let known = reading.availability == .available ? reading.enabled : nil
        return .init(enabled: known, availability: reading.availability, failure: failure)
    }

    private static func failure(for availability: NightShiftAvailability) -> NightShiftFailure {
        switch availability {
        case .unsupportedABI: .unsupportedABI
        case .unsupportedHardware: .unsupportedHardware
        default: .readFailed
        }
    }
}

struct NightShiftPresentationState: Equatable {
    private(set) var enabled: Bool?
    private(set) var availability: NightShiftAvailability = .unknown
    private(set) var isBusy = false
    private(set) var failure: NightShiftFailure?
    private var generation: UInt64 = 0

    mutating func begin() -> UInt64? {
        guard !isBusy else { return nil }
        generation &+= 1
        isBusy = true
        failure = nil
        return generation
    }

    @discardableResult
    mutating func receive(_ result: NightShiftResult, generation: UInt64) -> Bool {
        guard isBusy, generation == self.generation else { return false }
        enabled = result.enabled
        availability = result.availability
        failure = result.failure
        isBusy = false
        return true
    }
}

/// Verified 64-bit Objective-C ABI from CoreBrightness runtime and the
/// primary binding: https://github.com/smudge/nightlight/blob/master/src/macos/status.rs.
/// Unknown layouts are unsupported; never guess a private struct's size.
enum NightShiftRuntimeABI {
    static let statusType = "{?=BBBi{?={?=ii}{?=ii}}QB}"
    static let statusBytes = 40
    static let statusAlignment = 8
    static let enabledOffset = 1
    static let availableOffset = 32

    static func accepts(getter: String?, setter: String?, support: String?, factory: String?) -> Bool {
        getter == "B24@0:8^\(statusType)16" && setter == "B20@0:8B16" &&
            support == "B16@0:8" && factory == "@16@0:8"
    }
}
