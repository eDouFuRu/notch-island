import Foundation

/// Visual delivery is separate from awarding a completed rest. Background tools,
/// hidden windows and the lock screen must leave the one-shot animation pending.
public struct RestPresentationState: Equatable {
    public var notchOpen: Bool
    public var isIslandPage: Bool
    public var hidden: Bool
    public var locked: Bool
    public var pageMounted: Bool

    public init(
        notchOpen: Bool = false,
        isIslandPage: Bool = true,
        hidden: Bool = false,
        locked: Bool = false,
        pageMounted: Bool = false
    ) {
        self.notchOpen = notchOpen
        self.isIslandPage = isIslandPage
        self.hidden = hidden
        self.locked = locked
        self.pageMounted = pageMounted
    }

    public var canPresentGrowth: Bool {
        notchOpen && isIslandPage && !hidden && !locked && pageMounted
    }
}

/// Every notch owns a separate presentation record. A closed external display
/// cannot overwrite the visibility of the island open on the built-in display.
public struct RestPresentationRegistry {
    public var applicationAvailable = true
    private var presentations: [UUID: RestPresentationState] = [:]
    private var mountedPages: Set<UUID> = []

    public init() {}

    public subscript(sourceID: UUID) -> RestPresentationState? { presentations[sourceID] }

    public var visibleSources: [UUID] {
        guard applicationAvailable else { return [] }
        return presentations.filter { $0.value.canPresentGrowth }.keys.sorted { $0.uuidString < $1.uuidString }
    }

    public mutating func update(sourceID: UUID, notchOpen: Bool, isIslandPage: Bool,
                                hidden: Bool, locked: Bool) {
        presentations[sourceID] = RestPresentationState(
            notchOpen: notchOpen, isIslandPage: isIslandPage, hidden: hidden, locked: locked,
            pageMounted: mountedPages.contains(sourceID)
        )
    }

    public mutating func mountPage(_ sourceID: UUID) {
        mountedPages.insert(sourceID)
        presentations[sourceID]?.pageMounted = true
    }

    public mutating func unmountPage(_ sourceID: UUID) {
        mountedPages.remove(sourceID)
        presentations[sourceID]?.pageMounted = false
    }

    public mutating func remove(sourceID: UUID) {
        presentations.removeValue(forKey: sourceID)
        mountedPages.remove(sourceID)
    }

    /// Window teardown cannot wait for SwiftUI's deferred disappearance callbacks.
    /// Rebuilt windows must report both their state and an actual page mount again.
    public mutating func clearForWindowRebuild() {
        applicationAvailable = false
        presentations.removeAll()
        mountedPages.removeAll()
    }
}

extension RestSessionStore {
    /// Keep the original persistence schema and consume API intact for migration.
    @discardableResult
    public func consumeGrowthAnimation(when presentation: RestPresentationState) -> Bool {
        guard presentation.canPresentGrowth else { return false }
        return consumeGrowthAnimation()
    }
}
