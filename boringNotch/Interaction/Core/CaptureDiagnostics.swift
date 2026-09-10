import Foundation

/// Diagnostics are intentionally content-free and held only in memory. Never add
/// file paths, capture names, raw stderr, window titles, or clipboard data here.
enum CaptureErrorCategory: String, Equatable, Sendable {
    case none, cancelled, permission, captureFailure, launchFailure, other

    static func classify(_ stderr: String) -> Self {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty { return .none }
        if text.contains("permission") || text.contains("not authorized") || text.contains("denied") {
            return .permission
        }
        if text.contains("cancel") { return .cancelled }
        if text.contains("could not create image") || text.contains("failed") || text.contains("unable") {
            return .captureFailure
        }
        return .other
    }
}

enum CaptureOutputClassification: String, Equatable, Sendable {
    case notChecked, absent, empty, image, video, invalid
}

struct CaptureProcessDiagnostic: Equatable, Sendable {
    var kind: CaptureToolKind?
    var backend = "screencapture"
    var nativeErrorCode: Int?
    var cancellation = "none"
    var phase = "idle"
    var startedAt: Date?
    var endedAt: Date?
    var exitCode: Int32?
    var userRequestedStop = false
    var output: CaptureOutputClassification = .notChecked
    var error: CaptureErrorCategory = .none
    var imported = false
    var importMethod = "none"
    var recovery = "not attempted"

    var summary: String {
        ["Capture kind: \(kind?.rawValue ?? "none")",
         "Backend: \(backend)",
         "Native error code: \(nativeErrorCode.map(String.init) ?? "none")",
         "Cancellation source: \(cancellation)",
         "Phase: \(phase)",
         "Exit code: \(exitCode.map(String.init) ?? "not received")",
         "User requested stop: \(userRequestedStop)",
         "Output classification: \(output.rawValue)",
         "Error category: \(error.rawValue)",
         "Imported: \(imported)",
         "Import method: \(importMethod)",
         "Toolbar recovery: \(recovery)",
         "Started: \(startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
         "Finished: \(endedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")"].joined(separator: "\n")
    }
}

struct CaptureImportDiagnostic: Equatable, Sendable {
    var gate = "not started"
    var startedAt: Date?
    var lastScanAt: Date?
    var directoryReadable: Bool?
    var candidates = 0
    var stableCandidates = 0
    var importedThisScan = 0

    var summary: String {
        ["Screenshot observer: \(gate)",
         "Observing since: \(startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
         "Last scan: \(lastScanAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
         "Directory readable: \(directoryReadable.map(String.init) ?? "not checked")",
         "Candidate files: \(candidates)",
         "Stable candidates: \(stableCandidates)",
         "Imported this scan: \(importedThisScan)"].joined(separator: "\n")
    }
}
