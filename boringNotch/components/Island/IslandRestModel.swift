import AppKit
import Combine
import Foundation

/// One app-lifetime timer shared by the island page and all notch windows.
@MainActor
final class IslandRestModel: ObservableObject {
    static let shared = IslandRestModel()

    @Published private(set) var phase: RestSessionPhase = .idle
    @Published private(set) var mode: PotatoSessionMode = .rest
    @Published private(set) var remainingSeconds = 60
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var durationMinutes = 1
    @Published private(set) var restDurationMinutes = 1
    @Published private(set) var focusDurationMinutes = 25
    @Published private(set) var potatoCount = 0
    @Published private(set) var focusBitesTaken = 0
    @Published private(set) var pendingHarvestCount = 0
    @Published private(set) var pendingFocusReminder = false
    @Published private(set) var hasTree = false
    @Published private(set) var growthAnimationSourceID: UUID?
    @Published private(set) var harvestAnimationID: UUID?
    @Published private(set) var harvestAnimationCount = 0

    private let store: PotatoSessionStore
    private var presentations = RestPresentationRegistry()
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []

    init(store: PotatoSessionStore = PotatoSessionStore()) {
        self.store = store
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    deinit {
        ticker?.invalidate()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    var clockText: String {
        String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    var progress: Double {
        store.progress
    }
    var restCycleProgress: Double { elapsedSeconds.truncatingRemainder(dividingBy: 60) / 60 }
    var harvestAnimationSourceID: UUID? { growthAnimationSourceID }

    /// Synchronous app-wide gate closes before windows are hidden or the screen
    /// locks; no display tick can consume growth while SwiftUI catches up.
    func setApplicationAvailable(_ available: Bool) {
        presentations.applicationAvailable = available
        refresh()
    }

    /// The window coordinator calls this whenever any presentation condition changes.
    /// It does not affect the rest deadline or pause a running session.
    func setPresentation(sourceID: UUID, notchOpen: Bool, isIslandPage: Bool, hidden: Bool, locked: Bool) {
        presentations.update(sourceID: sourceID, notchOpen: notchOpen, isIslandPage: isIslandPage,
                             hidden: hidden, locked: locked)
        refresh(preferredSourceID: sourceID)
    }

    func removePresentation(sourceID: UUID) {
        presentations.remove(sourceID: sourceID)
        clearInvisibleAnimation()
    }

    /// The app calls this synchronously before removing any hosting views. This
    /// only resets presentation bookkeeping; the stored rest and its ticker survive.
    func clearPresentationsForWindowRebuild() {
        presentations.clearForWindowRebuild()
        clearHarvestAnimation()
    }

    func mountPage(_ identifier: UUID) {
        presentations.mountPage(identifier)
        refresh(preferredSourceID: identifier)
    }

    func unmountPage(_ identifier: UUID) {
        presentations.unmountPage(identifier)
        clearInvisibleAnimation()
    }

    @discardableResult func selectMode(_ mode: PotatoSessionMode) -> Bool {
        let accepted = store.selectMode(mode)
        refresh()
        return accepted
    }
    func setDurationMinutes(_ minutes: Int) { store.setDurationMinutes(minutes); refresh() }
    func setRestDurationMinutes(_ minutes: Int) { store.setRestDurationMinutes(minutes); refresh() }
    func setFocusDurationMinutes(_ minutes: Int) { store.setFocusDurationMinutes(minutes); refresh() }
    func start() { clearHarvestAnimation(); store.start(); refresh() }
    func pause() { store.pause(); refresh() }
    func resume() { store.resume(); refresh() }
    func cancel() { store.cancel(); refresh() }

    @discardableResult func consumeFocusReminder() -> Bool {
        let consumed = store.consumeFocusReminder()
        refresh()
        return consumed
    }

    func refresh(preferredSourceID: UUID? = nil) {
        store.reconcile()
        let snapshot = store.state
        if phase != snapshot.phase { phase = snapshot.phase }
        if mode != snapshot.mode { mode = snapshot.mode }
        if remainingSeconds != store.remainingSeconds { remainingSeconds = store.remainingSeconds }
        if elapsedSeconds != store.elapsedSeconds { elapsedSeconds = store.elapsedSeconds }
        if durationMinutes != store.durationMinutes { durationMinutes = store.durationMinutes }
        if restDurationMinutes != snapshot.restDurationMinutes { restDurationMinutes = snapshot.restDurationMinutes }
        if focusDurationMinutes != snapshot.focusDurationMinutes { focusDurationMinutes = snapshot.focusDurationMinutes }
        if potatoCount != snapshot.potatoCount { potatoCount = snapshot.potatoCount }
        if focusBitesTaken != store.focusBitesTaken { focusBitesTaken = store.focusBitesTaken }
        if pendingFocusReminder != snapshot.pendingFocusReminder { pendingFocusReminder = snapshot.pendingFocusReminder }
        if hasTree != (snapshot.potatoCount > 0) { hasTree = snapshot.potatoCount > 0 }
        clearInvisibleAnimation()
        let visibleSources = presentations.visibleSources
        let sourceID = preferredSourceID.flatMap { visibleSources.contains($0) ? $0 : nil } ?? visibleSources.first
        if let sourceID, let presentation = presentations[sourceID], snapshot.pendingHarvestCount > 0 {
            let count = store.consumeHarvest(when: presentation)
            if count > 0 {
                growthAnimationSourceID = sourceID
                harvestAnimationCount = count
                harvestAnimationID = UUID()
            }
        }
        if pendingHarvestCount != store.state.pendingHarvestCount { pendingHarvestCount = store.state.pendingHarvestCount }

        if phase == .running, ticker == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            timer.tolerance = 0.08
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else if phase != .running {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func clearInvisibleAnimation() {
        if let sourceID = growthAnimationSourceID, !presentations.visibleSources.contains(sourceID) {
            clearHarvestAnimation()
        }
    }
    private func clearHarvestAnimation() {
        growthAnimationSourceID = nil
        harvestAnimationID = nil
        harvestAnimationCount = 0
    }
}
