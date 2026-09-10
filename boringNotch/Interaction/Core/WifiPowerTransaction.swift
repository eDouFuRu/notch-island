import Foundation

struct WifiPowerReading: Equatable, Sendable {
    let interfaceID: String
    let enabled: Bool
}

enum WifiPowerCommand: Equatable, Sendable {
    case refresh
    case toggle(expectedEnabled: Bool)
}

enum WifiPowerFailure: String, Equatable, Sendable {
    case unavailable, changedBeforeWrite, writeFailed, readbackUnavailable, interfaceChanged, unconfirmed

    var messageKey: String {
        switch self {
        case .unavailable: "Wi-Fi power is unavailable on this Mac."
        case .changedBeforeWrite: "Wi-Fi changed since it was displayed. Check the current state and try again."
        case .writeFailed: "macOS could not change Wi-Fi power. Check System Settings and try again."
        case .readbackUnavailable: "Wi-Fi change was requested, but its current power state could not be read."
        case .interfaceChanged: "The Wi-Fi interface changed during the adjustment."
        case .unconfirmed: "macOS did not confirm the requested Wi-Fi power change."
        }
    }
}

struct WifiPowerResult: Equatable, Sendable {
    let enabled: Bool?
    let failure: WifiPowerFailure?
}

/// Runs entirely on the device's serial queue. The observed state at click time must
/// still match before any write; no optimistic target is returned as an actual value.
enum WifiPowerTransaction {
    static func execute(_ command: WifiPowerCommand,
                        read: () -> WifiPowerReading?,
                        write: (_ enabled: Bool, _ interfaceID: String) -> Bool) -> WifiPowerResult {
        guard let current = read(), !current.interfaceID.isEmpty else {
            return .init(enabled: nil, failure: .unavailable)
        }
        guard case let .toggle(expectedEnabled) = command else {
            return .init(enabled: current.enabled, failure: nil)
        }
        guard current.enabled == expectedEnabled else {
            return .init(enabled: current.enabled, failure: .changedBeforeWrite)
        }
        let target = !current.enabled
        let succeeded = write(target, current.interfaceID)
        let actual = read()
        guard succeeded else { return .init(enabled: actual?.enabled, failure: .writeFailed) }
        guard let actual, !actual.interfaceID.isEmpty else {
            return .init(enabled: nil, failure: .readbackUnavailable)
        }
        guard actual.interfaceID == current.interfaceID else {
            return .init(enabled: actual.enabled, failure: .interfaceChanged)
        }
        return .init(enabled: actual.enabled, failure: actual.enabled == target ? nil : .unconfirmed)
    }
}

/// Prevent an older asynchronous read from replacing a newer power operation's state.
struct WifiPowerPresentationState: Equatable {
    private(set) var enabled: Bool?
    private(set) var isBusy = false
    private(set) var failure: WifiPowerFailure?
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        isBusy = true
        failure = nil
        return generation
    }

    @discardableResult
    mutating func receive(_ result: WifiPowerResult, generation: UInt64) -> Bool {
        guard generation == self.generation else { return false }
        enabled = result.enabled
        failure = result.failure
        isBusy = false
        return true
    }
}
