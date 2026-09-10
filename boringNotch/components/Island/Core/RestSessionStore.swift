import Foundation

public enum RestSessionPhase: String, Codable, Equatable {
    case idle
    case running
    case paused
    case completed
}

/// A single persisted snapshot makes completing a session and awarding its tree atomic.
public struct RestSessionState: Codable, Equatable {
    public fileprivate(set) var phase: RestSessionPhase
    public fileprivate(set) var endDate: Date?
    public fileprivate(set) var pausedRemaining: TimeInterval
    public fileprivate(set) var completedSessions: Int
    public fileprivate(set) var growthAnimationPending: Bool
    fileprivate var schemaVersion: Int

    public var hasTree: Bool { completedSessions > 0 }

    fileprivate static var initial: RestSessionState {
        RestSessionState(
            phase: .idle,
            endDate: nil,
            pausedRemaining: 0,
            completedSessions: 0,
            growthAnimationPending: false,
            schemaVersion: 1
        )
    }

    fileprivate func isValid(duration: TimeInterval) -> Bool {
        guard schemaVersion == 1,
              completedSessions >= 0,
              pausedRemaining.isFinite,
              pausedRemaining >= 0,
              pausedRemaining <= duration,
              !growthAnimationPending || hasTree else { return false }

        switch phase {
        case .idle:
            return endDate == nil && pausedRemaining == 0
        case .running:
            return endDate?.timeIntervalSinceReferenceDate.isFinite == true
        case .paused:
            return endDate == nil && pausedRemaining > 0
        case .completed:
            return endDate == nil && pausedRemaining == 0 && hasTree
        }
    }
}

public protocol RestSessionPersistence: AnyObject {
    func loadData() -> Data?
    func saveData(_ data: Data)
}

public final class UserDefaultsRestSessionPersistence: RestSessionPersistence {
    public static let defaultKey = "notchIsland.restSession.v1"
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func loadData() -> Data? { defaults.data(forKey: key) }

    public func saveData(_ data: Data) { defaults.set(data, forKey: key) }
}

/// Own from a single executor (the app uses the main actor). There is no background timer:
/// callers reconcile on their display tick, app activation, and system wake.
public final class RestSessionStore {
    public private(set) var state: RestSessionState
    public let duration: TimeInterval

    private let storage: RestSessionPersistence
    private let now: () -> Date

    public init(
        storage: RestSessionPersistence = UserDefaultsRestSessionPersistence(),
        duration: TimeInterval = 60,
        now: @escaping () -> Date = Date.init
    ) {
        // Clamp invalid injection values rather than allowing non-finite dates or timer output.
        self.duration = duration.isFinite && duration > 0 && duration <= 86_400 ? duration : 60
        self.storage = storage
        self.now = now

        let persistedData = storage.loadData()
        if let data = persistedData,
           let decoded = try? JSONDecoder().decode(RestSessionState.self, from: data),
           decoded.isValid(duration: self.duration) {
            state = decoded
        } else {
            state = .initial
            if persistedData != nil { persist() }
        }
        reconcile()
    }

    /// Rounded up so a newly started minute reads 1:00 and never becomes negative.
    public var remainingSeconds: Int {
        let remaining: TimeInterval
        switch state.phase {
        case .idle:
            remaining = duration
        case .running:
            remaining = max(0, min(duration, state.endDate?.timeIntervalSince(now()) ?? 0))
        case .paused:
            remaining = state.pausedRemaining
        case .completed:
            remaining = 0
        }
        return Int(ceil(remaining))
    }

    /// Starting twice cannot reset an active or paused rest.
    public func start() {
        reconcile()
        guard state.phase == .idle || state.phase == .completed else { return }
        state.phase = .running
        state.endDate = now().addingTimeInterval(duration)
        state.pausedRemaining = 0
        persist()
    }

    public func pause() {
        let instant = now()
        reconcile(at: instant)
        guard state.phase == .running, let endDate = state.endDate else { return }
        state.pausedRemaining = min(duration, max(0, endDate.timeIntervalSince(instant)))
        state.phase = .paused
        state.endDate = nil
        persist()
    }

    public func resume() {
        guard state.phase == .paused else { return }
        state.endDate = now().addingTimeInterval(state.pausedRemaining)
        state.phase = .running
        state.pausedRemaining = 0
        persist()
    }

    /// Cancels an unfinished rest. A rest whose deadline has passed is already complete.
    public func cancel() {
        reconcile()
        guard state.phase == .running || state.phase == .paused else { return }
        state.phase = .idle
        state.endDate = nil
        state.pausedRemaining = 0
        persist()
    }

    public func reconcile() { reconcile(at: now()) }

    /// Call when the island expands. Persist before animating so reopen/relaunch cannot replay it.
    @discardableResult
    public func consumeGrowthAnimation() -> Bool {
        reconcile()
        guard state.growthAnimationPending else { return false }
        state.growthAnimationPending = false
        persist()
        return true
    }

    private func reconcile(at instant: Date) {
        guard state.phase == .running,
              let endDate = state.endDate,
              endDate <= instant else { return }
        state.phase = .completed
        state.endDate = nil
        state.pausedRemaining = 0
        if state.completedSessions < Int.max { state.completedSessions += 1 }
        state.growthAnimationPending = true
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        storage.saveData(data)
    }
}
