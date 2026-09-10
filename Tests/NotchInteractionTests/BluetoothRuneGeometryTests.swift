import XCTest
@testable import NotchInteractionCore

final class BluetoothRuneGeometryTests: XCTestCase {
    func testOutlineIsSixPointsInsideTheUnitSquare() {
        let points = BluetoothRuneGeometry.points
        XCTAssertEqual(points.count, 6)
        for point in points {
            XCTAssertTrue((0...1).contains(point.x), "x out of unit range: \(point.x)")
            XCTAssertTrue((0...1).contains(point.y), "y out of unit range: \(point.y)")
        }
    }

    /// The rune is symmetric about its centre, so a mistyped coordinate breaks the
    /// point set's closure under reflection long before anyone notices on screen.
    func testOutlineIsClosedUnderPointReflectionThroughTheCentre() {
        let points = BluetoothRuneGeometry.points
        for point in points {
            let mirrored = CGPoint(x: 1 - point.x, y: 1 - point.y)
            let hasMatch = points.contains {
                abs($0.x - mirrored.x) < 0.0001 && abs($0.y - mirrored.y) < 0.0001
            }
            XCTAssertTrue(hasMatch, "no mirrored counterpart for \(point)")
        }
    }

    /// The rune is taller than it is wide, so the invariant is that its proportions
    /// survive a non-square container, not that the drawn extent becomes square.
    func testScalingPreservesProportionsAndCentresInsideAWideRectangle() {
        let normalized = BluetoothRuneGeometry.points
        let expectedRatio = (normalized.map(\.x).max()! - normalized.map(\.x).min()!)
            / (normalized.map(\.y).max()! - normalized.map(\.y).min()!)

        let rect = CGRect(x: 10, y: 20, width: 100, height: 40)
        let scaled = BluetoothRuneGeometry.scaled(into: rect)
        XCTAssertEqual(scaled.count, 6)

        let xs = scaled.map(\.x), ys = scaled.map(\.y)
        let width = xs.max()! - xs.min()!
        let height = ys.max()! - ys.min()!
        XCTAssertEqual(width / height, expectedRatio, accuracy: 0.0001, "the rune must not stretch with its container")

        // The short edge bounds the glyph, so a wide container never clips it.
        XCTAssertLessThanOrEqual(height, rect.height + 0.0001)
        XCTAssertLessThanOrEqual(width, rect.width + 0.0001)

        XCTAssertEqual((xs.max()! + xs.min()!) / 2, rect.midX, accuracy: 0.0001)
        XCTAssertEqual((ys.max()! + ys.min()!) / 2, rect.midY, accuracy: 0.0001)
    }

    func testEmptyRectangleProducesNoPointsInsteadOfNaNs() {
        XCTAssertTrue(BluetoothRuneGeometry.scaled(into: .zero).isEmpty)
    }

    func testOnlyBluetoothCarriesACustomGlyph() {
        XCTAssertEqual(SystemToolCatalog.tool(.bluetooth).customIcon, .bluetoothRune)
        let others = SystemToolCatalog.all.filter { $0.id != .bluetooth }
        XCTAssertTrue(others.allSatisfy { $0.customIcon == nil })
    }

    func testBluetoothKeepsASymbolFallbackForTheDragPreview() {
        XCTAssertFalse(SystemToolCatalog.tool(.bluetooth).symbol.isEmpty)
    }
}
