import CoreGraphics

/// When more than one banner card is alive in the same window, only one can be mirrored.
public enum BannerCardSelection {
    /// Accessibility reports positions with the origin at the top-left of the display, so the card
    /// drawn highest on screen — the newest one — has the smallest y. Ties fall back to the
    /// leftmost card and then to the original order, so the choice never depends on set iteration.
    public static func topmostIndex(positions: [CGPoint?]) -> Int? {
        var best: (index: Int, point: CGPoint)?
        for (index, position) in positions.enumerated() {
            guard let position, position.x.isFinite, position.y.isFinite else { continue }
            guard let current = best else { best = (index, position); continue }
            if position.y < current.point.y || (position.y == current.point.y && position.x < current.point.x) {
                best = (index, position)
            }
        }
        // A single unreadable card is still the only candidate; refusing it would drop the message.
        if best == nil, positions.count == 1 { return 0 }
        return best?.index
    }
}
