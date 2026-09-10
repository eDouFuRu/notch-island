import SwiftUI

struct CaptainShuIllustration: View {
    var pose: ShuPose = .holding
    var motion: Double = 0
    var roastingInGarden = false
    var body: some View {
        if pose == .holding, let image = Shu25DAssets.image(.captainHolding) {
            Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true)
        } else if Shu25DAssets.hasPuppet {
            let time: Double = pose == .planting ? 3 : pose == .watering ? 17 : pose == .harvesting ? 26 : pose == .roasting ? 42 : 0
            ShuPuppet(sample: ShuAnimationTimeline.sample(elapsed: time + motion), resting: pose == .holding || pose == .resting)
        } else {
            LegacyCaptainShuIllustration(pose: pose, motion: motion, roastingInGarden: roastingInGarden)
        }
    }
}

struct RoastPotatoView: View {
    var bites: Int = 0
    var body: some View {
        if let image = Shu25DAssets.image(.roastPotato) {
            GeometryReader { _ in
                Image(nsImage: image).resizable().scaledToFit()
                    .mask(RasterPotatoBiteMask(bites: bites, contentBounds: Shu25DAssets.contentBounds(.roastPotato)))
            }.accessibilityHidden(true)
        } else {
            LegacyRoastPotatoView(bites: bites)
        }
    }
}

/// Keep one sixth of the potato per remaining bite, with a small scalloped edge.
/// Large overlapping circles erase too much of the final serving.
private struct RasterPotatoBiteMask: Shape {
    let bites: Int
    let contentBounds: CGRect
    func path(in rect: CGRect) -> Path {
        let eaten = min(6, max(0, bites))
        guard eaten < 6 else { return Path() }
        guard eaten > 0 else { return Path(rect) }
        let edge = rect.minX + rect.width * (contentBounds.minX + contentBounds.width * CGFloat(6 - eaten) / 6)
        let radius = min(2.2, rect.height * 0.08, (edge - rect.minX) * 0.15)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: edge, y: rect.minY))
            for index in 1...3 {
                let center = rect.minY + rect.height * CGFloat(index) / 4
                path.addLine(to: CGPoint(x: edge, y: center - radius))
                path.addQuadCurve(to: CGPoint(x: edge, y: center + radius),
                                  control: CGPoint(x: edge - radius * 2, y: center))
            }
            path.addLine(to: CGPoint(x: edge, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// The original face, shirt and lettering remain a single untouched image.
/// Only its embedded legs are masked at runtime; independent leg sprites own gait.
private struct ShuTorsoMask: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: rect.origin)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.770))
            // Follow the original asymmetric belly contour at each leg root,
            // instead of a broad ellipse that retains two square leg stumps.
            path.addCurve(to: CGPoint(x: rect.width * 0.75, y: rect.height * 0.820),
                          control1: CGPoint(x: rect.width * 0.93, y: rect.height * 0.787),
                          control2: CGPoint(x: rect.width * 0.855, y: rect.height * 0.805))
            path.addCurve(to: CGPoint(x: rect.width * 0.505, y: rect.height * 0.854),
                          control1: CGPoint(x: rect.width * 0.68, y: rect.height * 0.847),
                          control2: CGPoint(x: rect.width * 0.59, y: rect.height * 0.856))
            path.addCurve(to: CGPoint(x: rect.width * 0.255, y: rect.height * 0.829),
                          control1: CGPoint(x: rect.width * 0.425, y: rect.height * 0.855),
                          control2: CGPoint(x: rect.width * 0.33, y: rect.height * 0.844))
            path.addCurve(to: CGPoint(x: 0, y: rect.height * 0.770),
                          control1: CGPoint(x: rect.width * 0.16, y: rect.height * 0.810),
                          control2: CGPoint(x: rect.width * 0.07, y: rect.height * 0.790))
            path.closeSubpath()
        }
    }
}

private extension ShuPoint {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

private struct ShuSceneExclusion: Shape {
    let excluded: CGRect
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(excluded)
        return path
    }
}

/// Round the retained ankle pixels into the turning shin. The full-width lower
/// part leaves the original toe and sole alpha untouched.
private struct ShuFootCapMask: Shape {
    let ankleX: CGFloat
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width * 0.25, rect.height * 0.36)
        var path = Path(ellipseIn: CGRect(x: rect.width * ankleX - radius, y: 0,
                                         width: radius * 2, height: radius * 2))
        path.addRect(CGRect(x: rect.minX, y: radius, width: rect.width,
                            height: max(0, rect.height - radius)))
        return path
    }
}

enum ShuPuppetDepth { case rear, torso, nearArm, fingers }

