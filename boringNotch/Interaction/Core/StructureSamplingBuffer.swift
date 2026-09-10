import Foundation

/// In-memory evidence for a short explicit diagnostic session, never notification history.
struct StructureSamplingBuffer: Equatable {
    struct Sample: Equatable {
        let offset: TimeInterval
        let summary: String
    }
    static let duration: TimeInterval = 30
    static let sampleLimit = 30
    static let summaryLimit = 12_000
    let startedAt: TimeInterval
    private(set) var attempts = 0
    private(set) var samples: [Sample] = []
    private var lastFingerprint: String?
    private var lastSampleTime: TimeInterval?

    init(startedAt: TimeInterval) { self.startedAt = startedAt }

    func isExpired(at now: TimeInterval) -> Bool {
        !now.isFinite || !startedAt.isFinite || now < startedAt || now - startedAt >= Self.duration || attempts >= Self.sampleLimit
    }

    @discardableResult mutating func record(at now: TimeInterval, fingerprint: String, summary: String) -> Bool {
        guard !isExpired(at: now), lastSampleTime.map({ now >= $0 }) ?? true else { return false }
        attempts += 1
        lastSampleTime = now
        let fingerprint = String(fingerprint.prefix(Self.summaryLimit))
        guard lastFingerprint != fingerprint else { return false }
        lastFingerprint = fingerprint
        samples.append(Sample(offset: now - startedAt, summary: String(summary.prefix(Self.summaryLimit))))
        return true
    }

    var summary: String {
        samples.map { String(format: "+%.1fs · ", $0.offset) + $0.summary }.joined(separator: "\n\n")
    }
}
