import SwiftUI

// Shared palette and retained vector fallback. The primary 2.5D puppet and
// continuous action scene are implemented in Shu25DScene.swift.
enum ShuPalette {
    static let ink = Color(red: 0.19, green: 0.15, blue: 0.13)
    static let skin = Color(red: 0.88, green: 0.76, blue: 0.66)
    static let shirt = Color(red: 0.89, green: 0.035, blue: 0.14)
    static let leaf = Color(red: 0.12, green: 0.48, blue: 0.31)
    static let paper = Color(red: 0.98, green: 0.94, blue: 0.84)
    static let peel = Color(red: 0.63, green: 0.24, blue: 0.29)
    static let flesh = Color(red: 1, green: 0.71, blue: 0.31)
}

enum ShuPose { case holding, planting, watering, harvesting, roasting, resting }

struct LegacyCaptainShuIllustration: View {
    var pose: ShuPose = .holding
    var motion: Double = 0
    var roastingInGarden = false
    var body: some View {
        Canvas { raw, size in
            var c = raw
            let scale = min(size.width / 180, size.height / 220)
            c.translateBy(x: (size.width - 180 * scale) / 2, y: (size.height - 220 * scale) / 2)
            c.scaleBy(x: scale, y: scale)
            func draw(_ p: Path, _ fill: Color, width: CGFloat = 3.4) {
                c.fill(p, with: .color(fill))
                c.stroke(p, with: .color(ShuPalette.ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            func limb(_ a: CGPoint, _ b: CGPoint, width: CGFloat = 18, color: Color = ShuPalette.skin) {
                let p = Path { $0.move(to: a); $0.addLine(to: b) }
                c.stroke(p, with: .color(ShuPalette.ink), style: StrokeStyle(lineWidth: width + 5, lineCap: .round))
                c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            // Soft shadow, boots, arms, body and shirt are independent layers.
            c.fill(Path(ellipseIn: CGRect(x: 44, y: 205, width: 96, height: 9)), with: .color(ShuPalette.ink.opacity(0.1)))
            limb(CGPoint(x: 71, y: 175), CGPoint(x: 64, y: 202), width: 21)
            limb(CGPoint(x: 111, y: 175), CGPoint(x: pose == .roasting ? 132 : 118, y: 200), width: 21)
            let swing = CGFloat(sin(motion * 3)) * 8
            if pose != .holding {
                limb(CGPoint(x: 52, y: 125), CGPoint(x: pose == .planting ? 20 : 31, y: 112 + swing))
                limb(CGPoint(x: 129, y: 122), CGPoint(x: 158, y: pose == .planting ? 145 + swing : pose == .harvesting ? 86 : 104 - swing))
            }
            let body = Path { p in
                p.move(to: CGPoint(x: 83, y: 28))
                p.addCurve(to: CGPoint(x: 41, y: 125), control1: CGPoint(x: 39, y: 57), control2: CGPoint(x: 35, y: 78))
                p.addCurve(to: CGPoint(x: 62, y: 181), control1: CGPoint(x: 39, y: 158), control2: CGPoint(x: 45, y: 174))
                p.addCurve(to: CGPoint(x: 128, y: 171), control1: CGPoint(x: 91, y: 204), control2: CGPoint(x: 126, y: 189))
                p.addCurve(to: CGPoint(x: 116, y: 76), control1: CGPoint(x: 151, y: 139), control2: CGPoint(x: 126, y: 92))
                p.addQuadCurve(to: CGPoint(x: 83, y: 28), control: CGPoint(x: 93, y: 31))
                p.closeSubpath()
            }
            draw(body, ShuPalette.skin)
            let shirt = Path { p in
                p.move(to: CGPoint(x: 39, y: 121)); p.addQuadCurve(to: CGPoint(x: 138, y: 114), control: CGPoint(x: 91, y: 135))
                p.addLine(to: CGPoint(x: 142, y: 160)); p.addQuadCurve(to: CGPoint(x: 45, y: 169), control: CGPoint(x: 89, y: 185)); p.closeSubpath()
            }
            draw(shirt, ShuPalette.shirt)
            // Small badge instead of tiny, unreadable lettering at notch size.
            c.fill(Path(roundedRect: CGRect(x: 100, y: 137, width: 17, height: 10), cornerRadius: 3), with: .color(.white.opacity(0.95)))
            let sprout = Path { p in
                p.move(to: CGPoint(x: 86, y: 30))
                p.addCurve(to: CGPoint(x: 66, y: 10), control1: CGPoint(x: 65, y: 27), control2: CGPoint(x: 58, y: 7))
                p.addQuadCurve(to: CGPoint(x: 84, y: 12), control: CGPoint(x: 76, y: 1))
                p.addCurve(to: CGPoint(x: 103, y: 10), control1: CGPoint(x: 91, y: 0), control2: CGPoint(x: 107, y: 0))
                p.addQuadCurve(to: CGPoint(x: 86, y: 30), control: CGPoint(x: 114, y: 22)); p.closeSubpath()
            }
            draw(sprout, ShuPalette.leaf, width: 3)
            c.fill(Path(ellipseIn: CGRect(x: 48, y: 103, width: 22, height: 18)), with: .color(Color(red: 0.86, green: 0.40, blue: 0.38).opacity(0.6)))
            c.fill(Path(ellipseIn: CGRect(x: 100, y: 95, width: 22, height: 18)), with: .color(Color(red: 0.86, green: 0.40, blue: 0.38).opacity(0.6)))
            for point in [CGPoint(x: 66, y: 96), CGPoint(x: 104, y: 89)] {
                c.fill(Path(ellipseIn: CGRect(x: point.x - 4.5, y: point.y - 5, width: 9, height: 10)), with: .color(ShuPalette.ink))
            }
            let smile = Path { p in
                p.move(to: CGPoint(x: 80, y: 104)); p.addLine(to: CGPoint(x: 94, y: 101))
                p.addQuadCurve(to: CGPoint(x: 80, y: 104), control: CGPoint(x: 91, y: 124)); p.closeSubpath()
            }
            draw(smile, Color(red: 0.94, green: 0.46, blue: 0.43), width: 2)
            if pose == .holding {
                limb(CGPoint(x: 47, y: 143), CGPoint(x: 75, y: 151), width: 15)
                limb(CGPoint(x: 136, y: 142), CGPoint(x: 108, y: 153), width: 15)
            }
            if pose == .planting {
                limb(CGPoint(x: 157, y: 129 + swing), CGPoint(x: 141, y: 196), width: 4, color: Color(red: 0.53, green: 0.35, blue: 0.22))
                draw(Path(roundedRect: CGRect(x: 129, y: 190, width: 29, height: 8), cornerRadius: 2), Color(red: 0.56, green: 0.60, blue: 0.51), width: 2)
            }
            if pose == .roasting {
                limb(CGPoint(x: 155, y: 110 - swing), CGPoint(x: roastingInGarden ? 194 : 177, y: roastingInGarden ? 104 : 154), width: 3, color: Color(red: 0.48, green: 0.31, blue: 0.18))
            }
        }
        .overlay {
            GeometryReader { geometry in
                if pose == .holding {
                    RoastPotatoView().frame(width: geometry.size.width * 0.40, height: geometry.size.height * 0.17)
                        .rotationEffect(.degrees(-17))
                        .position(x: geometry.size.width * 0.51, y: geometry.size.height * 0.69)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct LegacyRoastPotatoView: View {
    var bites: Int = 0
    var body: some View {
        Canvas { c, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            let shape = Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.midY + 5))
                p.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY - 5), control1: CGPoint(x: rect.width * 0.21, y: rect.minY - 5), control2: CGPoint(x: rect.maxX * 0.82, y: rect.minY))
                p.addCurve(to: CGPoint(x: rect.minX, y: rect.midY + 5), control1: CGPoint(x: rect.width * 0.92, y: rect.maxY + 1), control2: CGPoint(x: rect.minX + 10, y: rect.maxY + 5)); p.closeSubpath()
            }
            let eaten = min(6, max(0, bites))
            if eaten == 6 { return }
            if eaten > 0 {
                // Each stage removes exactly one sixth of the length; overlapping
                // large bite circles used to erase nearly everything by bite five.
                let remainingEdge = rect.minX + rect.width * CGFloat(6 - eaten) / 6
                c.clip(to: Path(CGRect(x: 0, y: 0, width: remainingEdge, height: size.height)))
                for index in 0..<3 {
                    var scallop = Path(CGRect(origin: .zero, size: size))
                    scallop.addEllipse(in: CGRect(x: remainingEdge - 1.5,
                                                  y: size.height * CGFloat(index + 1) / 4 - 2,
                                                  width: 4, height: 4))
                    c.clip(to: scallop, style: FillStyle(eoFill: true))
                }
            }
            c.fill(shape, with: .color(ShuPalette.peel))
            c.stroke(shape, with: .color(ShuPalette.ink), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            let flesh = Path(ellipseIn: CGRect(x: size.width * 0.20, y: size.height * 0.25, width: size.width * 0.57, height: size.height * 0.40))
            c.fill(flesh, with: .color(ShuPalette.flesh))
            for i in 0..<3 {
                let x = size.width * (0.26 + Double(i) * 0.18)
                let p = Path { $0.move(to: CGPoint(x: x, y: size.height * 0.63)); $0.addLine(to: CGPoint(x: x + 4, y: size.height * 0.75)) }
                c.stroke(p, with: .color(ShuPalette.ink.opacity(0.3)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

enum GardenActivity { case idle, planting, roasting, focusing }

/// Shared vector artwork exported to AppIcon and shown in the theme picker.
struct CaptainShuIconArtwork: View {
    var variant: String = "captain"
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 112).fill(ShuPalette.shirt.gradient)
            RoundedRectangle(cornerRadius: 92).fill(ShuPalette.paper).padding(26)
            Circle().fill(ShuPalette.flesh.opacity(0.32)).frame(width: 270).offset(x: 100, y: -90)
            Ellipse().fill(Color(red: 0.73, green: 0.80, blue: 0.57)).frame(width: 405, height: 106).offset(y: 164)
            CaptainShuIllustration(pose: variant == "planting" ? .planting : variant == "roasting" ? .roasting : .holding)
                .frame(width: 300, height: 383).offset(x: variant == "roasting" ? -25 : 0, y: 8)
            if variant == "roasting" {
                Image(systemName: "flame.fill").resizable().scaledToFit().foregroundStyle(ShuPalette.flesh, ShuPalette.shirt)
                    .frame(width: 90, height: 102).offset(x: 132, y: 125)
                RoastPotatoView().frame(width: 81, height: 47).rotationEffect(.degrees(-15)).offset(x: 101, y: 64)
            }
            if variant == "planting" {
                ForEach(0..<3) { i in
                    Image(systemName: "leaf.fill").foregroundStyle(ShuPalette.leaf).font(.system(size: 29))
                        .offset(x: CGFloat(i * 40 - 45), y: 181)
                }
            }
        }
        .frame(width: 512, height: 512)
    }
}