enum ShuPreviewArmVisibility {
    case both, nearOnly, farOnly, none
    var showsNear: Bool { self == .both || self == .nearOnly }
    var showsFar: Bool { self == .both || self == .farOnly }
}

/// Rendering-only elapsed time. Repeated availability notifications do not reset
/// the phase, and paused/hidden time is never added on resumption.
struct ShuAmbientClock {
    private(set) var accumulated: TimeInterval = 0
    private(set) var startedAt: TimeInterval?

    mutating func setRunning(_ running: Bool, at now: TimeInterval) {
        guard now.isFinite else { return }
        if running {
            if startedAt == nil { startedAt = now }
        } else if startedAt != nil {
            accumulated = elapsed(at: now)
            startedAt = nil
        }
    }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        guard let startedAt, now.isFinite else { return accumulated }
        return accumulated + max(0, now - startedAt)
    }
}

enum ShuSkyLayout {
    struct CloudLayer {
        let center: CGPoint
        let size: CGSize
        let amplitude, period, phase, opacity: Double
    }
    static let clouds = [
        CloudLayer(center: CGPoint(x: 192, y: 35), size: CGSize(width: 36, height: 17),
                   amplitude: 4, period: 20, phase: 1.7, opacity: 0.63),
        CloudLayer(center: CGPoint(x: 146, y: 24), size: CGSize(width: 49, height: 24),
                   amplitude: 8, period: 30, phase: 4.1, opacity: 0.87),
        CloudLayer(center: CGPoint(x: 40, y: 34), size: CGSize(width: 44, height: 23),
                   amplitude: 12, period: 60, phase: 0.35, opacity: 0.95)
    ]

    static func cloudPosition(index: Int, time: Double, reduceMotion: Bool = false) -> CGPoint {
        let cloud = clouds[min(clouds.count - 1, max(0, index))]
        let time = !reduceMotion && time.isFinite ? max(0, time) : 0
        let phase = time * 2 * .pi / cloud.period + cloud.phase
        return CGPoint(x: cloud.center.x + cloud.amplitude * sin(phase),
                       y: cloud.center.y + 0.7 * cos(phase + 0.6))
    }
}

private struct ShuCloudSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        return Path { path in
            path.move(to: point(0.18, 0.89))
            path.addCurve(to: point(0.07, 0.43), control1: point(-0.03, 0.88), control2: point(-0.01, 0.51))
            path.addCurve(to: point(0.27, 0.38), control1: point(0.13, 0.34), control2: point(0.21, 0.33))
            path.addCurve(to: point(0.59, 0.13), control1: point(0.29, 0.04), control2: point(0.50, -0.04))
            path.addCurve(to: point(0.80, 0.38), control1: point(0.72, 0.12), control2: point(0.80, 0.22))
            path.addCurve(to: point(0.97, 0.61), control1: point(0.94, 0.34), control2: point(1.01, 0.47))
            path.addCurve(to: point(0.82, 0.89), control1: point(1.00, 0.79), control2: point(0.93, 0.90))
            path.addCurve(to: point(0.18, 0.89), control1: point(0.67, 0.98), control2: point(0.33, 0.96))
            path.closeSubpath()
        }
    }
}

private struct ShuSoftCloud: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ShuCloudSilhouette().fill(LinearGradient(
                    colors: [.white, Color(red: 0.98, green: 0.97, blue: 0.92),
                             Color(red: 0.89, green: 0.88, blue: 0.82)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Ellipse().fill(.white.opacity(0.78))
                    .frame(width: geometry.size.width * 0.34, height: geometry.size.height * 0.40)
                    .blur(radius: 1.1)
                    .position(x: geometry.size.width * 0.45, y: geometry.size.height * 0.28)
                Ellipse().fill(.white.opacity(0.54))
                    .frame(width: geometry.size.width * 0.25, height: geometry.size.height * 0.27)
                    .blur(radius: 1)
                    .position(x: geometry.size.width * 0.74, y: geometry.size.height * 0.49)
            }
            .clipShape(ShuCloudSilhouette())
            .overlay(ShuCloudSilhouette().stroke(.white.opacity(0.40), lineWidth: 0.45))
            .shadow(color: Color(red: 0.57, green: 0.50, blue: 0.36).opacity(0.12), radius: 1.5, x: 0, y: 1.4)
        }.accessibilityHidden(true)
    }
}

/// Shared with the offline pixel verifier. Width stays stable while the two
/// authored landmarks still land exactly on the sampled shoulder and grip.
@MainActor enum ShuArmSpriteLayout {
    struct Mapping {
        let size: CGSize
        let rotation: Double
        let pivot: UnitPoint
    }
    static let width: CGFloat = 13.6

