import Foundation

enum BriefPresentationSource: Equatable, Sendable {
    case none, hud, hi, songChange, lyric

    var usesBriefRow: Bool {
        self == .hi || self == .songChange || self == .lyric
    }
}

/// Only opaque event IDs and presentation deadlines. Source content, burst
/// counting and HUD lifetime remain owned by their respective managers.
struct BriefPresentationState: Equatable, Sendable {
    static let hiDuration: TimeInterval = 5
    static let songDuration: TimeInterval = 1.5

    struct Peek: Equatable, Sendable {
        let id: String
        var expiration: TimeInterval
    }

    private(set) var applicationAvailable = false
    private(set) var hi: Peek?
    private(set) var songChange: Peek?
    private(set) var isHovered = false
    private var heldHiRemaining: TimeInterval?
    private var lastHiID: String?
    private var lastSongID: String?

    /// Keep consumed IDs across hiding so republishing the same source object
    /// cannot replay a dismissed, expired or hidden peek after resumption.
    mutating func setApplicationAvailable(_ available: Bool) {
        applicationAvailable = available
        if !available { clear() }
    }

    mutating func receiveHi(id: String, now: TimeInterval, duration: TimeInterval = hiDuration) {
        guard now.isFinite, !id.isEmpty, id != lastHiID else { return }
        lastHiID = id
        expire(now: now)
        guard applicationAvailable, let deadline = deadline(now: now, duration: duration) else { return }
        hi = Peek(id: id, expiration: deadline)
        heldHiRemaining = isHovered ? duration : nil
    }

    mutating func receiveSongChange(id: String, now: TimeInterval, duration: TimeInterval = songDuration) {
        guard now.isFinite, !id.isEmpty, id != lastSongID else { return }
        lastSongID = id
        expire(now: now)
        guard applicationAvailable, let deadline = deadline(now: now, duration: duration) else { return }
        songChange = Peek(id: id, expiration: deadline)
    }

    /// The caller supplies hover of the actual hi row, not the entire island.
    /// Call false when a HUD replaces that row or the row leaves the hierarchy.
    mutating func setHovered(_ hovered: Bool, now: TimeInterval) {
        guard now.isFinite else { return }
        expire(now: now)
        let hovered = hovered && applicationAvailable && hi != nil
        guard hovered != isHovered else { return }
        isHovered = hovered
        if hovered, let hi {
            heldHiRemaining = max(0, hi.expiration - now)
        } else {
            if let remaining = heldHiRemaining, var hi {
                hi.expiration = now + remaining
                self.hi = hi
            }
            heldHiRemaining = nil
            expire(now: now)
        }
    }

    mutating func expire(now: TimeInterval) {
        guard now.isFinite else { return }
        if let hi, heldHiRemaining == nil, now >= hi.expiration { dismissHi() }
        if let songChange, now >= songChange.expiration { self.songChange = nil }
    }

    mutating func dismissHi() {
        hi = nil
        heldHiRemaining = nil
        isHovered = false
    }

    mutating func dismissSongChange() { songChange = nil }

    mutating func clear() {
        dismissHi()
        dismissSongChange()
    }

    /// A held hi has no timer deadline, while an obscured song still expires.
    var nextDeadline: TimeInterval? {
        [heldHiRemaining == nil ? hi?.expiration : nil, songChange?.expiration]
            .compactMap { $0 }.min()
    }

    func selection(now: TimeInterval, hudActive: Bool, hiEnabled: Bool = true,
                   songEnabled: Bool = true, lyricAvailable: Bool = false) -> BriefPresentationSource {
        guard applicationAvailable, now.isFinite else { return .none }
        if hudActive { return .hud }
        if hiEnabled, let hi, heldHiRemaining != nil || now < hi.expiration { return .hi }
        if songEnabled, let songChange, now < songChange.expiration { return .songChange }
        return lyricAvailable ? .lyric : .none
    }

    private func deadline(now: TimeInterval, duration: TimeInterval) -> TimeInterval? {
        guard duration.isFinite, duration > 0, (now + duration).isFinite else { return nil }
        return now + duration
    }
}

/// The brief occupies one independent row without shrinking an expanded page.
/// The standard HUD uses this same compact height; never add both rows.
struct BriefPresentationLayout: Equatable {
    static let rowHeight: CGFloat = 28
    /// An application notice carries a sender and a message, so the closed shell has to be
    /// wider than the physical notch or the row degrades into an ellipsis after a few glyphs.
    static let noticeMinimumWidth: CGFloat = 420

    let size: CGSize
    let rowTopInset: CGFloat
    let addedHeight: CGFloat
    let showsBrief: Bool

    init(active: Bool, standardHUD: Bool, expanded: Bool, baseClosedSize: CGSize,
         baseExpandedHeight: CGFloat = 250, headerHeight: CGFloat,
         minimumBriefWidth: CGFloat = 0, maximumWidth: CGFloat = 640,
         expandedWidth: CGFloat = 640) {
        func nonnegative(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
        showsBrief = active && !standardHUD
        addedHeight = showsBrief ? Self.rowHeight : 0
        let maximum = nonnegative(maximumWidth)
        if expanded {
            size = CGSize(width: min(maximum, nonnegative(expandedWidth)),
                          height: nonnegative(baseExpandedHeight) + addedHeight)
            rowTopInset = nonnegative(headerHeight)
        } else {
            let baseWidth = nonnegative(baseClosedSize.width)
            size = CGSize(width: showsBrief ? min(maximum, max(baseWidth, nonnegative(minimumBriefWidth))) : baseWidth,
                          height: nonnegative(baseClosedSize.height) + addedHeight)
            rowTopInset = nonnegative(baseClosedSize.height)
        }
    }
}

/// Global AppKit coordinates have their origin at the bottom left. The brief's
/// top inset is measured downward from the visible shell's top edge.
enum BriefInteractionRegion {
    static func rowRect(visibleRect: CGRect, rowTopInset: CGFloat,
                        height: CGFloat = BriefPresentationLayout.rowHeight) -> CGRect {
        guard !visibleRect.isNull, !visibleRect.isInfinite,
              [visibleRect.minX, visibleRect.minY, visibleRect.width, visibleRect.height,
               rowTopInset, height].allSatisfy(\.isFinite),
              visibleRect.width > 0, visibleRect.height > 0, rowTopInset >= 0, height > 0 else { return .null }
        return CGRect(x: visibleRect.minX, y: visibleRect.maxY - rowTopInset - height,
                      width: visibleRect.width, height: height).intersection(visibleRect)
    }

    static func contains(_ point: CGPoint, visibleRect: CGRect, rowTopInset: CGFloat,
                         height: CGFloat = BriefPresentationLayout.rowHeight) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        return rowRect(visibleRect: visibleRect, rowTopInset: rowTopInset, height: height).contains(point)
    }
}

/// Reveal a long line once, keeping its beginning readable before scrolling and
/// its ending in place until the source publishes a new line.
enum BriefMarqueeProgress {
    static func offset(textWidth: CGFloat, viewportWidth: CGFloat, elapsed: TimeInterval) -> CGFloat {
        guard textWidth.isFinite, viewportWidth.isFinite, elapsed.isFinite else { return 0 }
        return min(max(0, textWidth - max(0, viewportWidth)), CGFloat(max(0, elapsed - 2) * 22))
    }
}
