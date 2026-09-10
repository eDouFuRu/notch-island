import Foundation

enum TrueToneAvailability: String, Equatable, Sendable {
    case unknown, available, unsupportedABI, temporarilyUnavailable

    // CBTrueToneClient's negative BOOL responses have no error channel. They
    // cannot distinguish absent hardware from an unavailable daemon connection.
    var supported: Bool? { self == .available ? true : nil }
}

struct TrueToneReading: Equatable, Sendable {
    let enabled: Bool?
    let availability: TrueToneAvailability
}

enum TrueToneReadPolicy {
    /// The enabled getter has no separate success result. Accept it only while
    /// both capability gates remain positive, and two state reads agree.
    static func resolve(supportedBefore: Bool, availableBefore: Bool,
                        firstEnabled: Bool?, secondEnabled: Bool?,
                        supportedAfter: Bool, availableAfter: Bool) -> TrueToneReading {
        guard supportedBefore, availableBefore, supportedAfter, availableAfter,
              let enabled = firstEnabled, secondEnabled == enabled else {
            return .init(enabled: nil, availability: .temporarilyUnavailable)
        }
        return .init(enabled: enabled, availability: .available)
    }
}

enum TrueToneCommand: Equatable, Sendable {
    case refresh
    case toggle(expectedEnabled: Bool)
}

enum TrueToneFailure: String, Equatable, Sendable {
    case unsupportedABI, readFailed, changedBeforeWrite, writeFailed, readbackUnavailable, unconfirmed

    var messageKey: String {
        switch self {
        case .unsupportedABI: "True Tone direct control is not compatible with this macOS version. Open Displays settings instead."
        case .readFailed: "True Tone status could not be confirmed. Refresh or check whether it is available in Displays settings."
        case .changedBeforeWrite: "True Tone changed since it was displayed. Check the current state and try again."
        case .writeFailed: "macOS did not accept the True Tone change. Check Displays settings and try again."
        case .readbackUnavailable: "The True Tone change was requested, but its resulting state could not be confirmed."
        case .unconfirmed: "macOS did not confirm the requested True Tone change."
        }
    }
}

struct TrueToneResult: Equatable, Sendable {
    let enabled: Bool?
    let availability: TrueToneAvailability
    let failure: TrueToneFailure?
}

enum TrueToneTransaction {
    static let readbackAttempts = 6
    static let readbackInterval: TimeInterval = 0.15

    static func execute(_ command: TrueToneCommand, read: () -> TrueToneReading,
                        write: (Bool) -> Bool, wait: () -> Void = {}) -> TrueToneResult {
        let current = read()
        guard current.availability == .available, let enabled = current.enabled else {
            return result(current, failure: current.availability == .unsupportedABI ? .unsupportedABI : .readFailed)
        }
        guard case let .toggle(expectedEnabled) = command else { return result(current) }
        guard enabled == expectedEnabled else { return result(current, failure: .changedBeforeWrite) }
        let target = !enabled
        // Never retry the setter, including when its return value is negative.
        guard write(target) else { return result(read(), failure: .writeFailed) }
        var actual = current
        for attempt in 0..<readbackAttempts {
            if attempt > 0 { wait() }
            actual = read()
            if actual.availability == .available, actual.enabled == target { return result(actual) }
            if actual.availability == .unsupportedABI { return result(actual, failure: .readbackUnavailable) }
        }
        return result(actual, failure: actual.availability == .available && actual.enabled != nil ? .unconfirmed : .readbackUnavailable)
    }

    private static func result(_ reading: TrueToneReading, failure: TrueToneFailure? = nil) -> TrueToneResult {
        let availability: TrueToneAvailability = reading.availability == .available && reading.enabled == nil ? .temporarilyUnavailable : reading.availability
        return .init(enabled: availability == .available ? reading.enabled : nil,
                     availability: availability, failure: failure)
    }
}

struct TrueTonePresentationState: Equatable {
    private(set) var enabled: Bool?
    private(set) var availability: TrueToneAvailability = .unknown
    private(set) var isBusy = false
    private(set) var failure: TrueToneFailure?
    private var generation: UInt64 = 0

    mutating func begin() -> UInt64? {
        guard !isBusy else { return nil }
        generation &+= 1
        isBusy = true
        failure = nil
        return generation
    }

    @discardableResult
    mutating func receive(_ result: TrueToneResult, generation: UInt64) -> Bool {
        guard isBusy, generation == self.generation else { return false }
        enabled = result.availability == .available ? result.enabled : nil
        availability = result.availability
        failure = result.failure
        isBusy = false
        return true
    }
}

/// BOOL getter/setter declarations verified against the current 64-bit runtime
/// and https://github.com/alin23/Lunar/blob/master/Lunar/Headers/CBTrueToneClient.h.
/// Reject unverified BOOL representations or calling conventions before FFI.
enum TrueToneRuntimeABI {
    static func accepts(factory: String?, supported: String?, available: String?,
                        enabled: String?, setter: String?) -> Bool {
        factory == "@16@0:8" && supported == "B16@0:8" && available == "B16@0:8" &&
            enabled == "B16@0:8" && setter == "B20@0:8B16"
    }
}
