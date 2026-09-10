import Foundation

enum BluetoothPowerAvailability: String, Equatable, Sendable {
    case unknown, supported, unsupported, unavailable
}

/// Public CoreBluetooth authorization for the process reading it. This is a
/// separate diagnostic from legacy IOBluetooth SPI availability and power.
enum BluetoothPowerAuthorization: String, Equatable, Sendable {
    case notDetermined, denied, restricted, allowed, unknown

    static func decode(rawValue: Int) -> Self {
        switch rawValue {
        case 0: .notDetermined
        case 1: .restricted
        case 2: .denied
        case 3: .allowed
        default: .unknown
        }
    }
}

/// Only an explicit request can enter the pending state. Keep one native
/// manager per app session; repeated UI clicks and permission events cannot
/// create another manager or infer anything about the controller's power.
struct BluetoothAccessRequestState: Equatable {
    private(set) var hasStarted = false
    private(set) var isRequesting = false

    mutating func begin(authorization: BluetoothPowerAuthorization) -> Bool {
        guard authorization == .notDetermined, !hasStarted else { return false }
        hasStarted = true
        isRequesting = true
        return true
    }

    mutating func observe(_ authorization: BluetoothPowerAuthorization) {
        if authorization != .notDetermined && authorization != .unknown { isRequesting = false }
    }
}

enum BluetoothPowerCommand: Equatable, Sendable {
    case refresh
    case toggle(expectedEnabled: Bool)
}

enum BluetoothPowerReading: Equatable, Sendable {
    case state(Bool), unsupported, unavailable

    static func decode(preferencesAvailable: Bool, rawPower: Int32?) -> Self {
        guard preferencesAvailable else { return .unsupported }
        switch rawPower { case 0: return .state(false); case 1: return .state(true); default: return .unavailable }
    }
}

enum BluetoothPowerFailure: String, Codable, Equatable, Sendable {
    case unsupported, unavailable, changedBeforeWrite, readbackUnavailable, unconfirmed, timedOut, cancelled, busy
    var messageKey: String {
        switch self {
        case .unsupported: "Direct Bluetooth control is not supported on this Mac. Use System Settings."
        case .unavailable: "Bluetooth power could not be read. Refresh before trying again."
        case .changedBeforeWrite: "Bluetooth changed since it was displayed. Check the current state and try again."
        case .readbackUnavailable: "The Bluetooth change was requested, but its current state could not be read."
        case .unconfirmed: "macOS did not confirm the requested Bluetooth power change."
        case .timedOut: "The Bluetooth change timed out. Refresh to check its current state."
        case .cancelled: "The Bluetooth request was cancelled. Check its current state before trying again."
        case .busy: "A Bluetooth request is already in progress."
        }
    }
}

/// Only this private app CLI protocol can invoke the helper. No executable paths,
/// device IDs, arbitrary arguments, or shell source are accepted from the UI.
enum BluetoothPowerHelperProtocol {
    static let flag = "--island-bluetooth-power"
    static func arguments(for command: BluetoothPowerCommand) -> [String] {
        switch command {
        case .refresh: [flag, "read"]
        case .toggle(let expected): [flag, "toggle", expected ? "1" : "0"]
        }
    }

    static func command(from arguments: [String]) -> BluetoothPowerCommand? {
        if arguments == [flag, "read"] { return .refresh }
        if arguments == [flag, "toggle", "0"] { return .toggle(expectedEnabled: false) }
        if arguments == [flag, "toggle", "1"] { return .toggle(expectedEnabled: true) }
        return nil
    }

    private struct Response: Codable {
        let version: Int
        let enabled: Bool?
        let failure: BluetoothPowerFailure?
    }

    static func encode(_ result: BluetoothPowerResult) -> Data? {
        try? JSONEncoder().encode(Response(version: 1, enabled: result.enabled, failure: result.failure))
    }

    static func decode(_ data: Data, exitCode: Int32) -> BluetoothPowerResult {
        guard exitCode == 0, !data.isEmpty, data.count <= 512,
              let response = try? JSONDecoder().decode(Response.self, from: data), response.version == 1 else {
            return .failed(.unavailable)
        }
        if response.failure == nil && response.enabled == nil { return .failed(.unavailable) }
        if [.unsupported, .unavailable, .readbackUnavailable, .cancelled, .busy].contains(response.failure),
           response.enabled != nil { return .failed(.unavailable) }
        if [.changedBeforeWrite, .unconfirmed].contains(response.failure),
           response.enabled == nil { return .failed(.unavailable) }
        return .init(enabled: response.enabled, failure: response.failure)
    }
}

struct BluetoothPowerResult: Equatable, Sendable {
    let enabled: Bool?
    let failure: BluetoothPowerFailure?
    var availability: BluetoothPowerAvailability {
        if failure == .unsupported { return .unsupported }
        return enabled == nil ? .unavailable : .supported
    }
    static func failed(_ failure: BluetoothPowerFailure) -> Self { .init(enabled: nil, failure: failure) }
}

/// A setter call is only a request: this SPI returns void. Success requires a
/// matching readback. A stale UI value, missing API or unreadable state cannot
/// produce a write, and an interrupted request is never automatically reversed.
enum BluetoothPowerTransaction {
    static func execute(_ command: BluetoothPowerCommand,
                        read: () -> BluetoothPowerReading,
                        write: (Bool) -> Void,
                        now: () -> TimeInterval,
                        pause: () -> Void,
                        isCancelled: () -> Bool = { false }) -> BluetoothPowerResult {
        guard !isCancelled() else { return .failed(.cancelled) }
        let initial = read()
        guard case let .state(current) = initial else {
            return .failed(initial == .unsupported ? .unsupported : .unavailable)
        }
        guard case let .toggle(expected) = command else { return .init(enabled: current, failure: nil) }
        guard expected == current else { return .init(enabled: current, failure: .changedBeforeWrite) }
        guard !isCancelled() else { return .failed(.cancelled) }
        let target = !current
        let deadline = now() + 5
        write(target)
        var latest: Bool?
        for attempt in 0..<51 {
            if attempt > 0 { pause() }
            guard !isCancelled() else { return .failed(.cancelled) }
            if now() > deadline { return .init(enabled: latest, failure: .timedOut) }
            switch read() {
            case .unsupported: return .failed(.unsupported)
            case .unavailable: return .failed(.readbackUnavailable)
            case .state(let actual):
                latest = actual
                if actual == target { return .init(enabled: actual, failure: nil) }
            }
        }
        return .init(enabled: latest, failure: .unconfirmed)
    }
}
