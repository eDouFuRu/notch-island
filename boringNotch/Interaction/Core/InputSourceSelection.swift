import Foundation

enum KeyboardInputSourceKind: Equatable, Sendable {
    case layout, inputMethod, inputMethodParent, inputMode, other
}

/// Public input-source metadata only. No input text, keyboard layout data or key
/// events are part of this model. The stable source ID is distinct from mode ID.
struct KeyboardInputSourceRecord: Equatable, Sendable {
    let id: String
    let displayName: String
    let bundleID: String?
    let kind: KeyboardInputSourceKind
    let enabled: Bool
    let selectable: Bool
}

struct InputSourceMenuItem: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let parentName: String?
}

struct InputSourceReading: Equatable, Sendable {
    let sources: [InputSourceMenuItem]
    let selectedID: String?
    let currentName: String?

    init(records: [KeyboardInputSourceRecord], selectedID: String?, currentName: String?) {
        var seen = Set<String>()
        sources = records.compactMap { record in
            guard !record.id.isEmpty, !record.displayName.isEmpty,
                  record.enabled, record.selectable,
                  record.kind != .inputMethodParent, record.kind != .other,
                  seen.insert(record.id).inserted else { return nil }
            var parentName: String?
            if record.kind == .inputMode {
                // Modes share their parent's bundle identifier. Never infer a
                // parent by chopping a dotted source ID or by localized names.
                guard let bundle = record.bundleID, !bundle.isEmpty else { return nil }
                let parents = records.filter {
                    $0.kind == .inputMethodParent && ($0.id == bundle || $0.bundleID == bundle)
                }
                guard parents.count == 1, let parent = parents.first, parent.enabled else { return nil }
                parentName = parent.displayName == record.displayName ? nil : parent.displayName
            }
            return InputSourceMenuItem(id: record.id, displayName: record.displayName, parentName: parentName)
        }
        self.selectedID = selectedID
        self.currentName = currentName
    }

    func containsSelectableSource(_ id: String) -> Bool { sources.contains { $0.id == id } }
}

enum InputSourceFailure: Equatable, Sendable {
    case unavailable, noSources, sourceUnavailable, selectionFailed, confirmationFailed, notApplied, cancelled
    var messageKey: String {
        switch self {
        case .unavailable: "Input sources could not be read. Try again."
        case .noSources: "No enabled, selectable keyboard input sources are available."
        case .sourceUnavailable: "This input source is no longer available. Choose another source."
        case .selectionFailed: "macOS could not select this input source."
        case .confirmationFailed: "The input source was requested, but its current state could not be confirmed."
        case .notApplied: "The current input source did not change to your selection."
        case .cancelled: "Input source confirmation was cancelled. Refresh to check the current source."
        }
    }
}

enum InputSourceSelectionDecision: Equatable {
    case unavailable, alreadySelected, select
    static func evaluate(id: String, reading: InputSourceReading) -> Self {
        guard reading.containsSelectableSource(id) else { return .unavailable }
        return reading.selectedID == id ? .alreadySelected : .select
    }
}

enum InputSourceSelectionVerification {
    static func failure(requestedID: String, writeSucceeded: Bool, actual: InputSourceReading?) -> InputSourceFailure? {
        guard writeSucceeded else { return .selectionFailed }
        guard let actual, actual.selectedID != nil else { return .confirmationFailed }
        return actual.selectedID == requestedID ? nil : .notApplied
    }
}
