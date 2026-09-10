import SwiftUI

/// An original, code-drawn landscape. The scene is static except for a single
/// growth transition; it does not run an idle animation or a display-link loop.
struct IslandScene: View {
    let treeGrown: Bool
    let animateGrowth: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var growthProgress = 0.0

    private let drawingSize = CGSize(width: 340, height: 118)

    init(treeGrown: Bool, animateGrowth: Bool) {
        self.treeGrown = treeGrown
        self.animateGrowth = animateGrowth
        // Reopened pages draw their persisted tree in the first frame, without
        // briefly showing a sprout while the appearance task is scheduled.
        _growthProgress = State(initialValue: treeGrown && !animateGrowth ? 1 : 0)
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / drawingSize.width,
                            geometry.size.height / drawingSize.height)

            artwork
                .frame(width: drawingSize.width, height: drawingSize.height)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: (geometry.size.width - drawingSize.width * scale) / 2,
                        y: (geometry.size.height - drawingSize.height * scale) / 2)
        }
        .aspectRatio(drawingSize.width / drawingSize.height, contentMode: .fit)
        .frame(idealWidth: drawingSize.width, idealHeight: drawingSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(treeGrown ? "小岛上的小树已经长大" : "小岛上有一株等待长大的幼芽")
        .task(id: GrowthSignal(grown: treeGrown, animate: animateGrowth, reducedMotion: reduceMotion)) {
            await updateGrowth()
        }
    }

    private var artwork: some View {
        ZStack(alignment: .topLeading) {
            IslandLandscape()

            IslandSprout()
                .frame(width: 32, height: 28)
                .position(x: 181, y: 81)
                .opacity(1 - min(growthProgress * 2, 1))

            IslandTree()
                .frame(width: 94, height: 91)
                .scaleEffect(x: 0.72 + 0.28 * growthProgress,
                             y: 0.14 + 0.86 * growthProgress,
                             anchor: .bottom)
                .opacity(growthProgress)
                .position(x: 181, y: 49.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(IslandPalette.ink.opacity(0.12), lineWidth: 1)
        }
    }

    @MainActor
    private func updateGrowth() async {
        guard treeGrown else {
            growthProgress = 0
            return
        }
        guard animateGrowth, !reduceMotion else {
            growthProgress = 1
            return
        }

        growthProgress = 0
        // Allow the sprout to be drawn before starting this one-shot transition.
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(.spring(response: 1.05, dampingFraction: 0.76)) {
            growthProgress = 1
        }
    }

    private struct GrowthSignal: Equatable {
        let grown: Bool
        let animate: Bool
        let reducedMotion: Bool
    }
}

private enum IslandPalette {
    static let paper = Color(red: 0.953, green: 0.925, blue: 0.850)
    static let ink = Color(red: 0.285, green: 0.344, blue: 0.258)
    static let grass = Color(red: 0.645, green: 0.737, blue: 0.485)
    static let grassLight = Color(red: 0.738, green: 0.800, blue: 0.573)
    static let sand = Color(red: 0.871, green: 0.778, blue: 0.605)
    static let bark = Color(red: 0.531, green: 0.439, blue: 0.294)
    static let leaf = Color(red: 0.428, green: 0.586, blue: 0.385)
    static let leafLight = Color(red: 0.597, green: 0.702, blue: 0.445)
}