    static func mapping(_ pose: ShuArmPose) -> Mapping {
        let pivot = Shu25DAssets.pivot(.shortArm), grip = Shu25DAssets.end(.shortArm)
        let delta = pose.wrist - pose.shoulder
        let distance = delta.length
        let authoredX = grip.x - pivot.x, authoredY = grip.y - pivot.y
        // The generated arm is slightly slanted. Solve its actual rendered
        // vector, rather than treating a nonvertical bitmap as a vertical rod.
        let fittedWidth = min(width, distance / max(0.001, abs(authoredX)))
        let dx = fittedWidth * authoredX
        let height = sqrt(max(0, distance * distance - dx * dx)) / max(0.001, abs(authoredY))
        let dy = height * authoredY
        let rotation = (atan2(delta.y, delta.x) - atan2(dy, dx)) * 180 / .pi
        return Mapping(size: CGSize(width: fittedWidth, height: height), rotation: rotation, pivot: pivot)
    }
}

@MainActor private enum ShuLegSpriteLayout {
    static func size(_ asset: Shu25DAsset, actorScale: Double) -> CGSize {
        let source = Shu25DAssets.image(asset)?.size ?? CGSize(width: 22, height: 42)
        let hip = Shu25DAssets.pivot(asset), ankle = Shu25DAssets.end(asset)
        let span = hypot(source.width * (ankle.x - hip.x), source.height * (ankle.y - hip.y))
        let scale = 29 * actorScale / max(0.001, span)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}

/// Each arm is one continuous rounded sleeve/arm/hand image. Its two measured
/// endpoints bind directly to shoulder and grip, without a visible elbow or wrist
/// assembly. Only a small foreground finger layer can cover a held object.
struct ShuPuppetLayer: View {
    let sample: ShuAnimationSample
    let depth: ShuPuppetDepth
    var armVisibility: ShuPreviewArmVisibility = .both
    private var rig: ShuRigSample { sample.rig }
    private var actorScale: Double { rig.actor.scale }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch depth {
            case .rear:
                leg(.legFar, pose: rig.farFoot, far: true)
                leg(.legNear, pose: rig.nearFoot, far: false)
                if armVisibility.showsFar { arm(rig.farArm, far: true) }
            case .torso:
                let size = Shu25DAssets.size(.captainBase, fitting: CGSize(width: 168, height: 214))
                let center = rig.actor.worldPoint(local: ShuPoint(x: 90, y: 110))
                ShuSprite(asset: .captainBase)
                    .frame(width: size.width * actorScale, height: size.height * actorScale)
                    .mask(ShuTorsoMask())
                    .rotationEffect(.degrees(rig.actor.rotation))
                    .position(center.cgPoint)
            case .nearArm:
                if armVisibility.showsNear { arm(rig.nearArm, far: false) }
            case .fingers:
                if armVisibility.showsNear && hasHeldObject {
                    frontFingers(at: rig.nearArm.wrist, rotation: rig.nearArm.palmRotation,
                                 grip: rig.nearArm.gripClosed)
                }
            }
        }
        .frame(width: 324, height: 186)
        .accessibilityHidden(true)
    }

    private func arm(_ pose: ShuArmPose, far: Bool) -> some View {
        let mapping = ShuArmSpriteLayout.mapping(pose)
        // This is one complete sleeve/arm/hand bitmap. Only its length changes
        // within Core's short reach limits; it never grows a wider palm.
        return limbImage(.shortArm)
            .frame(width: mapping.size.width, height: mapping.size.height)
            .brightness(far ? -0.035 : 0).saturation(far ? 0.90 : 1)
            .rotationEffect(.degrees(mapping.rotation), anchor: mapping.pivot)
            .position(x: pose.shoulder.x + mapping.size.width * (0.5 - mapping.pivot.x),
                      y: pose.shoulder.y + mapping.size.height * (0.5 - mapping.pivot.y))
    }

    private var hasHeldObject: Bool {
        rig.hoe.opacity > 0.001 || rig.wateringCan.opacity > 0.001
            || (rig.plantPotato.opacity > 0.001 && rig.plantPotato.attachment == .hand)
            || (rig.potato.opacity > 0.001
                && (rig.potato.attachment == .hand || rig.potato.attachment == .roastingRack))
    }

    private func frontFingers(at point: ShuPoint, rotation: Double, grip: Double) -> some View {
        let pivot = Shu25DAssets.pivot(.fingersFront)
        let size = CGSize(width: 15 * actorScale, height: 18 * actorScale)
        let opening = 1 - min(1, max(0, grip))
        let release = ShuPoint(x: 3 * opening * actorScale).rotated(degrees: rotation)
        return ShuSprite(asset: .fingersFront).frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(rotation - 18 * opening), anchor: pivot)
            .position(x: point.x + release.x + size.width * (0.5 - pivot.x),
                      y: point.y + release.y + size.height * (0.5 - pivot.y))
    }

    /// The shin turns with the hip-to-ankle segment; the separately masked foot
    /// remains level during support. Both pieces use the very same ankle point.
    private func leg(_ asset: Shu25DAsset, pose: ShuLegPose, far: Bool) -> some View {
        let mapping = spriteMapping(asset, from: pose.hip, to: pose.ankle)
        let footSize = ShuLegSpriteLayout.size(asset, actorScale: actorScale)
        // A crouch may shorten the shin projection; it must not shrink the foot.
        let shinSize = CGSize(width: footSize.width, height: mapping.size.height)
        let hip = Shu25DAssets.pivot(asset)
        let ankle = Shu25DAssets.end(asset)
        let split = max(0.1, min(0.95, ankle.y - 0.13))
        return ZStack(alignment: .topLeading) {
            limbImage(asset).frame(width: shinSize.width, height: shinSize.height)
                .mask(alignment: .top) { Rectangle().frame(height: shinSize.height * min(1, ankle.y + 0.025)) }
                .rotationEffect(.degrees(mapping.angle), anchor: hip)
                .position(x: pose.hip.x + shinSize.width * (0.5 - hip.x),
                          y: pose.hip.y + shinSize.height * (0.5 - hip.y))
            ShuSprite(asset: asset).frame(width: footSize.width, height: footSize.height)
                .mask(alignment: .bottom) {
                    ShuFootCapMask(ankleX: ankle.x).frame(height: footSize.height * (1 - split))
                }
                .rotationEffect(.degrees(pose.footRotation), anchor: ankle)
                .position(x: pose.ankle.x + footSize.width * (0.5 - ankle.x),
                          y: pose.ankle.y + footSize.height * (0.5 - ankle.y))
        }.brightness(far ? -0.04 : 0)
    }

    @ViewBuilder private func limbImage(_ asset: Shu25DAsset) -> some View {
        if let image = Shu25DAssets.image(asset) {
            Image(nsImage: image).resizable()
        } else { ShuSprite(asset: asset) }
    }

    private func spriteMapping(_ asset: Shu25DAsset, from start: ShuPoint, to end: ShuPoint) -> (size: CGSize, angle: Double) {
        let source = Shu25DAssets.image(asset)?.size ?? CGSize(width: 22, height: 42)
        let pivot = Shu25DAssets.pivot(asset), tip = Shu25DAssets.end(asset)
        let sx = source.width * (tip.x - pivot.x), sy = source.height * (tip.y - pivot.y)
        let dx = end.x - start.x, dy = end.y - start.y
        let scale = hypot(dx, dy) / max(0.001, hypot(sx, sy))
        return (CGSize(width: source.width * scale, height: source.height * scale),
                (atan2(dy, dx) - atan2(sy, sx)) * 180 / .pi)
    }
}

