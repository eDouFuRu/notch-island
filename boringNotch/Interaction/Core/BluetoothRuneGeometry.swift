import CoreGraphics

/// Outline of the classic Bluetooth rune.
///
/// SF Symbols ships no Bluetooth glyph, so the tool grid draws its own instead of
/// settling for the antenna symbol that does not match the shape macOS shows in
/// Control Center. The rune is stored here, away from SwiftUI, so the coordinates
/// stay unit-testable.
public enum BluetoothRuneGeometry {
    /// One continuous open polyline inside the unit square, in SwiftUI's
    /// y-grows-downward space: upper-left, lower-right, bottom tip, top tip,
    /// upper-right, lower-left.
    public static let points: [CGPoint] = [
        CGPoint(x: 0.2708, y: 0.2708),
        CGPoint(x: 0.7292, y: 0.7292),
        CGPoint(x: 0.5000, y: 0.9583),
        CGPoint(x: 0.5000, y: 0.0417),
        CGPoint(x: 0.7292, y: 0.2708),
        CGPoint(x: 0.2708, y: 0.7292)
    ]

    /// Scales the normalized outline into a drawing rectangle, keeping it square
    /// and centred so the rune never stretches with the surrounding label.
    public static func scaled(into rect: CGRect) -> [CGPoint] {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return [] }
        let originX = rect.midX - side / 2
        let originY = rect.midY - side / 2
        return points.map { CGPoint(x: originX + $0.x * side, y: originY + $0.y * side) }
    }
}
