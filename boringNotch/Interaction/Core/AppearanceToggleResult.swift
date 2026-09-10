import Foundation

enum AppearanceToggleFailure: Equatable, Sendable {
    case authorizationRequired, cancelled, unavailable, unconfirmed, timedOut, busy

    var messageKey: String {
        switch self {
        case .authorizationRequired: "Allow this app to control System Events in System Settings > Privacy & Security > Automation."
        case .cancelled: "The appearance change was cancelled. Check the current appearance before trying again."
        case .unavailable: "System Events could not read the system appearance."
        case .unconfirmed: "macOS did not confirm the requested appearance change."
        case .timedOut: "The appearance change timed out. Check the current appearance before trying again."
        case .busy: "An appearance change is already in progress."
        }
    }
}

struct AppearanceToggleResult: Equatable, Sendable {
    /// Only a post-write read may describe the resulting system state. A failed
    /// write may have partially completed, so its earlier reading is not reused.
    let enabled: Bool?
    let failure: AppearanceToggleFailure?

    static func failed(_ reason: AppearanceToggleFailure) -> Self {
        .init(enabled: nil, failure: reason)
    }

    /// The fixed script exports stage, before, after, and a numeric Apple Event
    /// error only. Raw script error descriptions are neither displayed nor logged.
    static func decode(_ output: String, exitCode: Int32) -> Self {
        guard exitCode == 0, output.utf8.count <= 120 else { return .failed(.unavailable) }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let errorCode = Int(parts[3]) else { return .failed(.unavailable) }
        let before = bit(parts[1]), after = bit(parts[2])
        switch parts[0] {
        case "ok":
            guard errorCode == 0, let before, let after else { return .failed(.unavailable) }
            return .init(enabled: after, failure: before != after ? nil : .unconfirmed)
        case "read", "write", "readback":
            // Failure stages never carry an after value, even if a write may have
            // succeeded before a subsequent read was denied or interrupted.
            guard parts[2] == "?", errorCode != 0,
                  parts[0] == "read" ? parts[1] == "?" : before != nil else {
                return .failed(.unavailable)
            }
            switch errorCode {
            case -1743, -1744: return .failed(.authorizationRequired)
            case -128: return .failed(.cancelled)
            case -1712: return .failed(.timedOut)
            default: return .failed(parts[0] == "read" ? .unavailable : .unconfirmed)
            }
        default: return .failed(.unavailable)
        }
    }

    private static func bit(_ value: String) -> Bool? {
        switch value { case "0": false; case "1": true; default: nil }
    }
}
