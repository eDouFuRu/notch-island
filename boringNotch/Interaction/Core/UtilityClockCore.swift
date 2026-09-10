import Foundation

struct UtilityStopwatch: Codable, Equatable {
    var accumulated: TimeInterval = 0
    var startedAt: Date?
    var laps: [TimeInterval] = []
    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
    mutating func start(at now: Date) { if startedAt == nil { startedAt = now } }
    mutating func pause(at now: Date) { accumulated = elapsed(at: now); startedAt = nil }
    mutating func lap(at now: Date) {
        guard startedAt != nil else { return }
        laps.insert(elapsed(at: now), at: 0)
        if laps.count > 100 { laps.removeLast(laps.count - 100) }
    }
    mutating func reset() { self = Self() }
}

struct UtilityCountdown: Codable, Equatable {
    var deadline: Date?
    var pausedRemaining: TimeInterval?
    var completed = false
    var isActive: Bool { deadline != nil || pausedRemaining != nil }
    func remaining(at now: Date) -> TimeInterval {
        deadline.map { max(0, $0.timeIntervalSince(now)) } ?? pausedRemaining ?? 0
    }
    mutating func start(seconds: TimeInterval, at now: Date) -> Bool {
        guard seconds.isFinite, seconds >= 1, seconds <= 86_400 else { return false }
        deadline = now.addingTimeInterval(seconds); pausedRemaining = nil; completed = false
        return true
    }
    mutating func pause(at now: Date) {
        guard deadline != nil, !settle(at: now) else { return }
        pausedRemaining = remaining(at: now); deadline = nil
    }
    mutating func resume(at now: Date) {
        guard let remaining = pausedRemaining, remaining > 0 else { return }
        deadline = now.addingTimeInterval(remaining); pausedRemaining = nil
    }
    @discardableResult mutating func settle(at now: Date) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil; pausedRemaining = nil; completed = true
        return true
    }
    mutating func cancel() { self = Self() }
}

struct UtilityClockSnapshot: Codable, Equatable {
    var stopwatch = UtilityStopwatch()
    var countdown = UtilityCountdown()
    var alarmDate: Date?
    var alarmCompleted = false
    // Optional for compatibility with snapshots written before notifications had session IDs.
    var timerNotificationID: String?
    var alarmNotificationID: String?

    func notificationID(for kind: UtilityNotificationKind) -> String? {
        kind == .timer ? timerNotificationID : alarmNotificationID
    }
    var notificationIDs: Set<String> { Set([timerNotificationID, alarmNotificationID].compactMap { $0 }) }
    func staleNotificationIDs(in pending: [String]) -> [String] {
        let current = notificationIDs
        return pending.filter { $0.hasPrefix(UtilityNotificationKind.prefix) && !current.contains($0) }
    }

    /// Restoring the same session reuses its ID; resume/new sessions first invalidate it.
    mutating func ensureNotificationID(for kind: UtilityNotificationKind, token: String = UUID().uuidString) -> String {
        if let existing = notificationID(for: kind) { return existing }
        let id = UtilityNotificationKind.prefix + kind.rawValue + "." + token
        if kind == .timer { timerNotificationID = id } else { alarmNotificationID = id }
        return id
    }
    @discardableResult mutating func invalidateNotification(for kind: UtilityNotificationKind) -> String? {
        let old = notificationID(for: kind)
        if kind == .timer { timerNotificationID = nil } else { alarmNotificationID = nil }
        return old
    }
    @discardableResult mutating func settleAlarm(at now: Date) -> Bool {
        guard let alarmDate, now >= alarmDate else { return false }
        self.alarmDate = nil; alarmCompleted = true; return true
    }
}

enum UtilityNotificationKind: String, CaseIterable {
    case timer, alarm
    static let prefix = "island.utility."
}

enum UtilityTimerInput {
    static func duration(minutes: String, seconds: String) -> TimeInterval? {
        func integer(_ raw: String) -> Int? {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(text)
        }
        guard let minutes = integer(minutes), (0...1_440).contains(minutes),
              let seconds = integer(seconds), (0...59).contains(seconds) else { return nil }
        let duration = minutes * 60 + seconds
        return (1...86_400).contains(duration) ? Double(duration) : nil
    }
}
