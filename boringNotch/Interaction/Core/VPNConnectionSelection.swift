import Foundation

enum VPNConnectionState: String, Equatable, Sendable {
    case disconnected, connecting, connected, disconnecting, unknown

    var canRequestChange: Bool { self == .connected || self == .disconnected }
    var isTransitioning: Bool { self == .connecting || self == .disconnecting }
    var labelKey: String {
        switch self {
        case .disconnected: "VPN Disconnected"
        case .connecting: "VPN Connecting…"
        case .connected: "VPN Connected"
        case .disconnecting: "VPN Disconnecting…"
        case .unknown: "VPN Status Unknown"
        }
    }
}

struct VPNConnectionMenuItem: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let status: VPNConnectionState
    /// Disabled configurations are excluded; this does not enable a VPN type.
    var isEnabled: Bool { true }
    var canToggle: Bool { status.canRequestChange }
}

struct VPNConnectionReading: Equatable, Sendable {
    let services: [VPNConnectionMenuItem]
    /// Counts only rows actually returned by scutil. It cannot count hidden providers.
    let unsupportedServiceCount: Int
}

enum VPNConnectionFailure: String, Equatable, Sendable {
    case unavailable, malformedOutput, noServices, serviceMissing, stateChanged
    case transitionInProgress, statusUnknown, requestRejected, confirmationPending
    case timedOut, cancelled, busy

    var messageKey: String {
        switch self {
        case .unavailable: "VPN services could not be read. Refresh or open VPN settings."
        case .malformedOutput: "macOS returned an unrecognized VPN list. Open VPN settings instead."
        case .noServices: "No enabled VPN services controllable here were found. Other VPNs may require their own app."
        case .serviceMissing: "This VPN is no longer available. Refresh the list."
        case .stateChanged: "The VPN status changed since the menu opened. Refresh before trying again."
        case .transitionInProgress: "This VPN is still connecting or disconnecting. Wait for its actual status."
        case .statusUnknown: "The current VPN status could not be confirmed. No change was made."
        case .requestRejected: "macOS did not accept this VPN request. Check VPN settings or the provider app."
        case .confirmationPending: "The VPN request was sent, but the requested connection state is not confirmed. Refresh to check."
        case .timedOut: "The VPN command took too long. Its final state is unknown; refresh to check."
        case .cancelled: "VPN status checking was cancelled. A submitted connection request may still complete."
        case .busy: "A VPN request is already in progress."
        }
    }
}

/// Parses the documented `scutil --nc list` presentation conservatively. Raw
/// output, names and IDs stay in memory; no configuration/credential/status dump
/// is used. Unknown rows fail the whole parse instead of silently claiming none.
enum VPNConnectionListParser {
    static let maximumBytes = 131_072
    static let maximumServices = 128
    static let header = "Available network connection services in the current set (*=enabled):"

    static func parse(_ data: Data) -> VPNConnectionReading? {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == header,
              lines.count <= maximumServices + 1 else { return nil }
        let pattern = #"^\s*(\*)?\s*\((Invalid|Disconnected|Connecting|Connected|Disconnecting|Unknown)\)\s+([0-9A-Fa-f-]{36})\s+.+?\s+\"(.*)\"\s+\[([^\[\]\r\n]+)\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var items: [VPNConnectionMenuItem] = []
        var seen: Set<String> = []
        var unsupported = 0
        for line in lines.dropFirst() {
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  match.range.length == ns.length else { return nil }
            let id = ns.substring(with: match.range(at: 3)).uppercased()
            let name = ns.substring(with: match.range(at: 4))
            let kind = ns.substring(with: match.range(at: 5))
            guard isValidServiceID(id), seen.insert(id).inserted,
                  !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 256,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            let supportedKind = kind == "IPSec" || kind == "PPP:L2TP" ||
                (kind.hasPrefix("VPN:") && kind.count > 4) || kind == "VPN"
            guard match.range(at: 1).location != NSNotFound, supportedKind else {
                unsupported += 1
                continue
            }
            let status = VPNConnectionState(rawValue: ns.substring(with: match.range(at: 2)).lowercased()) ?? .unknown
            items.append(.init(id: id, displayName: name, status: status))
        }
        return .init(services: items, unsupportedServiceCount: unsupported)
    }

    static func isValidServiceID(_ id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return uuid.uuidString.caseInsensitiveCompare(id) == .orderedSame
    }
}

