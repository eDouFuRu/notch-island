import SwiftUI

/// The classic Bluetooth rune, stroked from the shared normalized outline.
struct BluetoothRuneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points = BluetoothRuneGeometry.scaled(into: rect)
        var path = Path()
        guard let start = points.first else { return path }
        path.move(to: start)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

/// Drop-in replacement for `Image(systemName: tool.symbol)` that also covers the
/// catalog entries Apple provides no symbol for.
struct SystemToolGlyph: View {
    let tool: SystemToolDefinition
    var lineWidth: CGFloat = 1.6
    /// A `Shape` ignores the ambient font, so the drawn rune would otherwise fill
    /// whatever frame the call site happens to impose and end up taller than the
    /// SF Symbols beside it. Keep this in step with the call site's font size.
    var glyphHeight: CGFloat = 18

    var body: some View {
        switch tool.customIcon {
        case .bluetoothRune:
            BluetoothRuneShape()
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .aspectRatio(1, contentMode: .fit)
                .frame(height: glyphHeight)
        case nil:
            Image(systemName: tool.symbol)
        }
    }
}
