import Foundation

public enum PotatoSessionMode: String, Codable, CaseIterable { case rest, focus }

/// Inventory and credited cycles share a snapshot: recovery cannot credit the same minute twice.
public struct PotatoSessionState: Codable, Equatable {
    public fileprivate(set) var schemaVersion = 2
    public fileprivate(set) var mode: PotatoSessionMode = .rest
    public fileprivate(set) var phase: RestSessionPhase = .idle
    public fileprivate(set) var restDurationMinutes = 1
    public fileprivate(set) var focusDurationMinutes = 25
    public fileprivate(set) var sessionDuration: TimeInterval = 60
    public fileprivate(set) var endDate: Date?
    public fileprivate(set) var pausedRemaining: TimeInterval = 0
    public fileprivate(set) var creditedRestCycles = 0
    public fileprivate(set) var potatoCount = 0
    public fileprivate(set) var pendingHarvestCount = 0
    public fileprivate(set) var pendingFocusReminder = false

    fileprivate var isValid: Bool {
        guard schemaVersion == 2,
              (1...120).contains(restDurationMinutes), (1...120).contains(focusDurationMinutes),
              sessionDuration.isFinite, (60...7_200).contains(sessionDuration),
              sessionDuration.truncatingRemainder(dividingBy: 60) == 0,
              pausedRemaining.isFinite, pausedRemaining >= 0, pausedRemaining <= sessionDuration,
              potatoCount >= 0, pendingHarvestCount >= 0,
              creditedRestCycles >= 0, creditedRestCycles <= Int(sessionDuration / 60),
              mode == .rest || creditedRestCycles == 0 else { return false }
        switch phase {
        case .idle: return endDate == nil && pausedRemaining == 0 && creditedRestCycles == 0
        case .running: return endDate?.timeIntervalSinceReferenceDate.isFinite == true && pausedRemaining == 0
        case .paused: return endDate == nil && pausedRemaining > 0
        case .completed:
            return endDate == nil && pausedRemaining == 0 && (mode == .focus || creditedRestCycles == Int(sessionDuration / 60))
        }
    }
}

public final class PotatoSessionStore {
    public static let defaultKey = "notchIsland.potatoSession.v2"
    public private(set) var state: PotatoSessionState
    private let storage: RestSessionPersistence
    private let now: () -> Date

    public init(
        storage: RestSessionPersistence = UserDefaultsRestSessionPersistence(key: PotatoSessionStore.defaultKey),
        legacyStorage: RestSessionPersistence? = UserDefaultsRestSessionPersistence(),
        now: @escaping () -> Date = Date.init
    ) {
        self.storage = storage
        self.now = now
        if let data = storage.loadData() {
            // Existing v2 owns inventory, even when corrupt. Never resurrect spent stock from v1.
            if let decoded = try? JSONDecoder().decode(PotatoSessionState.self, from: data), decoded.isValid {
                state = decoded
            } else {
                state = PotatoSessionState()
                persist()
            }
        } else {
            state = Self.migrate(legacyStorage?.loadData()) ?? PotatoSessionState()
            persist()
        }
        reconcile()
    }

    public var durationMinutes: Int {
        state.phase == .running || state.phase == .paused ? Int(state.sessionDuration / 60) : configuredMinutes
    }
    public var duration: TimeInterval { TimeInterval(durationMinutes * 60) }
    public var remainingSeconds: Int { Int(ceil(remaining(at: now()))) }
    public var elapsedSeconds: TimeInterval { state.phase == .idle ? 0 : max(0, state.sessionDuration - remaining(at: now())) }
    public var progress: Double { min(1, max(0, elapsedSeconds / state.sessionDuration)) }
    public var focusBitesTaken: Int { state.mode == .focus ? min(6, Int(floor(progress * 6))) : 0 }
    private var configuredMinutes: Int { state.mode == .rest ? state.restDurationMinutes : state.focusDurationMinutes }

    @discardableResult public func selectMode(_ mode: PotatoSessionMode) -> Bool {
        reconcile()
        guard state.phase != .running && state.phase != .paused else { return false }
        state.mode = mode
        state.pendingFocusReminder = false
        resetSession()
        persist()
        return true
    }
    public func setDurationMinutes(_ minutes: Int) {
        if state.mode == .rest { setRestDurationMinutes(minutes) } else { setFocusDurationMinutes(minutes) }
    }
    public func setRestDurationMinutes(_ minutes: Int) {
        state.restDurationMinutes = min(120, max(1, minutes))
        if state.phase == .idle && state.mode == .rest { state.sessionDuration = TimeInterval(configuredMinutes * 60) }
        persist()
    }
    public func setFocusDurationMinutes(_ minutes: Int) {
        state.focusDurationMinutes = min(120, max(1, minutes))
        if state.phase == .idle && state.mode == .focus { state.sessionDuration = TimeInterval(configuredMinutes * 60) }
        persist()
    }
    public func start() {
        reconcile()
        guard state.phase == .idle || state.phase == .completed else { return }
        state.pendingFocusReminder = false
        state.sessionDuration = TimeInterval(configuredMinutes * 60)
        state.phase = .running
        state.endDate = now().addingTimeInterval(state.sessionDuration)
        state.pausedRemaining = 0
        state.creditedRestCycles = 0
        persist()
    }
    public func pause() {
        let instant = now()
        reconcile(at: instant)
        guard state.phase == .running else { return }
        state.pausedRemaining = remaining(at: instant)
        state.endDate = nil
        state.phase = .paused
        persist()
    }
    public func resume() {
        guard state.phase == .paused else { return }
        state.endDate = now().addingTimeInterval(state.pausedRemaining)
        state.pausedRemaining = 0
        state.phase = .running
        persist()
    }
    public func cancel() {
        reconcile()
        guard state.phase == .running || state.phase == .paused else { return }
        resetSession()
        persist()
    }
    public func reconcile() { reconcile(at: now()) }

