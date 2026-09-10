import Foundation

struct AudioOutputDeviceRecord: Equatable, Sendable {
    let objectID: UInt32
    let uid: String
    let displayName: String
    let outputChannels: Int
    let isAlive: Bool
    let canBeDefault: Bool
}

struct AudioOutputMenuItem: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
}

struct AudioOutputReading: Equatable, Sendable {
    let devices: [AudioOutputMenuItem]
    let selectedID: String?
    let currentName: String?
    let canSelect: Bool

    init(records: [AudioOutputDeviceRecord], selectedObjectID: UInt32?, defaultIsSettable: Bool) {
        let eligible = records.filter { $0.objectID != 0 && !$0.uid.isEmpty && !$0.displayName.isEmpty &&
            $0.outputChannels > 0 && $0.isAlive && $0.canBeDefault }
        // UIDs are opaque. Reject ambiguous identities instead of picking one
        // by name or a reused AudioObjectID after a device reconnects.
        let counts = Dictionary(grouping: eligible, by: \.uid).mapValues(\.count)
        devices = eligible.filter { counts[$0.uid] == 1 }.map { .init(id: $0.uid, displayName: $0.displayName) }
        let current = records.filter { $0.objectID == selectedObjectID && $0.outputChannels > 0 && $0.isAlive }
        if current.count == 1, let item = current.first, !item.uid.isEmpty {
            selectedID = item.uid
            currentName = item.displayName.isEmpty ? nil : item.displayName
        } else { selectedID = nil; currentName = nil }
        canSelect = defaultIsSettable && !devices.isEmpty
    }
    func contains(_ id: String) -> Bool { devices.contains { $0.id == id } }
}

enum AudioOutputFailure: Equatable, Sendable {
    case unavailable, noDevices, readOnly, deviceUnavailable, writeFailed, unconfirmed, notApplied, timedOut, cancelled
    var messageKey: String {
        switch self {
        case .unavailable: "Audio output devices could not be read. Try again."
        case .noDevices: "No available audio output devices were found."
        case .readOnly: "macOS does not currently allow changing the default audio output."
        case .deviceUnavailable: "This audio output is no longer available. Choose another device."
        case .writeFailed: "macOS could not change the audio output device."
        case .unconfirmed: "The audio output was requested, but its current state could not be confirmed."
        case .notApplied: "The default audio output did not change to your selection."
        case .timedOut: "The audio device took too long to respond. Refresh to check the current output."
        case .cancelled: "Audio output confirmation was cancelled. Refresh to check the current output."
        }
    }
}

enum AudioOutputSelectionDecision: Equatable {
    case unavailable, readOnly, alreadySelected, select
    static func evaluate(id: String, reading: AudioOutputReading) -> Self {
        guard reading.contains(id) else { return .unavailable }
        if reading.selectedID == id { return .alreadySelected }
        return reading.canSelect ? .select : .readOnly
    }
}

struct AudioOutputDeviceResponse: Sendable {
    var reading: AudioOutputReading?
    var failure: AudioOutputFailure?
    var statusCode: Int32?
    init(reading: AudioOutputReading? = nil, failure: AudioOutputFailure? = nil, statusCode: Int32? = nil) {
        self.reading = reading; self.failure = failure; self.statusCode = statusCode
    }
}

enum AudioOutputVerification {
    static func failure(requestedID: String, actual: AudioOutputReading?) -> AudioOutputFailure? {
        guard let actual, actual.selectedID != nil else { return .unconfirmed }
        return actual.selectedID == requestedID ? nil : .notApplied
    }
}

/// A cancelled/timed-out queued HAL operation must not execute later. A HAL call
/// already in progress cannot be interrupted; its late result is discarded and
/// the UI receives an explicit unknown/failure state, never assumed success.
final class AudioOutputRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var finished = false
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !started, !finished else { return false }
        started = true; return true
    }
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true; return true
    }
}