struct VPNConnectionRequest: Equatable, Sendable {
    let serviceID: String
    let connected: Bool
    let expectedStatus: VPNConnectionState
    var target: VPNConnectionState { connected ? .connected : .disconnected }
}

enum VPNConnectionCommand: Equatable, Sendable { case refresh, set(VPNConnectionRequest) }
enum VPNConnectionInvocation: Equatable, Sendable {
    case list, connect(String), disconnect(String)
    var arguments: [String]? {
        switch self {
        case .list: return ["--nc", "list"]
        case .connect(let id): return VPNConnectionListParser.isValidServiceID(id) ? ["--nc", "start", id] : nil
        case .disconnect(let id): return VPNConnectionListParser.isValidServiceID(id) ? ["--nc", "stop", id] : nil
        }
    }
}

struct VPNConnectionProcessOutput: Sendable {
    let exitCode: Int32
    let output: Data
    var timedOut = false
    var cancelled = false
    var exceededLimit = false
}

struct VPNConnectionResult: Equatable, Sendable {
    let reading: VPNConnectionReading?
    let failure: VPNConnectionFailure?
    var statusCode: Int32? = nil
    /// Acceptance only. Callers must use actual status to report completion.
    var requestAccepted = false
}

enum VPNConnectionDecision: Equatable {
    case alreadySelected, submit, fail(VPNConnectionFailure)
    static func evaluate(_ request: VPNConnectionRequest, reading: VPNConnectionReading) -> Self {
        guard VPNConnectionListParser.isValidServiceID(request.serviceID),
              let item = reading.services.first(where: { $0.id == request.serviceID }) else { return .fail(.serviceMissing) }
        guard item.status != .unknown else { return .fail(.statusUnknown) }
        // An explicit already-current target is a no-op, never a repeated start.
        if item.status == request.target { return .alreadySelected }
        guard !item.status.isTransitioning else { return .fail(.transitionInProgress) }
        guard item.status == request.expectedStatus else { return .fail(.stateChanged) }
        return .submit
    }
}

enum VPNConnectionTransaction {
    static func execute(_ command: VPNConnectionCommand,
                        run: (VPNConnectionInvocation) -> VPNConnectionProcessOutput,
                        isCancelled: () -> Bool = { false }) -> VPNConnectionResult {
        guard !isCancelled() else { return .init(reading: nil, failure: .cancelled) }
        let initial = read(run: run)
        guard case let .set(request) = command, let reading = initial.reading,
              initial.failure == nil else { return initial }
        switch VPNConnectionDecision.evaluate(request, reading: reading) {
        case .alreadySelected: return initial
        case .fail(let failure): return .init(reading: reading, failure: failure)
        case .submit: break
        }
        guard !isCancelled() else { return .init(reading: nil, failure: .cancelled) }
        let write = run(request.connected ? .connect(request.serviceID) : .disconnect(request.serviceID))
        if let failure = processFailure(write, fallback: .requestRejected) {
            // Timed-out/cancelled commands may already have reached macOS. Do
            // not perform an inverse action or an automatic write retry.
            return .init(reading: nil, failure: failure, statusCode: write.exitCode)
        }
        guard !isCancelled() else { return .init(reading: nil, failure: .cancelled, requestAccepted: true) }
        let actual = read(run: run)
        let confirmed = actual.reading?.services.first(where: { $0.id == request.serviceID })?.status == request.target
        return .init(reading: actual.reading,
                     failure: confirmed ? nil : (actual.failure ?? .confirmationPending),
                     statusCode: actual.statusCode, requestAccepted: true)
    }

    static func read(run: (VPNConnectionInvocation) -> VPNConnectionProcessOutput) -> VPNConnectionResult {
        let output = run(.list)
        if let failure = processFailure(output, fallback: .unavailable) {
            return .init(reading: nil, failure: failure, statusCode: output.exitCode)
        }
        guard let reading = VPNConnectionListParser.parse(output.output) else {
            return .init(reading: nil, failure: .malformedOutput)
        }
        return .init(reading: reading, failure: reading.services.isEmpty ? .noServices : nil)
    }

    private static func processFailure(_ output: VPNConnectionProcessOutput,
                                       fallback: VPNConnectionFailure) -> VPNConnectionFailure? {
        if output.cancelled { return .cancelled }
        if output.timedOut { return .timedOut }
        if output.exceededLimit { return .malformedOutput }
        return output.exitCode == 0 ? nil : fallback
    }
}