    /// Inventory is already credited. The presentation layer gates visual delivery.
    @discardableResult public func consumeHarvest() -> Int {
        reconcile()
        let count = state.pendingHarvestCount
        guard count > 0 else { return 0 }
        state.pendingHarvestCount = 0
        persist()
        return count
    }
    @discardableResult public func consumeHarvest(when presentation: RestPresentationState) -> Int {
        guard state.mode == .rest, presentation.canPresentGrowth else { return 0 }
        return consumeHarvest()
    }
    @discardableResult public func consumeFocusReminder() -> Bool {
        reconcile()
        guard state.pendingFocusReminder else { return false }
        state.pendingFocusReminder = false
        persist()
        return true
    }
    private func remaining(at instant: Date) -> TimeInterval {
        switch state.phase {
        case .idle: return TimeInterval(configuredMinutes * 60)
        case .running: return min(state.sessionDuration, max(0, state.endDate?.timeIntervalSince(instant) ?? 0))
        case .paused: return state.pausedRemaining
        case .completed: return 0
        }
    }
    private func resetSession() {
        state.phase = .idle
        state.endDate = nil
        state.pausedRemaining = 0
        state.creditedRestCycles = 0
        state.sessionDuration = TimeInterval(configuredMinutes * 60)
    }
    private func reconcile(at instant: Date) {
        guard state.phase == .running, let endDate = state.endDate else { return }
        var changed = false
        if state.mode == .rest {
            let elapsed = state.sessionDuration - remaining(at: instant)
            let cycles = min(Int(state.sessionDuration / 60), Int(floor(elapsed / 60)))
            let newlyCompleted = max(0, cycles - state.creditedRestCycles)
            if newlyCompleted > 0 {
                state.creditedRestCycles = cycles
                state.potatoCount = Self.addClamped(state.potatoCount, newlyCompleted)
                state.pendingHarvestCount = Self.addClamped(state.pendingHarvestCount, newlyCompleted)
                changed = true
            }
        }
        if endDate <= instant {
            state.phase = .completed
            state.endDate = nil
            state.pausedRemaining = 0
            if state.mode == .focus {
                state.potatoCount = max(0, state.potatoCount - 1)
                state.pendingFocusReminder = true
            }
            changed = true
        }
        if changed { persist() }
    }
    private static func addClamped(_ value: Int, _ addition: Int) -> Int {
        value > Int.max - addition ? Int.max : value + addition
    }
    private func persist() { if let data = try? JSONEncoder().encode(state) { storage.saveData(data) } }

    private struct LegacySnapshot: Decodable {
        let schemaVersion: Int
        let phase: RestSessionPhase
        let endDate: Date?
        let pausedRemaining: TimeInterval
        let completedSessions: Int
        let growthAnimationPending: Bool
    }
    private static func migrate(_ data: Data?) -> PotatoSessionState? {
        guard let data, let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data),
              legacy.schemaVersion == 1, legacy.completedSessions >= 0,
              legacy.pausedRemaining.isFinite, (0...60).contains(legacy.pausedRemaining),
              !legacy.growthAnimationPending || legacy.completedSessions > 0 else { return nil }
        switch legacy.phase {
        case .running: guard legacy.endDate?.timeIntervalSinceReferenceDate.isFinite == true else { return nil }
        case .paused: guard legacy.endDate == nil, legacy.pausedRemaining > 0 else { return nil }
        case .idle: guard legacy.endDate == nil, legacy.pausedRemaining == 0 else { return nil }
        case .completed: guard legacy.endDate == nil, legacy.pausedRemaining == 0, legacy.completedSessions > 0 else { return nil }
        }
        var migrated = PotatoSessionState()
        migrated.phase = legacy.phase
        migrated.endDate = legacy.endDate
        migrated.pausedRemaining = legacy.phase == .paused ? legacy.pausedRemaining : 0
        migrated.potatoCount = legacy.completedSessions
        migrated.pendingHarvestCount = legacy.growthAnimationPending ? 1 : 0
        migrated.creditedRestCycles = legacy.phase == .completed ? 1 : 0
        return migrated
    }
}
