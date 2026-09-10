// Custom changes for 工位充电岛. Geometry is independent of AppKit and SwiftUI.
import Foundation
import CoreGraphics

/// Geometry for a control that floats just outside the island's painted edge.
///
/// It is the one thing the user can click that the black shape does not cover, so its
/// rectangle has to be described somewhere both the view and the hit test can read; letting
/// each place its own copy is how a button ends up visible but dead.
enum NotchAccessorySlot: CaseIterable {
    case collapse
    case clearShelf

    /// Fraction of the island's height the control's centre sits at, measured from the top.
    /// One per half, which is what makes the pair symmetric about the island's horizontal
    /// axis by construction rather than by arithmetic that could drift.
    var centerFraction: CGFloat {
        switch self {
        case .collapse: return 0.25
        case .clearShelf: return 0.75
        }
    }
}

enum NotchAccessoryControl {
    static let diameter: CGFloat = 26
    /// Clear of the island's edge but still obviously attached to it.
    static let gap: CGFloat = 9

    /// Total width the carrier window must reserve beyond the island on that side.
    static var requiredSideMargin: CGFloat { gap + diameter }

    /// Centre offset from the island's centre, for the view to position itself with.
    static func centerOffsetX(visibleWidth: CGFloat) -> CGFloat {
        visibleWidth / 2 + gap + diameter / 2
    }

    /// Distance from the island's top edge down to the control's centre.
    static func centerOffsetY(visibleHeight: CGFloat, slot: NotchAccessorySlot) -> CGFloat {
        max(0, visibleHeight) * slot.centerFraction
    }

    /// What a `.overlay(alignment: .top)` needs: it aligns the child's *top edge*, not its
    /// centre. Naming the two axes differently is deliberate — writing the x axis' centre
    /// convention into the y offset is exactly how the drawn circle ended up 11pt below the
    /// clickable one in Build 288.
    static func topEdgeOffset(visibleHeight: CGFloat, slot: NotchAccessorySlot) -> CGFloat {
        centerOffsetY(visibleHeight: visibleHeight, slot: slot) - diameter / 2
    }

    /// The same control in AppKit screen coordinates, for hit testing.
    static func rect(visibleFrame: CGRect, slot: NotchAccessorySlot) -> CGRect {
        let centerY = visibleFrame.maxY - centerOffsetY(visibleHeight: visibleFrame.height, slot: slot)
        return CGRect(x: visibleFrame.maxX + gap, y: centerY - diameter / 2,
                      width: diameter, height: diameter)
    }
}

struct NotchHitRegion: Equatable {
    var triggerRect: CGRect
    var visibleFrame: CGRect
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Empty unless controls are floating outside the island. They sit beyond
    /// `visibleFrame`, so they need their own hit test — the painted shape does not
    /// contain them.
    var accessoryRects: [CGRect] = []

    /// AppKit screen coordinates, including screens whose origin is not zero.
    /// The physical camera exclusion area is exactly between the two auxiliary areas.
    static func triggerRect(
        screenFrame: CGRect,
        safeTop: CGFloat,
        leftAuxiliaryWidth: CGFloat?,
        rightAuxiliaryWidth: CGFloat?,
        fallbackSize: CGSize = CGSize(width: 120, height: 29)
    ) -> CGRect {
        if safeTop > 0,
           let left = leftAuxiliaryWidth, let right = rightAuxiliaryWidth,
           left >= 0, right >= 0, left + right < screenFrame.width {
            return CGRect(
                x: screenFrame.minX + left,
                y: screenFrame.maxY - safeTop,
                width: screenFrame.width - left - right,
                height: safeTop
            )
        }
        let width = min(max(1, fallbackSize.width), screenFrame.width)
        let height = min(max(1, fallbackSize.height), screenFrame.height)
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height,
                      width: width, height: height)
    }

    func containsTrigger(_ point: CGPoint) -> Bool {
        Self.containsIncludingEdges(triggerRect, point)
    }

    /// Same quadratic contour as the upstream NotchShape, with AppKit's Y axis flipped.
    /// The top outer corners are concave and are not rectangular hit targets.
    func containsVisible(_ point: CGPoint) -> Bool {
        guard visibleFrame.width > 0, visibleFrame.height > 0,
              Self.containsIncludingEdges(visibleFrame, point) else { return false }
        let local = CGPoint(x: point.x - visibleFrame.minX, y: visibleFrame.maxY - point.y)
        return Self.outline(size: visibleFrame.size, topRadius: topRadius,
                            bottomRadius: bottomRadius).contains(local)
    }

    /// The floating controls, if any are shown. Round, so a corner of a square frame is
    /// not a hit — they sit over open desktop, where a stray hit would eat someone else's
    /// click.
    func containsAccessory(_ point: CGPoint) -> Bool {
        accessoryRects.contains { rect in
            guard rect.width > 0, rect.height > 0 else { return false }
            let radius = min(rect.width, rect.height) / 2
            let dx = point.x - rect.midX, dy = point.y - rect.midY
            return dx * dx + dy * dy <= radius * radius
        }
    }

    /// Everywhere the island currently occupies, for deciding whether a click is "outside".
    /// Includes the floating control: clicking it is using the island, not dismissing it.
    func containsExpandedHover(_ point: CGPoint) -> Bool {
        containsTrigger(point) || containsVisible(point) || containsAccessory(point)
    }

    /// Everywhere the pointer may rest without the island collapsing. Deliberately does not
    /// include `triggerRect`, which alone is what may *open* the island.
    func containsInteractiveContent(_ point: CGPoint) -> Bool {
        containsVisible(point) || containsAccessory(point)
    }

    static func outline(size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat) -> CGPath {
        let width = max(0, size.width), height = max(0, size.height)
        let top = min(max(0, topRadius), min(width / 2, height))
        let bottom = min(max(0, bottomRadius), min(max(0, width / 2 - top), max(0, height - top)))
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: top, y: top), control: CGPoint(x: top, y: 0))
        path.addLine(to: CGPoint(x: top, y: height - bottom))
        path.addQuadCurve(to: CGPoint(x: top + bottom, y: height),
                          control: CGPoint(x: top, y: height))
        path.addLine(to: CGPoint(x: width - top - bottom, y: height))
        path.addQuadCurve(to: CGPoint(x: width - top, y: height - bottom),
                          control: CGPoint(x: width - top, y: height))
        path.addLine(to: CGPoint(x: width - top, y: top))
        path.addQuadCurve(to: CGPoint(x: width, y: 0), control: CGPoint(x: width - top, y: 0))
        path.closeSubpath()
        return path
    }

    private static func containsIncludingEdges(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}