/// Production prop layer, also used by the isolated alpha-contact verifier.
struct ShuPotatoSprite: View {
    let pose: ShuPropPose
    var roastedMix: Double = 0
    var body: some View {
        ZStack {
            ShuSprite(asset: .rawPotato).opacity(1 - roastedMix)
            ShuSprite(asset: .roastPotato).opacity(roastedMix)
        }
        .frame(width: pose.width, height: pose.height)
        .rotationEffect(.degrees(pose.rotation))
        .opacity(pose.opacity)
        .position(pose.position.cgPoint)
        .frame(width: 324, height: 186, alignment: .topLeading)
    }
}

/// Standalone artwork previews share the production articulated pose.
private struct ShuPuppet: View {
    let sample: ShuAnimationSample
    var resting = false
    var body: some View {
        GeometryReader { geometry in
            let scale = sample.rig.actor.scale
            let bounds = CGRect(x: sample.rig.actor.foot.x - 90 * scale,
                                y: sample.rig.actor.foot.y - 210 * scale,
                                width: 180 * scale, height: 220 * scale)
            let fit = min(geometry.size.width / bounds.width, geometry.size.height / bounds.height)
            ZStack(alignment: .topLeading) {
                ShuPuppetLayer(sample: sample, depth: .rear)
                ShuPuppetLayer(sample: sample, depth: .torso)
                ShuPuppetLayer(sample: sample, depth: .nearArm)
                ShuPuppetLayer(sample: sample, depth: .fingers)
            }
            .frame(width: 324, height: 186)
            .offset(x: -bounds.minX, y: -bounds.minY)
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .scaleEffect(fit, anchor: .topLeading)
            .offset(x: (geometry.size.width - bounds.width * fit) / 2,
                    y: (geometry.size.height - bounds.height * fit) / 2)
        }.accessibilityHidden(true)
    }
}

