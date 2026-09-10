import Foundation

/// A successful native toolbar may save into Screenshot.app's chosen folder
/// instead of the CLI path. Recovery is limited to one explicit capture session.
struct CaptureRecoveryPolicy: Sendable {
    static let maximumDelay: TimeInterval = 15
    enum Decision: Equatable {
        case waiting, unique(CaptureFileCandidate), ambiguous, timedOut
        case directoryChanged, interrupted, unreadable
    }

    let directory: URL
    let startedAt: Date
    let finishedAt: Date
    private let existingPaths: Set<String>
    private var observed: [String: CaptureFileCandidate] = [:]

    init(directory: URL, startedAt: Date, finishedAt: Date, existing: [CaptureFileCandidate]) {
        self.directory = directory.standardizedFileURL
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.existingPaths = Set(existing.map { $0.url.standardizedFileURL.path })
    }

    mutating func evaluate(_ candidates: [CaptureFileCandidate]?, currentDirectory: URL,
                           permitted: Bool, now: Date) -> Decision {
        guard permitted else { return .interrupted }
        guard currentDirectory.standardizedFileURL == directory else { return .directoryChanged }
        guard let candidates else { return .unreadable }
        let deadline = finishedAt.addingTimeInterval(Self.maximumDelay)
        guard now <= deadline else { return .timedOut }
        let matches = candidates.filter { candidate in
            candidate.url.isFileURL && candidate.url.deletingLastPathComponent().standardizedFileURL == directory &&
                !existingPaths.contains(candidate.url.standardizedFileURL.path) && candidate.isRegularFile &&
                !candidate.isSymbolicLink && candidate.isSystemScreenshot &&
                CaptureFilePolicy.imageExtensions.contains(candidate.url.pathExtension.lowercased()) &&
                candidate.creationDate >= startedAt && candidate.creationDate <= deadline &&
                candidate.creationDate <= now.addingTimeInterval(1)
        }
        // Do not choose a convenient candidate when more than one capture could
        // belong to this session, even if one is already imported by the observer.
        guard matches.count < 2 else { return .ambiguous }
        if let candidate = matches.first {
            let key = candidate.url.standardizedFileURL.path
            let previous = observed.updateValue(candidate, forKey: key)
            if candidate.byteCount > 0, candidate.modificationDate <= now.addingTimeInterval(-0.35),
               previous == candidate { return .unique(candidate) }
        }
        return now >= deadline ? .timedOut : .waiting
    }
}

/// Both automatic observation and explicit toolbar recovery run on MainActor;
/// checking and recording around a synchronous copy prevents duplicate cards.
struct CaptureImportLedger: Sendable {
    private struct Identity: Hashable, Sendable {
        let url: URL
        let creation: Date
        let modification: Date
        let bytes: Int64
        init(_ candidate: CaptureFileCandidate) {
            url = candidate.url.standardizedFileURL
            creation = candidate.creationDate
            modification = candidate.modificationDate
            bytes = candidate.byteCount
        }
    }
    private var identities: Set<Identity> = []
    private var order: [Identity] = []
    func contains(_ candidate: CaptureFileCandidate) -> Bool { identities.contains(Identity(candidate)) }
    mutating func recordSuccessfulImport(_ candidate: CaptureFileCandidate) {
        let identity = Identity(candidate)
        guard identities.insert(identity).inserted else { return }
        order.append(identity)
        if order.count > 2_000 { identities.remove(order.removeFirst()) }
    }
}
