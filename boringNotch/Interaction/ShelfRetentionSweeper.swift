// Custom changes for 工位充电岛: shelf items expire on their own clock.
import AppKit
import Combine
import Defaults

/// Clears staged items once their retention window has lapsed.
///
/// The shelf is a staging area, so leaving it to grow forever means screenshots pile up in
/// the temporary directory indefinitely. Each item ages from when it was staged, so one
/// sweep can expire an old item and spare one added minutes earlier.
@MainActor
final class ShelfRetentionSweeper {
    static let shared = ShelfRetentionSweeper()

    /// Retention windows start at twelve hours, so the exact minute a sweep lands is
    /// immaterial; this only has to be often enough that the shelf does not look stale.
    private static let sweepInterval: TimeInterval = 300

    private var timer: Timer?
    private var observation: Set<AnyCancellable> = []
    /// `start()` is called once from the app delegate today, but the wake observer below is
    /// registered without a token and cannot be undone, so a second call would silently
    /// double every sweep from then on.
    private var hasStarted = false

    private init() {}

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        Defaults.publisher(.shelfRetention)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncTimer()
                    self?.sweepNow()
                }
            }
            .store(in: &observation)

        // A Mac that slept through the expiry would otherwise keep the item until the next
        // tick, since timers do not fire while asleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ShelfRetentionSweeper.shared.sweepNow() }
        }

        syncTimer()
        sweepNow()
    }

    func sweepNow() {
        ShelfStateViewModel.shared.sweepExpiredItems()
    }

    private func syncTimer() {
        // Switching retention off stops the timer outright rather than leaving it spinning
        // on a sweep that would do nothing.
        guard Defaults[.shelfRetention].corePolicy != .off else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { _ in
            MainActor.assumeIsolated { ShelfRetentionSweeper.shared.sweepNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
