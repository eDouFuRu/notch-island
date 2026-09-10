import Foundation

/// A deterministic animation clock. It never awards potatoes or writes session state.
public enum ShuGardenStage: String, CaseIterable, Codable {
    case hoe, plant, water, pull, turn, roast, carry, place, returnHome

    public var interval: Range<Double> {
        switch self {
        case .hoe: return 0..<6
        case .plant: return 6..<12
        case .water: return 12..<23
        case .pull: return 23..<30
        case .turn: return 30..<33
        case .roast: return 33..<51
        case .carry: return 51..<54
        case .place: return 54..<56
        case .returnHome: return 56..<60
        }
    }
}

public struct ShuLayerPose: Equatable {
    public var x: Double = 0
    public var y: Double = 0
    public var rotation: Double = 0
    public var scale: Double = 1
    public var opacity: Double = 1
}

public struct ShuAnimationSample: Equatable {
    public let cycleTime: Double
    public let stage: ShuGardenStage
    public let stageProgress: Double
    public let rig: ShuRigSample
    /// Legacy adapters retained for callers outside the layered scene.
    public let body: ShuLayerPose
    public let nearArmAngle: Double
    public let farArmAngle: Double
    public let hoe: ShuLayerPose
    public let wateringCan: ShuLayerPose
    public let potato: ShuLayerPose
    public let seedlingScale: Double
    public let seedlingOpacity: Double
    public let waterAmount: Double
    public let fireAmount: Double
    public let steamAmount: Double
}

/// Shared by the uncredited cooling visual and its inventory receiver.
public enum ShuDeliveryLayout {
    public struct Sample: Equatable {
        public let x, y, width, height, receiverFade: Double
    }
    public static func destination(inventory: Int) -> ShuLayerPose {
        let occupied = max(0, inventory)
        // Overflow is a physical ground pile; the elevated counter is only a label.
        if occupied >= 12 { return ShuLayerPose(x: 298, y: 168) }
        return ShuLayerPose(x: 302 - Double(occupied % 4) * 21,
                            y: 159 - Double(occupied / 4) * 14)
    }
    public static func sample(cycleTime: Double, inventory: Int) -> Sample {
        let time = min(60, max(0, cycleTime.isFinite ? cycleTime : 54))
        let stage = ShuGardenStage.allCases.first { $0.interval.contains(time) } ?? .returnHome
        let pose = ShuRigLayout.sample(time: time, stage: stage, inventory: inventory, reduceMotion: false).potato
        return Sample(x: pose.position.x, y: pose.position.y, width: pose.width, height: pose.height,
                      receiverFade: inventory > 12 ? smooth((time - 55.4) / 0.3) : 0)
    }
    private static func smooth(_ value: Double) -> Double {
        let v = min(1, max(0, value)); return v * v * (3 - 2 * v)
    }
}

public enum ShuAnimationTimeline {
    public static let duration: Double = 60

    /// Extrapolate between 250 ms timer snapshots; paused/hidden frames cannot advance.
    public static func renderElapsed(authoritative: Double, sampledAt: Double, frameTime: Double,
                                     running: Bool, visible: Bool, reduceMotion: Bool = false) -> Double? {
        guard visible else { return nil }
        let base = authoritative.isFinite ? max(0, authoritative) : 0
        guard running, !reduceMotion, sampledAt.isFinite, frameTime.isFinite else { return base }
        return base + min(0.5, max(0, frameTime - sampledAt))
    }

    public static func sample(elapsed: Double, inventory: Int = 0, reduceMotion: Bool = false) -> ShuAnimationSample {
        let safe = elapsed.isFinite ? max(0, elapsed) : 0
        let t = safe.truncatingRemainder(dividingBy: duration)
        let stage = ShuGardenStage.allCases.first { $0.interval.contains(t) } ?? .hoe
        let progress = (t - stage.interval.lowerBound) / (stage.interval.upperBound - stage.interval.lowerBound)
        let rig = ShuRigLayout.sample(time: t, stage: stage, inventory: inventory, reduceMotion: reduceMotion)
        let poseTime = rig.poseTime
        let home = rig.stations.fieldFoot
        return ShuAnimationSample(
            cycleTime: t, stage: stage, stageProgress: progress, rig: rig,
            body: ShuLayerPose(x: rig.actor.foot.x - home.x,
                               y: rig.actor.bodyOffset.y, rotation: rig.actor.rotation),
            nearArmAngle: rig.nearArm.upperRotation, farArmAngle: rig.farArm.upperRotation,
            hoe: ShuLayerPose(x: rig.hoe.grip.x, y: rig.hoe.grip.y,
                              rotation: rig.hoe.rotation, opacity: rig.hoe.opacity),
            wateringCan: ShuLayerPose(x: rig.wateringCan.grip.x, y: rig.wateringCan.grip.y,
                                      rotation: rig.wateringCan.rotation, opacity: rig.wateringCan.opacity),
            potato: ShuLayerPose(x: rig.potato.position.x - 149, y: rig.potato.position.y - 145,
                                 rotation: rig.potato.rotation, opacity: rig.potato.opacity),
            seedlingScale: 0.15 + 0.85 * smooth((poseTime - 10) / 13),
            seedlingOpacity: smooth((poseTime - 10.7) / 1.3) * (1 - smooth((poseTime - 26) / 3)),
            waterAmount: envelope(poseTime, start: 12, end: 23, fade: 0.75),
            fireAmount: envelope(poseTime, start: 30, end: 56, fade: 1.4),
            steamAmount: envelope(poseTime, start: 42, end: 60, fade: 1.2)
        )
    }
    private static func envelope(_ t: Double, start: Double, end: Double, fade: Double) -> Double {
        smooth((t - start) / fade) * (1 - smooth((t - end + fade) / fade))
    }
    private static func smooth(_ value: Double) -> Double {
        let v = min(1, max(0, value)); return v * v * (3 - 2 * v)
    }
}
