import Foundation

enum TimeMachineCommand: Sendable { case refresh, start, stop }

/// The production runner accepts only these four fixed, non-destructive verbs.
enum TimeMachineInvocation: Equatable, Sendable {
    case status, destinations, start, stop
    var arguments: [String] {
        switch self {
        case .status: ["status", "-X"]
        case .destinations: ["destinationinfo", "-X"]
        case .start: ["startbackup"]
        case .stop: ["stopbackup"]
        }
    }
}

enum TimeMachineFailure: Equatable, Sendable {
    case permissionRequired, unavailable, noDestination, commandFailed, unconfirmed, timedOut, cancelled, busy
    var messageKey: String {
        switch self {
        case .permissionRequired: "Time Machine access was denied. Check this app's permissions in System Settings."
        case .unavailable: "Time Machine status could not be read. Controls are unavailable."
        case .noDestination: "Set up a backup disk in Time Machine settings first."
        case .commandFailed: "Time Machine did not accept the backup action."
        case .unconfirmed: "The requested backup state could not be confirmed. Refresh to check."
        case .timedOut: "Time Machine timed out. Refresh to check whether a backup is running."
        case .cancelled: "The request was cancelled. Any backup already running has been left alone."
        case .busy: "A Time Machine request is already in progress."
        }
    }
}

struct TimeMachineResult: Equatable, Sendable {
    let running: Bool?
    /// Only whether a destination is configured, not whether its disk is online.
    let configAvailable: Bool?
    let failure: TimeMachineFailure?
    static func failed(_ failure: TimeMachineFailure, configured: Bool? = nil) -> Self {
        .init(running: nil, configAvailable: configured, failure: failure)
    }
}

struct TimeMachineProcessOutput: Sendable {
    let exitCode: Int32
    let output: Data
    let error: Data
    var timedOut = false
    var cancelled = false

    var failure: TimeMachineFailure? {
        if cancelled { return .cancelled }
        if timedOut { return .timedOut }
        guard exitCode != 0 else { return nil }
        // Do not expose or persist these strings: they can contain destination
        // names. Only known permission phrases are mapped to a fixed message.
        let text = String(data: error, encoding: .utf8)?.lowercased() ?? ""
        if text.contains("requires full disk access privileges") || text.contains("requires root privileges")
            || text.contains("operation not permitted") { return .permissionRequired }
        return .commandFailed
    }
}

enum TimeMachineTransaction {
    /// status -X is a version-dependent system diagnostic, not a public SDK
    /// contract. Fail closed on absent/unknown plist fields. Never infer Running
    /// from a successful process exit or a backup phase name.
    static func running(from output: TimeMachineProcessOutput) -> Bool? {
        guard output.failure == nil, let dictionary = plist(output.output),
              let value = dictionary["Running"] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() || String(cString: value.objCType) != "d",
              value == 0 || value == 1 else { return nil }
        return value.boolValue
    }

    static func configured(from output: TimeMachineProcessOutput) -> Bool? {
        if output.failure == nil, let dictionary = plist(output.output) {
            // macOS 26 destinationinfo -X returns a successful empty dictionary
            // when no destination is configured, rather than an empty array.
            if dictionary.isEmpty { return false }
            if let destinations = dictionary["Destinations"] as? [[String: Any]] {
                return !destinations.isEmpty
            }
        }
        // tmutil can return a nonzero status for an empty configuration. Match
        // only its exact native diagnostic, not a generic command failure.
        guard !output.cancelled, !output.timedOut, output.exitCode != 0 else { return nil }
        let diagnostic = String(data: output.error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return diagnostic == "tmutil: No destinations configured." ? false : nil
    }

    static func execute(_ command: TimeMachineCommand,
                        run: (TimeMachineInvocation) -> TimeMachineProcessOutput,
                        pause: () -> Void) -> TimeMachineResult {
        let status = run(.status)
        guard let initial = running(from: status) else {
            return .failed(readFailure(status))
        }
        let destinations = run(.destinations)
        guard let configured = configured(from: destinations) else {
            return .init(running: initial, configAvailable: nil, failure: readFailure(destinations))
        }
        let current = TimeMachineResult(running: initial, configAvailable: configured, failure: nil)
        if command == .refresh { return current }
        let target = command == .start
        if initial == target { return current }
        if target && !configured { return .init(running: false, configAvailable: false, failure: .noDestination) }

        let action = run(target ? .start : .stop)
        if let failure = action.failure { return .failed(failure, configured: configured) }
        var actual: Bool?
        for attempt in 0..<10 {
            if attempt > 0 { pause() }
            let observed = run(.status)
            guard let reading = running(from: observed) else {
                return .failed(readFailure(observed), configured: configured)
            }
            actual = reading
            if reading == target {
                return .init(running: reading, configAvailable: configured, failure: nil)
            }
        }
        return .init(running: actual, configAvailable: configured, failure: .unconfirmed)
    }

    private static func readFailure(_ output: TimeMachineProcessOutput) -> TimeMachineFailure {
        let failure = output.failure
        return failure == nil || failure == .commandFailed ? .unavailable : failure!
    }

    private static func plist(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= 1_048_576 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
