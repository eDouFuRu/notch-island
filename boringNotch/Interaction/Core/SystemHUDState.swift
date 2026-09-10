import Foundation

enum SystemHUDKind: String, Equatable, Sendable {
    case volume, brightness, backlight, mic
}

/// System controls own their expiry independently of music sneak peeks and rest timers.
struct SystemHUDState: Equatable, Sendable {
    static let visibleDuration: TimeInterval = 2
    private(set) var activeKind: SystemHUDKind?
    private(set) var value: Double = 0
    private(set) var error: String?
    private(set) var icon = ""
    private(set) var expiration: TimeInterval?
    private(set) var applicationAvailable = false

    mutating func setApplicationAvailable(_ available: Bool) {
        applicationAvailable = available
        if !available { clear() }
    }

    mutating func show(kind: SystemHUDKind, value: Double, error: String? = nil,
                       icon: String = "", now: TimeInterval) {
        guard applicationAvailable, now.isFinite else { return }
        activeKind = kind
        self.value = value.isFinite ? min(1, max(0, value)) : 0
        self.error = error
        self.icon = icon
        expiration = now + Self.visibleDuration
    }

    mutating func expire(now: TimeInterval) {
        guard let expiration, now >= expiration else { return }
        clear()
    }

    mutating func clear() {
        activeKind = nil
        expiration = nil
        error = nil
        icon = ""
    }
}

/// Measurements are shared by the carrier's visible shell and the HUD's contents.
/// The physical camera gap never depends on a timer, media wing, or HUD width.
struct SystemHUDLayout: Equatable {
    static let rowHeight: CGFloat = BriefPresentationLayout.rowHeight
    static let closedInset: CGFloat = 6
    static let openInset: CGFloat = 31
    /// Sized for the tallest page (tools, three card rows) on the deepest header, plus one
    /// brief or HUD row and the shadow margin. Brief and standard HUD never stack, so a
    /// single row is the worst case. `testTallestPagePlusHUDRowStillFitsInsideCarrierWindow`
    /// pins this down: the window cannot grow at runtime, so anything taller gets clipped.
    static let carrierHeight: CGFloat = 380
    static let preferredWingWidth: CGFloat = 104

    let physicalGapWidth: CGFloat
    let headerHeight: CGFloat
    let wingWidth: CGFloat
    let size: CGSize
    let showsInline: Bool
    let showsRow: Bool

    init(active: Bool, inline: Bool, expanded: Bool, notchWidth: CGFloat,
         headerHeight: CGFloat, baseClosedSize: CGSize, baseExpandedHeight: CGFloat,
         expandedWidth: CGFloat = 640) {
        physicalGapWidth = max(0, notchWidth)
        self.headerHeight = max(24, headerHeight)
        showsInline = active && inline
        showsRow = active && !inline
        let horizontalInset = expanded ? Self.openInset : Self.closedInset
        let inlineWidth = min(expandedWidth, physicalGapWidth + 2 * Self.preferredWingWidth + 2 * horizontalInset)
        let width: CGFloat
        if expanded {
            width = expandedWidth
        } else if showsInline {
            width = inlineWidth
        } else if showsRow {
            width = min(expandedWidth, max(320, baseClosedSize.width))
        } else {
            width = baseClosedSize.width
        }
        wingWidth = max(0, (width - 2 * horizontalInset - physicalGapWidth) / 2)
        let height: CGFloat
        if expanded {
            height = baseExpandedHeight + (showsRow ? Self.rowHeight : 0)
        } else if active {
            height = self.headerHeight + (showsRow ? Self.rowHeight : 0)
        } else {
            height = baseClosedSize.height
        }
        size = CGSize(width: width, height: height)
    }
}