struct PotatoGardenScene: View {
    let activity: GardenActivity
    let elapsed: Double
    let inventory: Int
    let isRunning: Bool
    let harvestPulse: UUID?
    var harvestCount: Int = 0
    var isVisible = true
    var maximumElapsed: Double = .infinity
    /// Used only by the static renderer to select exact timeline samples.
    var previewElapsed: Double?
    /// Offline QA can inspect the system setting's rendering branch without
    /// changing accessibility preferences or installing an application.
    var previewReduceMotion: Bool?
    var previewSkyTime: Double?
    var previewArmVisibility: ShuPreviewArmVisibility = .both
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { previewReduceMotion ?? systemReduceMotion }
    @State private var pop = false
    @State private var sampledAt = Date()
    @State private var ambientClock = ShuAmbientClock()
    private var ambientMotionAllowed: Bool { isVisible && !reduceMotion && (isRunning || activity == .idle) }

    var body: some View {
        Group {
            if isVisible {
                TimelineView(.animation(minimumInterval: isRunning && (activity == .planting || activity == .roasting) ? 1.0 / 30 : 1.0 / 15,
                                        paused: !ambientMotionAllowed || previewElapsed != nil || previewSkyTime != nil)) { timeline in
                    let extrapolated = ShuAnimationTimeline.renderElapsed(
                        authoritative: elapsed, sampledAt: sampledAt.timeIntervalSinceReferenceDate,
                        frameTime: timeline.date.timeIntervalSinceReferenceDate,
                        running: isRunning, visible: isVisible, reduceMotion: reduceMotion) ?? elapsed
                    let current = previewElapsed ?? min(max(0, maximumElapsed - 0.000_1), extrapolated)
                    let sample = ShuAnimationTimeline.sample(elapsed: current, inventory: inventory, reduceMotion: reduceMotion)
                    let skyTime = previewSkyTime ?? (previewElapsed != nil ? current : ambientClock.elapsed(at: timeline.date.timeIntervalSinceReferenceDate))
                    scene(sample: sample, skyTime: skyTime)
                }
            } else {
                // Offscreen content contains no Canvas, image layers or timeline.
                Color.clear
            }
        }
        .frame(width: 324, height: 186)
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(ShuPalette.ink.opacity(0.09), lineWidth: 1))
        .onAppear { ambientClock.setRunning(ambientMotionAllowed, at: Date().timeIntervalSinceReferenceDate) }
        .onChange(of: ambientMotionAllowed) {
            ambientClock.setRunning(ambientMotionAllowed, at: Date().timeIntervalSinceReferenceDate)
        }
        .onDisappear { ambientClock.setRunning(false, at: Date().timeIntervalSinceReferenceDate) }
        .onChange(of: elapsed) { sampledAt = Date() }
        .onChange(of: isRunning) { sampledAt = Date() }
        .onChange(of: isVisible) { sampledAt = Date() }
        .task(id: harvestPulse) {
            guard harvestPulse != nil, isVisible else { pop = false; return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { pop = true }
            do { try await Task.sleep(for: .milliseconds(1600)) } catch { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { pop = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L(activity == .planting ? "Captain Shu is planting" : activity == .roasting ? "Captain Shu is roasting" : "Captain Shu is resting")))
        .accessibilityValue(Text(String(format: L("Stock: %lld"), inventory)))
    }

    private func scene(sample: ShuAnimationSample, skyTime: Double) -> some View {
        let working = activity == .planting || activity == .roasting
        let rig = sample.rig
        return ZStack(alignment: .topLeading) {
            landscape(time: skyTime)
            inventoryGround
            if working {
                footShadows(sample: sample)
                ForEach(0..<3) { index in
                    ShuSprite(asset: .seedling).frame(width: 23, height: 28)
                        .scaleEffect(sample.seedlingScale, anchor: .bottom)
                        .opacity(sample.seedlingOpacity)
                        .position(x: rig.stations.soil.x - 16 + Double(index) * 16,
                                  y: rig.stations.soil.y - 10 - Double(index % 2) * 3)
                }
                // Keep the logs behind the walking lane. The held potato uses
                // its independent world rack point and does not move with this art offset.
                fire(sample: sample).position(x: rig.stations.fire.x, y: rig.stations.fire.y - 10)
                ShuPuppetLayer(sample: sample, depth: .rear, armVisibility: previewArmVisibility)
                ShuPuppetLayer(sample: sample, depth: .torso, armVisibility: previewArmVisibility)
                ShuPuppetLayer(sample: sample, depth: .nearArm, armVisibility: previewArmVisibility)
                    .mask { soilMask(sample: sample) }
                tools(sample: sample)
                potato(sample.rig.plantPotato, roastedMix: 0)
                    .mask { soilMask(sample: sample) }
                if sample.stage == .roast {
                    // A short roasting stick has two physical endpoints. The rig
                    // constrains their separation; this is not a wrist-to-world tween.
                    Path { path in
                        path.move(to: rig.nearArm.wrist.cgPoint)
                        path.addLine(to: rig.potato.position.cgPoint)
                    }.stroke(Color(red: 0.45, green: 0.28, blue: 0.15),
                             style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                potato(rig.potato, roastedMix: min(1, max(0, (sample.cycleTime - 33) / 15)))
                    .mask { soilMask(sample: sample) }
                ShuPuppetLayer(sample: sample, depth: .fingers, armVisibility: previewArmVisibility)
                    .mask { soilMask(sample: sample) }
                if rig.potato.opacity > 0 {
                    steam(sample: sample)
                        .opacity(rig.potato.opacity)
                        .position(x: rig.potato.position.x,
                                  y: rig.potato.position.y - rig.potato.height / 2 - 3)
                }
                if sample.stage == .plant, sample.rig.plantPotato.opacity > 0,
                   sample.rig.plantPotato.burial > 0 {
                    // Local earth lip: only the burial site occludes the potato,
                    // without dimming/scaling the seed or redrawing the whole ground.
                    Ellipse().fill(Color(red: 0.64, green: 0.47, blue: 0.28).opacity(0.75))
                        .frame(width: 32, height: 3).position(x: rig.stations.soil.x, y: rig.stations.soil.y + 1.5)
                }
            } else {
                idleCaptain
            }
            inventoryLabels
        }.frame(width: 324, height: 186)
    }

    private var idleCaptain: some View {
        // Finishing, idling and starting all use the same body, feet and home
        // joint sample. A differently proportioned hero image never replaces it.
        let sample = ShuAnimationTimeline.sample(elapsed: 0, inventory: inventory)
        return ZStack(alignment: .topLeading) {
            footShadows(sample: sample)
            ShuPuppetLayer(sample: sample, depth: .rear, armVisibility: previewArmVisibility)
            ShuPuppetLayer(sample: sample, depth: .torso, armVisibility: previewArmVisibility)
            ShuPuppetLayer(sample: sample, depth: .nearArm, armVisibility: previewArmVisibility)
            ShuPuppetLayer(sample: sample, depth: .fingers, armVisibility: previewArmVisibility)
        }.frame(width: 324, height: 186)
    }

    private func footShadows(sample: ShuAnimationSample) -> some View {
        let rig = sample.rig
        return ZStack {
            ForEach(0..<2) { index in
                let foot = index == 0 ? rig.farFoot : rig.nearFoot
                let asset: Shu25DAsset = index == 0 ? .legFar : .legNear
                let size = ShuLegSpriteLayout.size(asset, actorScale: rig.actor.scale)
                let ankle = Shu25DAssets.end(asset)
                let bounds = Shu25DAssets.contentBounds(asset)
                Ellipse().fill(ShuPalette.ink.opacity(foot.isPlanted ? 0.16 : 0.09))
                    .frame(width: foot.isPlanted ? 19 : 16, height: 5)
                    .blur(radius: foot.isPlanted ? 1.4 : 2.5)
                    .position(x: foot.ankle.x + size.width * (bounds.midX - ankle.x),
                              y: foot.ankle.y + foot.lift + size.height * (bounds.maxY - ankle.y))
            }
        }.frame(width: 324, height: 186)
    }

    private func potato(_ pose: ShuPropPose, roastedMix: Double) -> some View {
        ShuPotatoSprite(pose: pose, roastedMix: roastedMix)
    }

    private func tools(sample: ShuAnimationSample) -> some View {
        let rig = sample.rig
        let canSize = Shu25DAssets.size(.wateringCan, fitting: CGSize(width: 36, height: 29))
        let canPivot = Shu25DAssets.pivot(.wateringCan)
        let emitter = Shu25DAssets.emitter(.wateringCan)
        let sprayOrigin = attachedPoint(CGPoint(x: canSize.width * (emitter.x - canPivot.x),
                                                y: canSize.height * (emitter.y - canPivot.y)),
                                       origin: rig.wateringCan.grip.cgPoint, angle: rig.wateringCan.rotation)
        return ZStack(alignment: .topLeading) {
            attachedTool(.hoe, pose: rig.hoe, limit: CGSize(width: 22, height: 43))
            attachedTool(.wateringCan, pose: rig.wateringCan, limit: CGSize(width: 36, height: 29))
            waterDrops(sample: sample, origin: sprayOrigin)
        }.frame(width: 324, height: 186)
    }

    private func attachedTool(_ asset: Shu25DAsset, pose: ShuToolPose, limit: CGSize) -> some View {
        let size = Shu25DAssets.size(asset, fitting: limit)
        let pivot = Shu25DAssets.pivot(asset)
        return ShuSprite(asset: asset).frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(pose.rotation), anchor: pivot)
            .opacity(pose.opacity)
            .position(x: pose.grip.x + size.width * (0.5 - pivot.x),
                      y: pose.grip.y + size.height * (0.5 - pivot.y))
    }

    @ViewBuilder private func soilMask(sample: ShuAnimationSample) -> some View {
        if (sample.stage == .plant && sample.rig.plantPotato.opacity > 0 && sample.rig.plantPotato.burial > 0)
            || (sample.stage == .pull && sample.rig.potato.burial > 0) {
            let soil = sample.rig.stations.soil
            ShuSceneExclusion(excluded: CGRect(x: soil.x - 24, y: soil.y, width: 48, height: 36))
                .fill(style: FillStyle(eoFill: true))
        } else { Rectangle() }
    }

    /// Stored potatoes belong to the ground behind the character. The incoming
    /// hand-held/cooling potato remains in the scene's separate prop depth pass.
    private var inventoryGround: some View {
        ZStack(alignment: .topLeading) {
            if inventory > 12 {
                RoastPotatoView().frame(width: 21, height: 16)
                    .position(x: ShuDeliveryLayout.destination(inventory: 12).x,
                              y: ShuDeliveryLayout.destination(inventory: 12).y)
            }
            ZStack(alignment: .topLeading) {
                ForEach(0..<12) { index in
                    let receiver = ShuDeliveryLayout.destination(inventory: index)
                    RoastPotatoView().frame(width: 21, height: 16)
                        .shadow(color: ShuPalette.ink.opacity(0.16), radius: 1, y: 1)
                        .opacity(index < inventory ? 1 : 0)
                        .position(x: receiver.x, y: receiver.y)
                }
            }.frame(width: 324, height: 186)
                .scaleEffect(pop && !reduceMotion ? 1.06 : 1, anchor: UnitPoint(x: 270.0 / 324, y: 167.0 / 186))
        }.frame(width: 324, height: 186)
    }

    private var inventoryLabels: some View {
        ZStack(alignment: .topLeading) {
            Text(String(format: L("Stock: %lld"), inventory))
                .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(ShuPalette.ink)
                .frame(width: 86, height: 14, alignment: .trailing).position(x: 270, y: 18)
            if pop && harvestCount > 0 {
                Text(String(format: L("Harvest +%lld"), harvestCount)).font(.system(size: 9, weight: .bold)).foregroundStyle(ShuPalette.peel)
                    .frame(width: 86, height: 11, alignment: .trailing).position(x: 270, y: inventory > 12 ? 94 : 75)
            }
            if inventory > 12 {
                Text("+\(inventory - 12)").font(.system(size: 9, weight: .semibold)).foregroundStyle(ShuPalette.peel)
                    .frame(width: 61, height: 16, alignment: .trailing).position(x: 257.5, y: 35)
            }
        }.frame(width: 324, height: 186)
    }

    private func landscape(time: Double) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.99, green: 0.95, blue: 0.85), Color(red: 0.96, green: 0.90, blue: 0.73)], startPoint: .top, endPoint: .bottom)
            softSun.position(x: 270, y: 43)
            ForEach(0..<ShuSkyLayout.clouds.count, id: \.self) { index in
                let cloud = ShuSkyLayout.clouds[index]
                ShuSoftCloud().frame(width: cloud.size.width, height: cloud.size.height)
                    .opacity(cloud.opacity)
                    .position(ShuSkyLayout.cloudPosition(index: index, time: time, reduceMotion: reduceMotion))
            }
            if Shu25DAssets.image(.ground) != nil {
                ShuSprite(asset: .ground).frame(width: 366, height: 157).position(x: 191, y: 136)
            } else {
              Ellipse().fill(LinearGradient(colors: [Color(red: 0.76, green: 0.83, blue: 0.59), Color(red: 0.66, green: 0.75, blue: 0.48)], startPoint: .top, endPoint: .bottom))
                .frame(width: 445, height: 135).position(x: 178, y: 164)
            Ellipse().fill(Color(red: 0.55, green: 0.37, blue: 0.24).opacity(0.16)).frame(width: 218, height: 49).blur(radius: 4).position(x: 137, y: 154)
            Ellipse().fill(LinearGradient(colors: [Color(red: 0.75, green: 0.57, blue: 0.38), Color(red: 0.61, green: 0.42, blue: 0.27)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 218, height: 42).position(x: 137, y: 149)
            ForEach(0..<4) { index in
                Capsule().fill(ShuPalette.ink.opacity(0.12)).frame(width: 2, height: 21).rotationEffect(.degrees(25))
                    .position(x: 80 + Double(index) * 33, y: 150)
            }
            }
        }
    }

    private var softSun: some View {
        ZStack {
            Circle().fill(RadialGradient(
                colors: [Color(red: 1, green: 0.79, blue: 0.39).opacity(0.26),
                         Color(red: 1, green: 0.87, blue: 0.60).opacity(0.10), .clear],
                center: .center, startRadius: 4, endRadius: 32))
                .frame(width: 64, height: 64)
            Circle().fill(LinearGradient(
                colors: [Color(red: 1, green: 0.97, blue: 0.78), Color(red: 1, green: 0.81, blue: 0.44)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white.opacity(0.32), lineWidth: 0.6))
                .shadow(color: Color(red: 1, green: 0.84, blue: 0.47).opacity(0.35), radius: 4)
            Ellipse().fill(.white.opacity(0.5)).frame(width: 8, height: 4)
                .blur(radius: 1.2).offset(x: -3, y: -5)
        }.frame(width: 64, height: 64).accessibilityHidden(true)
    }

    private func fire(sample: ShuAnimationSample) -> some View {
        ZStack(alignment: .bottom) {
            Ellipse().fill(ShuPalette.flesh.opacity(sample.fireAmount * 0.28)).frame(width: 58, height: 20).blur(radius: 5)
            ShuSprite(asset: .firepit).frame(width: 50, height: 21)
            ForEach(0..<3) { index in
                let pulse = reduceMotion ? 1 : 0.90 + 0.10 * sin(sample.cycleTime * 4 + Double(index) * 1.7)
                Image(systemName: "flame.fill").resizable().scaledToFit()
                    .foregroundStyle(LinearGradient(colors: index == 1
                        ? [Color(red: 1, green: 0.96, blue: 0.69), ShuPalette.flesh]
                        : [Color(red: 1, green: 0.77, blue: 0.40), Color(red: 0.92, green: 0.39, blue: 0.18)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: index == 1 ? 20 : 27, height: index == 1 ? 32 : 40)
                    .scaleEffect(x: 1, y: pulse, anchor: .bottom)
                    .offset(x: Double(index - 1) * 10, y: -8)
                    .blur(radius: 0.35)
                    .shadow(color: ShuPalette.flesh.opacity(0.25), radius: 2)
            }
        }.frame(width: 60, height: 57).opacity(sample.fireAmount)
    }

    private func waterDrops(sample: ShuAnimationSample, origin: CGPoint) -> some View {
        ForEach(0..<7) { index in
            let travel = reduceMotion ? Double(index) / 7 : (sample.cycleTime * 1.5 + Double(index) / 7).truncatingRemainder(dividingBy: 1)
            Ellipse().fill(Color(red: 0.34, green: 0.67, blue: 0.83).opacity(0.70))
                .frame(width: 2.5, height: 4).rotationEffect(.degrees(-17))
                .position(x: origin.x + travel * 9, y: origin.y + travel * 22)
                .opacity(sample.waterAmount * sin(travel * .pi))
        }
    }

    private func steam(sample: ShuAnimationSample) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                let phase = reduceMotion ? Double(index) / 3 : (sample.cycleTime / 2.4 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                Capsule().fill(.white.opacity(0.7)).frame(width: 3, height: 12)
                    .blur(radius: 1.2).offset(x: sin(phase * .pi * 2) * 3, y: -phase * 18)
                    .opacity(sin(phase * .pi) * sample.steamAmount)
            }
        }.frame(width: 28, height: 26)
    }

    private func attachedPoint(_ point: CGPoint, origin: CGPoint, angle: Double) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: origin.x + cos(radians) * point.x - sin(radians) * point.y,
                       y: origin.y + sin(radians) * point.x + cos(radians) * point.y)
    }
}
