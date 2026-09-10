import Foundation

/// Capturing temporarily hides the island's own windows; it is not a user's
/// request to stop receiving files. Only the explicit setting, manual hide and
/// screen/session availability delimit an external screenshot observation epoch.
struct CaptureObservationState: Equatable, Sendable {
    enum Gate: String, Equatable, Sendable {
        case disabled, manuallyHidden = "island hidden"
        case screenUnavailable = "screen unavailable", observing
    }

    private(set) var gate: Gate = .disabled
    private(set) var beganAt: Date?

    @discardableResult
    mutating func update(enabled: Bool, manuallyHidden: Bool, screenUnavailable: Bool,
                         captureInProgress _: Bool, at now: Date) -> Bool {
        let next: Gate
        if !enabled { next = .disabled }
        else if manuallyHidden { next = .manuallyHidden }
        else if screenUnavailable { next = .screenUnavailable }
        else { next = .observing }
        guard next != gate else { return false }
        gate = next
        beganAt = next == .observing ? now : nil
        return true
    }
}

enum CaptureToolKind: String, CaseIterable, Sendable {
    case fullScreenshot, areaScreenshot, windowScreenshot, customScreenshot
    case fullRecording, areaRecording, customRecording

    var recordsVideo: Bool {
        switch self {
        case .fullRecording, .areaRecording, .customRecording: return true
        default: return false
        }
    }

    var isInteractive: Bool { self != .fullScreenshot && self != .fullRecording }
    var usesSystemToolbar: Bool { self == .customScreenshot }

    /// Fixed executable + argument vector; neither shell interpolation nor user
    /// controlled switches are accepted. Never use -u/-p: they ignore our output.
    func arguments(output: URL, region: CaptureRegion? = nil) -> [String] {
        let switches: [String]
        switch self {
        case .fullScreenshot: switches = ["-x", "-D", "1", "-t", "png"]
        case .areaScreenshot: switches = ["-x", "-i", "-s", "-t", "png"]
        case .windowScreenshot: switches = ["-x", "-i", "-w", "-t", "png"]
        case .customScreenshot: switches = ["-x", "-i", "-U", "-J", "selection", "-t", "png"]
        case .fullRecording: switches = ["-v", "-D", "1"]
        case .areaRecording:
            // Interactive video (-v -i) is rejected by the native utility.
            // Only our explicit, single-display selection supplies this rect.
            guard let region else { return [] }
            switches = ["-v", "-R", region.argument]
        case .customRecording: return [] // ScreenCaptureKit owns this mode; never launch the CLI.
        }
        return switches + [output.path]
    }
}

/// Pure metadata gate shared by filesystem observation and its tests. It never
/// infers a screenshot from a filename, and never follows a symbolic link.
struct CaptureFileCandidate: Equatable, Sendable {
    let url: URL
    let creationDate: Date
    let modificationDate: Date
    let byteCount: Int64
    let isRegularFile: Bool
    let isSymbolicLink: Bool
    let isSystemScreenshot: Bool
}

struct CaptureFilePolicy: Sendable {
    private(set) var startedAt: Date
    private(set) var directory: URL
    private var imported: Set<String> = []
    private var observations: [String: CaptureFileCandidate] = [:]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif"]

    init(directory: URL, startedAt: Date) {
        self.directory = directory.standardizedFileURL
        self.startedAt = startedAt
    }

    mutating func readyToImport(_ candidate: CaptureFileCandidate, now: Date) -> Bool {
        guard candidate.url.isFileURL,
              candidate.url.deletingLastPathComponent().standardizedFileURL == directory,
              candidate.isRegularFile, !candidate.isSymbolicLink,
              candidate.isSystemScreenshot, candidate.byteCount > 0,
              candidate.creationDate >= startedAt,
              candidate.creationDate <= now.addingTimeInterval(1),
              candidate.modificationDate <= now.addingTimeInterval(-0.35),
              Self.imageExtensions.contains(candidate.url.pathExtension.lowercased()) else { return false }
        let key = candidate.url.standardizedFileURL.path
        guard !imported.contains(key) else { return false }
        let previous = observations.updateValue(candidate, forKey: key)
        // Wait for two unchanged observations so a partially written image is
        // not copied. Failed imports are retried, successful imports only once.
        return previous == candidate
    }

    mutating func markImported(_ candidate: CaptureFileCandidate) {
        let key = candidate.url.standardizedFileURL.path
        imported.insert(key)
        observations.removeValue(forKey: key)
        if imported.count > 2_000 {
            // Advance the lower bound before pruning, so prior screenshots
            // cannot replay after a long-running session.
            startedAt = max(startedAt, candidate.creationDate)
            imported = [key]
            observations = observations.filter { $0.value.creationDate >= startedAt }
        }
    }
}
