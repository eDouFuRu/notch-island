import Foundation

/// Only opaque identifiers and timing survive an AX scan. Text stays in the current notice.
struct HiAXCardContent: Equatable, Sendable {
    let cardID: String
    let fingerprint: String
    /// Requires a nonempty recognized body field, not a relative timestamp or app label.
    let hasPayload: Bool
}

enum HiAXCardUpdate: Equatable, Sendable {
    case ignored
    case update(eventID: String)
    case new(eventID: String)
}

/// AX exposes UI cards, not stable notification request IDs. A reused card whose previous
/// body settled before changing is treated as another event; this is an explicit heuristic.
struct HiAXCardTracker: Sendable {
    static let settlingInterval: TimeInterval = 0.75
    static let capacity = 64
    private struct Record: Sendable {
        var fingerprint: String
        var hasPayload: Bool
        var changedAt: TimeInterval
        var lastSeenAt: TimeInterval
        var eventID: String?
    }
    private var records: [String: Record] = [:]
    private var generation: UInt64 = 0
    private let sessionID: String
    var trackedCount: Int { records.count }

    init(sessionID: String = UUID().uuidString) { self.sessionID = sessionID }

    mutating func beginBaseline(_ cards: [HiAXCardContent], now: TimeInterval) {
        records.removeAll(keepingCapacity: false)
        guard now.isFinite else { return }
        for card in cards.prefix(Self.capacity) {
            records[card.cardID] = Record(fingerprint: card.fingerprint, hasPayload: card.hasPayload,
                                          changedAt: now, lastSeenAt: now, eventID: nil)
        }
    }

    /// Incomplete/failed AX reads must not turn an old visible banner into a new event.
    mutating func reconcileVisibleCards(_ visible: Set<String>, snapshotComplete: Bool) {
        guard snapshotComplete else { return }
        records = records.filter { visible.contains($0.key) }
    }

    @discardableResult
    mutating func observe(_ card: HiAXCardContent, now: TimeInterval) -> HiAXCardUpdate {
        guard now.isFinite, !card.cardID.isEmpty, !card.fingerprint.isEmpty else { return .ignored }
        guard var old = records[card.cardID] else {
            let eventID = nextIdentity()
            records[card.cardID] = Record(fingerprint: card.fingerprint, hasPayload: card.hasPayload,
                                          changedAt: now, lastSeenAt: now, eventID: eventID)
            trim()
            return .new(eventID: eventID)
        }
        guard now >= old.lastSeenAt else { return .ignored }
        old.lastSeenAt = now
        guard old.fingerprint != card.fingerprint else {
            records[card.cardID] = old
            return .ignored
        }
        let anotherEvent = old.hasPayload && card.hasPayload && now - old.changedAt >= Self.settlingInterval
        old.fingerprint = card.fingerprint
        old.hasPayload = card.hasPayload
        old.changedAt = now
        if anotherEvent { old.eventID = nextIdentity() }
        records[card.cardID] = old
        guard let id = old.eventID else { return .ignored }
        return anotherEvent ? .new(eventID: id) : .update(eventID: id)
    }

    mutating func clear() { records.removeAll(keepingCapacity: false) }

    private mutating func nextIdentity() -> String {
        generation &+= 1
        return "\(sessionID)-\(generation)"
    }

    private mutating func trim() {
        while records.count > Self.capacity {
            guard let oldest = records.min(by: {
                $0.value.lastSeenAt == $1.value.lastSeenAt ? $0.key < $1.key : $0.value.lastSeenAt < $1.value.lastSeenAt
            })?.key else { break }
            records.removeValue(forKey: oldest)
        }
    }
}