private struct IslandLandscape: View {
    var body: some View {
        Canvas { context, _ in
            context.fill(Path(CGRect(x: 0, y: 0, width: 340, height: 118)), with: .color(IslandPalette.paper))

            // A restrained paper grain, with fixed positions for stable redraws.
            for index in 0..<110 {
                let x = CGFloat((index * 47 + 13) % 337)
                let y = CGFloat((index * 31 + 7) % 117)
                let width = index.isMultiple(of: 3) ? 1.8 : 0.7
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: width, height: 0.7)),
                             with: .color(IslandPalette.ink.opacity(0.075)))
            }

            context.fill(Path(ellipseIn: CGRect(x: 254, y: 12, width: 27, height: 27)),
                         with: .color(Color(red: 0.931, green: 0.740, blue: 0.403).opacity(0.65)))

            cloud(in: &context, at: CGPoint(x: 45, y: 26), scale: 1)
            cloud(in: &context, at: CGPoint(x: 257, y: 45), scale: 0.76)

            // Thin water marks give the island a little space to breathe.
            var water = Path()
            water.move(to: CGPoint(x: 45, y: 91))
            water.addQuadCurve(to: CGPoint(x: 90, y: 91), control: CGPoint(x: 69, y: 87))
            water.move(to: CGPoint(x: 247, y: 91))
            water.addQuadCurve(to: CGPoint(x: 291, y: 92), control: CGPoint(x: 268, y: 88))
            water.move(to: CGPoint(x: 73, y: 106))
            water.addLine(to: CGPoint(x: 102, y: 106))
            water.move(to: CGPoint(x: 246, y: 107))
            water.addLine(to: CGPoint(x: 272, y: 107))
            context.stroke(water, with: .color(Color(red: 0.553, green: 0.690, blue: 0.670).opacity(0.38)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

            context.fill(Path(ellipseIn: CGRect(x: 93, y: 94, width: 151, height: 18)),
                         with: .color(IslandPalette.ink.opacity(0.08)))

            let sand = Path { path in
                path.move(to: CGPoint(x: 94, y: 85))
                path.addCurve(to: CGPoint(x: 168, y: 68), control1: CGPoint(x: 111, y: 74), control2: CGPoint(x: 143, y: 70))
                path.addCurve(to: CGPoint(x: 244, y: 87), control1: CGPoint(x: 208, y: 65), control2: CGPoint(x: 236, y: 72))
                path.addCurve(to: CGPoint(x: 219, y: 106), control1: CGPoint(x: 257, y: 96), control2: CGPoint(x: 236, y: 103))
                path.addCurve(to: CGPoint(x: 111, y: 103), control1: CGPoint(x: 184, y: 116), control2: CGPoint(x: 134, y: 110))
                path.addCurve(to: CGPoint(x: 94, y: 85), control1: CGPoint(x: 93, y: 100), control2: CGPoint(x: 85, y: 93))
                path.closeSubpath()
            }
            context.fill(sand, with: .color(IslandPalette.sand))
            context.stroke(sand, with: .color(IslandPalette.ink.opacity(0.31)), lineWidth: 1.05)

            let grass = Path { path in
                path.move(to: CGPoint(x: 98, y: 81))
                path.addCurve(to: CGPoint(x: 164, y: 64), control1: CGPoint(x: 112, y: 71), control2: CGPoint(x: 140, y: 66))
                path.addCurve(to: CGPoint(x: 238, y: 79), control1: CGPoint(x: 200, y: 62), control2: CGPoint(x: 230, y: 68))
                path.addCurve(to: CGPoint(x: 222, y: 97), control1: CGPoint(x: 255, y: 88), control2: CGPoint(x: 239, y: 93))
                path.addCurve(to: CGPoint(x: 113, y: 97), control1: CGPoint(x: 187, y: 108), control2: CGPoint(x: 133, y: 102))
                path.addCurve(to: CGPoint(x: 98, y: 81), control1: CGPoint(x: 99, y: 94), control2: CGPoint(x: 86, y: 88))
                path.closeSubpath()
            }
            context.fill(grass, with: .color(IslandPalette.grass))
            context.stroke(grass, with: .color(IslandPalette.ink.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))

            let meadow = Path { path in
                path.move(to: CGPoint(x: 107, y: 80))
                path.addCurve(to: CGPoint(x: 217, y: 77), control1: CGPoint(x: 132, y: 66), control2: CGPoint(x: 191, y: 67))
                path.addCurve(to: CGPoint(x: 181, y: 91), control1: CGPoint(x: 209, y: 88), control2: CGPoint(x: 193, y: 92))
                path.addCurve(to: CGPoint(x: 107, y: 80), control1: CGPoint(x: 144, y: 96), control2: CGPoint(x: 111, y: 87))
            }
            context.fill(meadow, with: .color(IslandPalette.grassLight.opacity(0.72)))

            var walkingPath = Path()
            walkingPath.move(to: CGPoint(x: 165, y: 101))
            walkingPath.addCurve(to: CGPoint(x: 167, y: 91), control1: CGPoint(x: 143, y: 95), control2: CGPoint(x: 151, y: 94))
            walkingPath.addCurve(to: CGPoint(x: 181, y: 83), control1: CGPoint(x: 182, y: 88), control2: CGPoint(x: 187, y: 88))
            context.stroke(walkingPath, with: .color(IslandPalette.paper.opacity(0.83)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round))

            for origin in [CGPoint(x: 117, y: 83), CGPoint(x: 140, y: 76),
                           CGPoint(x: 216, y: 87), CGPoint(x: 201, y: 95), CGPoint(x: 125, y: 95)] {
                var tuft = Path()
                tuft.move(to: CGPoint(x: origin.x - 3, y: origin.y))
                tuft.addLine(to: CGPoint(x: origin.x - 4, y: origin.y - 3))
                tuft.move(to: origin)
                tuft.addLine(to: CGPoint(x: origin.x, y: origin.y - 4))
                tuft.move(to: CGPoint(x: origin.x + 2, y: origin.y))
                tuft.addLine(to: CGPoint(x: origin.x + 4, y: origin.y - 2))
                context.stroke(tuft, with: .color(IslandPalette.ink.opacity(0.4)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }

            for origin in [CGPoint(x: 105, y: 91), CGPoint(x: 232, y: 85)] {
                context.fill(Path(ellipseIn: CGRect(x: origin.x, y: origin.y, width: 6, height: 3.5)),
                             with: .color(IslandPalette.paper.opacity(0.85)))
            }
        }
    }

    private func cloud(in context: inout GraphicsContext, at origin: CGPoint, scale: CGFloat) {
        var cloudContext = context
        cloudContext.translateBy(x: origin.x, y: origin.y)
        cloudContext.scaleBy(x: scale, y: scale)
        let shape = Path { path in
            path.move(to: CGPoint(x: 0, y: 11))
            path.addCurve(to: CGPoint(x: 12, y: 4), control1: CGPoint(x: -1, y: 4), control2: CGPoint(x: 5, y: 1))
            path.addCurve(to: CGPoint(x: 30, y: 4), control1: CGPoint(x: 13, y: -8), control2: CGPoint(x: 29, y: -6))
            path.addCurve(to: CGPoint(x: 43, y: 13), control1: CGPoint(x: 37, y: 0), control2: CGPoint(x: 48, y: 6))
            path.addCurve(to: CGPoint(x: 0, y: 11), control1: CGPoint(x: 35, y: 18), control2: CGPoint(x: 5, y: 18))
            path.closeSubpath()
        }
        cloudContext.fill(shape, with: .color(.white.opacity(0.7)))
        cloudContext.stroke(shape, with: .color(IslandPalette.ink.opacity(0.22)),
                            style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
    }
}

private struct IslandSprout: View {
    var body: some View {
        Canvas { context, _ in
            context.fill(Path(ellipseIn: CGRect(x: 5, y: 23, width: 23, height: 4)),
                         with: .color(IslandPalette.ink.opacity(0.14)))
            var stem = Path()
            stem.move(to: CGPoint(x: 17, y: 25))
            stem.addQuadCurve(to: CGPoint(x: 15, y: 9), control: CGPoint(x: 17, y: 13))
            context.stroke(stem, with: .color(IslandPalette.ink.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
            let leaves = Path { path in
                path.move(to: CGPoint(x: 16, y: 17))
                path.addCurve(to: CGPoint(x: 4, y: 6), control1: CGPoint(x: 6, y: 19), control2: CGPoint(x: 3, y: 12))
                path.addQuadCurve(to: CGPoint(x: 16, y: 17), control: CGPoint(x: 16, y: 6))
                path.move(to: CGPoint(x: 16, y: 13))
                path.addQuadCurve(to: CGPoint(x: 27, y: 2), control: CGPoint(x: 16, y: 2))
                path.addQuadCurve(to: CGPoint(x: 16, y: 13), control: CGPoint(x: 30, y: 11))
            }
            context.fill(leaves, with: .color(IslandPalette.leaf))
            context.stroke(leaves, with: .color(IslandPalette.ink.opacity(0.62)), lineWidth: 1)
        }
    }
}

private struct IslandTree: View {
    var body: some View {
        Canvas { context, _ in
            context.fill(Path(ellipseIn: CGRect(x: 30, y: 85, width: 37, height: 5)),
                         with: .color(IslandPalette.ink.opacity(0.14)))

            let trunk = Path { path in
                path.move(to: CGPoint(x: 43, y: 85))
                path.addCurve(to: CGPoint(x: 43, y: 38), control1: CGPoint(x: 47, y: 64), control2: CGPoint(x: 40, y: 49))
                path.addLine(to: CGPoint(x: 50, y: 36))
                path.addCurve(to: CGPoint(x: 52, y: 86), control1: CGPoint(x: 48, y: 56), control2: CGPoint(x: 49, y: 77))
                path.addQuadCurve(to: CGPoint(x: 43, y: 85), control: CGPoint(x: 58, y: 89))
                path.closeSubpath()
            }
            context.fill(trunk, with: .color(IslandPalette.bark))
            context.stroke(trunk, with: .color(IslandPalette.ink.opacity(0.75)), lineWidth: 1.1)

            var branches = Path()
            branches.move(to: CGPoint(x: 47, y: 64))
            branches.addQuadCurve(to: CGPoint(x: 30, y: 48), control: CGPoint(x: 32, y: 59))
            branches.move(to: CGPoint(x: 48, y: 57))
            branches.addQuadCurve(to: CGPoint(x: 67, y: 42), control: CGPoint(x: 63, y: 54))
            context.stroke(branches, with: .color(IslandPalette.bark),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round))

            let canopy = Path { path in
                path.move(to: CGPoint(x: 17, y: 49))
                path.addCurve(to: CGPoint(x: 15, y: 29), control1: CGPoint(x: 5, y: 49), control2: CGPoint(x: 5, y: 33))
                path.addCurve(to: CGPoint(x: 32, y: 13), control1: CGPoint(x: 10, y: 18), control2: CGPoint(x: 23, y: 8))
                path.addCurve(to: CGPoint(x: 57, y: 10), control1: CGPoint(x: 36, y: 0), control2: CGPoint(x: 53, y: 0))
                path.addCurve(to: CGPoint(x: 78, y: 25), control1: CGPoint(x: 71, y: 5), control2: CGPoint(x: 83, y: 13))
                path.addCurve(to: CGPoint(x: 83, y: 44), control1: CGPoint(x: 91, y: 30), control2: CGPoint(x: 91, y: 42))
                path.addCurve(to: CGPoint(x: 65, y: 60), control1: CGPoint(x: 87, y: 56), control2: CGPoint(x: 74, y: 64))
                path.addCurve(to: CGPoint(x: 40, y: 63), control1: CGPoint(x: 58, y: 69), control2: CGPoint(x: 47, y: 69))
                path.addCurve(to: CGPoint(x: 17, y: 49), control1: CGPoint(x: 26, y: 69), control2: CGPoint(x: 15, y: 61))
                path.closeSubpath()
            }
            context.fill(canopy, with: .color(IslandPalette.leaf))
            context.stroke(canopy, with: .color(IslandPalette.ink.opacity(0.75)),
                           style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))

            let light = Path { path in
                path.move(to: CGPoint(x: 19, y: 31))
                path.addCurve(to: CGPoint(x: 35, y: 17), control1: CGPoint(x: 17, y: 17), control2: CGPoint(x: 25, y: 13))
                path.addCurve(to: CGPoint(x: 55, y: 14), control1: CGPoint(x: 40, y: 5), control2: CGPoint(x: 53, y: 6))
                path.addCurve(to: CGPoint(x: 68, y: 23), control1: CGPoint(x: 68, y: 12), control2: CGPoint(x: 75, y: 20))
                path.addCurve(to: CGPoint(x: 48, y: 37), control1: CGPoint(x: 70, y: 34), control2: CGPoint(x: 60, y: 38))
                path.addCurve(to: CGPoint(x: 19, y: 31), control1: CGPoint(x: 35, y: 46), control2: CGPoint(x: 17, y: 43))
                path.closeSubpath()
            }
            context.fill(light, with: .color(IslandPalette.leafLight.opacity(0.8)))

            // A few deliberate pencil marks keep the foliage from looking flat.
            for origin in [CGPoint(x: 29, y: 28), CGPoint(x: 55, y: 23), CGPoint(x: 63, y: 48), CGPoint(x: 30, y: 51)] {
                var detail = Path()
                detail.move(to: CGPoint(x: origin.x - 3, y: origin.y + 1))
                detail.addQuadCurve(to: CGPoint(x: origin.x + 3, y: origin.y),
                                    control: CGPoint(x: origin.x, y: origin.y - 3))
                context.stroke(detail, with: .color(IslandPalette.ink.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            }
            var trunkMark = Path()
            trunkMark.move(to: CGPoint(x: 47, y: 73))
            trunkMark.addLine(to: CGPoint(x: 47.5, y: 82))
            context.stroke(trunkMark, with: .color(IslandPalette.paper.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }
}

#Preview("幼芽") {
    IslandScene(treeGrown: false, animateGrowth: false)
        .frame(width: 340, height: 118)
        .padding(20)
        .background(.black)
}

#Preview("休息后的树") {
    IslandScene(treeGrown: true, animateGrowth: false)
        .frame(width: 340, height: 118)
        .padding(20)
        .background(.black)
}
