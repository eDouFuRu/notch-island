import Foundation

/// Scene coordinates use points, +x right, +y down. Angles are clockwise degrees.
public struct ShuPoint: Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
    public static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Self, b: Self) -> Self { Self(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: Self, b: Double) -> Self { Self(x: a.x * b, y: a.y * b) }
    public var length: Double { hypot(x, y) }
    public func rotated(degrees: Double) -> Self {
        let r = degrees * .pi / 180
        return Self(x: x * cos(r) - y * sin(r), y: x * sin(r) + y * cos(r))
    }
}

public struct ShuRect: Equatable {
    public var x, y, width, height: Double
    public var minX: Double { x }; public var maxX: Double { x + width }
    public var minY: Double { y }; public var maxY: Double { y + height }
    public func contains(_ point: ShuPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

public struct ShuActorPose: Equatable {
    /// Ground reference; unlike bodyOffset, this never bobs during a planted stance.
    public let foot: ShuPoint
    public let rotation: Double
    public let bodyOffset: ShuPoint
    public let scale: Double
    public let logicalFoot = ShuPoint(x: 90, y: 210)
    public func worldPoint(local: ShuPoint) -> ShuPoint {
        foot + (local - logicalFoot).rotated(degrees: rotation) * scale + bodyOffset
    }
}

public struct ShuArmPose: Equatable {
    public let shoulder, elbow, wrist: ShuPoint
    /// One continuous sleeve/arm/hand sprite; elbow is only a compatibility midpoint.
    public let upperRotation, forearmRotation, palmRotation: Double
    public let gripClosed: Double
    public var length: Double { (wrist - shoulder).length }
    public var rotation: Double { atan2(wrist.y - shoulder.y, wrist.x - shoulder.x) * 180 / .pi - 90 }
}

public struct ShuLegPose: Equatable {
    public let hip, knee, ankle: ShuPoint
    /// Whole-leg orientation relative to down. The foot remains level when planted.
    public let rotation, footRotation, lift: Double
    public let isPlanted: Bool
}

public struct ShuToolPose: Equatable {
    /// World coordinates. Render the sprite's grip pivot at grip, with this final rotation.
    public let grip, tip: ShuPoint
    public let rotation, opacity: Double
    public var emitter: ShuPoint { tip }
}

public enum ShuPropAttachment: String, Equatable {
    case hidden, hand, soil, roastingRack, coolingTray
}

public struct ShuPropPose: Equatable {
    public let position: ShuPoint
    public let width, height, rotation, opacity: Double
    /// Occlude behind the foreground soil; never shrink a planting potato to conceal it.
    public let burial: Double
    public let attachment: ShuPropAttachment
}

public struct ShuRigStations: Equatable {
    public let fieldFoot, fireFoot, productFoot, soil, fire, receiver: ShuPoint
}

public struct ShuRigSample: Equatable {
    public let actor: ShuActorPose
    public let nearArm, farArm: ShuArmPose
    public let nearFoot, farFoot: ShuLegPose
    public let hoe, wateringCan: ShuToolPose
    public let plantPotato, potato: ShuPropPose
    public let logoProtection: ShuRect
    public let stations: ShuRigStations
    public let walkDistance, walkAmount: Double
    /// Time used for poses; with Reduce Motion it is constant throughout a stage.
    public let poseTime: Double
}

/// Only deterministic presentation geometry. There is no timer, persistence or award here.
public enum ShuRigLayout {
    public static let actorScale = 124.0 / 180
    public static let nearShoulder = ShuPoint(x: 145, y: 132)
    // The torso's measured left alpha edge is x≈38.5 at this height. Place the
    // sleeve just inside that edge and let the small hand hang outside it.
    public static let farShoulder = ShuPoint(x: 40, y: 132)
    /// Measured in the aspect-fitted 634×1122 body, including a conservative margin.
    public static let logoLocal = ShuRect(x: 108, y: 111, width: 28, height: 20)
    public static let upperArmLength = 29.0
    public static let forearmLength = 31.0
    public static let maximumArmLength = 26.0
    public static let seedGripOffset = ShuPoint(x: 6, y: 3)
    public static let potatoGripOffset = ShuPoint(x: 6, y: 3)
    /// Measured from the imported PNG grip pivot at the renderer's aspect-fitted size.
    public static let hoeTipLocal = ShuPoint(x: 4.912879304663041, y: 26.33565873702422)
    public static let canEmitterLocal = ShuPoint(x: 16.336140314136127, y: 10.167248167539265)

    public static func stations(inventory: Int) -> ShuRigStations {
        let receiver = ShuDeliveryLayout.destination(inventory: inventory)
        return ShuRigStations(fieldFoot: ShuPoint(x: 64, y: 166),
                              fireFoot: ShuPoint(x: 139, y: 166),
                              productFoot: ShuPoint(x: receiver.x - 52, y: 166),
                              soil: ShuPoint(x: 118, y: 150),
                              fire: ShuPoint(x: 194, y: 147),
                              receiver: ShuPoint(x: receiver.x, y: receiver.y))
    }

    public static func sample(time: Double, stage: ShuGardenStage, inventory: Int, reduceMotion: Bool) -> ShuRigSample {
        let safeTime = time.isFinite ? min(60, max(0, time)) : 0
        let t = reduceMotion ? (stage.interval.lowerBound + stage.interval.upperBound) / 2 : safeTime
        let site = stations(inventory: inventory)
        let walk = walkSample(time: t, stations: site, reduceMotion: reduceMotion)
        let work = envelope(t, 0, 6, 0.55)
        let stroke = reduceMotion ? 0 : keyframe(t.truncatingRemainder(dividingBy: 2) / 2,
            [(0, 0), (0.30, -1), (0.48, 1), (0.61, 0.72), (0.84, 0.08), (1, 0)]) * work
        let plantCrouch = 4 * envelope(t, 7.2, 11.9, 1.1)
        let pullCrouch = keyframe(t, [(0, 0), (23, 0), (24.3, 3), (26.5, 0), (60, 0)])
        let placeCrouch = max(0, site.receiver.y - 159) * envelope(t, 54, 56.8, 0.75)
        let walkingLean = reduceMotion ? 0 : walk.direction * 1.5 * walk.amount + stroke * 0.8
        let placeLean = 14 * smooth((site.receiver.y - 131) / 28) * envelope(t, 54, 56.8, 0.75)
        let lean = walkingLean + placeLean
        // Bend toward the receiver about the hips, keeping the planted legs fixed.
        let hip = ShuPoint(y: -29 * actorScale)
        let hipCompensation = hip.rotated(degrees: walkingLean) - hip.rotated(degrees: lean)
        let actor = ShuActorPose(foot: walk.root, rotation: lean,
                                 bodyOffset: hipCompensation + ShuPoint(y: 9 + plantCrouch + pullCrouch + placeCrouch), scale: actorScale)

        // Targets stay in the side working space. The torso/logo is never mirrored.
        let hoeAngle = stroke < 0 ? stroke * 65 : stroke * 6
        // Keep the wrist to the side and below the lowered shoulder. Near-zero
        // shoulder/wrist separation would produce an implausibly fast folded elbow.
        let hoeHome = ShuPoint(x: 49, y: -41)
        let impactWorld = site.soil - hoeTipLocal.rotated(degrees: 6 + actor.rotation)
        let impact = (impactWorld - walk.root).rotated(degrees: -actor.rotation)
        let hoeHand = stroke < 0
            ? mix(hoeHome, ShuPoint(x: 52, y: -40), -stroke)
            : mix(hoeHome, impact, stroke)
        let waterHand = ShuPoint(x: 50, y: -34)
        let carryHand = ShuPoint(x: 45, y: -28)
        let roastHand = ShuPoint(x: 43, y: -36)
        let plantBurial = smooth((t - 8.2) / 2.7)
        let plantTravel = smooth((t - 7.2) / 2.5)
        let initialPlant = site.fieldFoot + hoeHome + seedGripOffset
        let plantingPoint = mix(initialPlant, site.soil, plantTravel) + ShuPoint(y: 14 * plantBurial)
        let plantedHand = plantingPoint - walk.root - seedGripOffset
        let pullHand = site.soil - site.fieldFoot - potatoGripOffset
        let releaseHand = (site.receiver - site.productFoot).rotated(degrees: -lean) - deliveryGripOffset(receiver: site.receiver)
        var handOffset: ShuPoint
        if t < 6 { handOffset = hoeHand }
        else if t < 9 { handOffset = plantedHand }
        else if t < 12 {
            let releaseTravel = smooth((9 - 7.2) / 2.5), releaseBurial = smooth((9 - 8.2) / 2.7)
            let releasePoint = mix(initialPlant, site.soil, releaseTravel) + ShuPoint(y: 14 * releaseBurial)
            let soilHand = releasePoint - site.fieldFoot - seedGripOffset
            handOffset = mix(soilHand, waterHand, smooth((t - 9) / 3))
        }
        else if t < 23 {
            handOffset = waterHand + ShuPoint(y: reduceMotion ? 0 : sin((t - 12) * .pi * 0.75) * envelope(t, 12, 23, 0.75))
        } else if t < 24.4 {
            handOffset = mix(waterHand, pullHand, smooth((t - 23) / 1.4))
        } else if t < 27.8 {
            handOffset = mix(pullHand, ShuPoint(x: 48, y: -43), smooth((t - 24.4) / 3.4))
        } else if t < 30 {
            handOffset = mix(ShuPoint(x: 48, y: -43), carryHand, smooth((t - 27.8) / 2.2))
        } else if t < 33 {
            handOffset = mix(carryHand, roastHand, smooth((t - 31.8) / 1.2))
        } else if t < 51 {
            handOffset = mix(roastHand, carryHand, smooth((t - 50.1) / 0.9))
        } else if t < 54 { handOffset = carryHand }
        else if t < 55.7 {
            handOffset = mix(carryHand, releaseHand, smooth((t - 54) / 1.7))
        } else if t < 56 { handOffset = releaseHand }
        else { handOffset = mix(releaseHand, hoeHome, smooth((t - 56) / 0.9)) }
        // The same actor transform is used for body, shoulder and wrist target.
        // Compensate crouch here because hand targets refer to their world task positions.
        let handWorld = actor.foot + handOffset.rotated(degrees: actor.rotation)
        let palmAngle = (t < 6 ? hoeAngle : 22 * envelope(t, 12, 23, 0.75)) + actor.rotation
        let near = arm(shoulder: actor.worldPoint(local: nearShoulder), target: handWorld,
                       outward: 1, grip: 1 - envelope(t, 55.7, 59.6, 0.3), palmAngle: palmAngle)
        let farSwing = reduceMotion ? 0 : sin(walk.phase * .pi * 2) * walk.amount * 4
        let farSway = reduceMotion ? 0 : sin(t * .pi / 3) * 0.65
        let far = arm(shoulder: actor.worldPoint(local: farShoulder),
                      target: actor.worldPoint(local: ShuPoint(x: 24 - farSwing * 0.5 + farSway, y: 153)), outward: -1, grip: 0)
        let nearLeg = leg(actor: actor, localHip: ShuPoint(x: 111, y: 181),
                          ankle: walk.nearAnkle, lift: walk.nearLift, outward: 1, direction: walk.direction)
        let farLeg = leg(actor: actor, localHip: ShuPoint(x: 73, y: 181),
                         ankle: walk.farAnkle, lift: walk.farLift, outward: -1, direction: walk.direction)
        // Wrist-local orientation gets the actor orientation exactly once. The renderer
        // must not add body or forearm rotations again to these world tool rotations.
        let finalHoeAngle = near.palmRotation
        let canAngle = near.palmRotation
        let hoe = ShuToolPose(grip: near.wrist, tip: near.wrist + hoeTipLocal.rotated(degrees: finalHoeAngle),
                              rotation: finalHoeAngle, opacity: work)
        let can = ShuToolPose(grip: near.wrist, tip: near.wrist + canEmitterLocal.rotated(degrees: canAngle),
                              rotation: canAngle, opacity: envelope(t, 11.8, 23, 0.55))
        let plantOpacity = envelope(t, 5.7, 11.8, 0.3)
        let planting = ShuPropPose(position: t < 9 ? near.wrist + seedGripOffset.rotated(degrees: actor.rotation) : plantingPoint,
                                  width: 30, height: 22, rotation: -10 + 14 * plantTravel,
                                  opacity: plantOpacity, burial: plantBurial,
                                  attachment: plantOpacity == 0 ? .hidden : t < 9 ? .hand : .soil)
        let potato = potatoPose(time: t, actor: actor, wrist: near.wrist, stations: site, reduceMotion: reduceMotion)
        let corners = [ShuPoint(x: logoLocal.minX, y: logoLocal.minY), ShuPoint(x: logoLocal.maxX, y: logoLocal.minY),
                       ShuPoint(x: logoLocal.minX, y: logoLocal.maxY), ShuPoint(x: logoLocal.maxX, y: logoLocal.maxY)]
            .map { actor.worldPoint(local: $0) }
        let x = corners.map(\.x).min()!, y = corners.map(\.y).min()!
        let logo = ShuRect(x: x, y: y, width: corners.map(\.x).max()! - x, height: corners.map(\.y).max()! - y)
        return ShuRigSample(actor: actor, nearArm: near, farArm: far, nearFoot: nearLeg, farFoot: farLeg,
                            hoe: hoe, wateringCan: can, plantPotato: planting, potato: potato,
                            logoProtection: logo, stations: site, walkDistance: walk.distance,
                            walkAmount: walk.amount, poseTime: t)
    }

    private static func potatoPose(time t: Double, actor: ShuActorPose, wrist: ShuPoint,
                                   stations: ShuRigStations, reduceMotion: Bool) -> ShuPropPose {
        var position = wrist + potatoGripOffset.rotated(degrees: actor.rotation)
        var rotation = 0.0, width = 33.0, height = 26.0, opacity = 1.0, burial = 0.0
        var attachment: ShuPropAttachment = .hand
        if t < 23 { opacity = 0; attachment = .hidden }
        else if t < 24.4 {
            position = stations.soil
            burial = 0.55 * (1 - smooth((t - 23) / 1.4))
            opacity = smooth((t - 23) / 0.4)
            attachment = .soil
        } else if t < 30 {
            position = wrist + potatoGripOffset.rotated(degrees: actor.rotation)
            rotation = -12 * sin(smooth((t - 24.4) / 5.6) * .pi)
        } else if t < 33 {
            position = mix(position, stations.fire + ShuPoint(y: -20), smooth((t - 31.8) / 1.2))
        } else if t < 51 {
            position = mix(stations.fire + ShuPoint(y: -20), position, smooth((t - 50.1) / 0.9))
            rotation = reduceMotion ? 0 : sin((t - 33) * .pi / 2) * 10 * envelope(t, 33, 50.1, 0.8)
            attachment = .roastingRack
        } else if t >= 54 {
            let progress = smooth((t - 54) / 1.7)
            let gripOffset = mix(potatoGripOffset, deliveryGripOffset(receiver: stations.receiver), progress)
            position = wrist + gripOffset.rotated(degrees: actor.rotation)
            // At release, the world receiver owns this visual. Returning feet and
            // hands cannot drag it away. Inventory remains entirely outside this file.
            if t >= 55.7 { position = stations.receiver }
            width = 33 + (21 - 33) * progress; height = 26 + (16 - 26) * progress
            rotation = 0
            if t >= 55.7 { attachment = .coolingTray }
        }
        return ShuPropPose(position: position, width: width, height: height, rotation: rotation,
                           opacity: opacity, burial: burial, attachment: attachment)
    }

    /// A high row is supported nearer the palm center. Both offsets remain within
    /// the visible potato silhouette, keeping the hand in contact with the raster.
    public static func deliveryGripOffset(receiver: ShuPoint) -> ShuPoint {
        ShuPoint(x: 6 * smooth((receiver.y - 131) / 14), y: 3)
    }

    private struct Walk {
        var root: ShuPoint; var nearAnkle: ShuPoint; var farAnkle: ShuPoint
        var nearLift = 0.0, farLift = 0.0, distance = 0.0, amount = 0.0, phase = 0.0, direction = 0.0
    }
    private static func walkSample(time t: Double, stations s: ShuRigStations, reduceMotion: Bool) -> Walk {
        let start: ShuPoint, end: ShuPoint, lower: Double, upper: Double
        if t >= 30 && t < 33 { start = s.fieldFoot; end = s.fireFoot; lower = 30; upper = 33 }
        else if t >= 51 && t < 54 { start = s.fireFoot; end = s.productFoot; lower = 51; upper = 54 }
        else if t >= 56 { start = s.productFoot; end = s.fieldFoot; lower = 56; upper = 60 }
        else {
            let root = t < 30 ? s.fieldFoot : t < 51 ? s.fireFoot : s.productFoot
            return Walk(root: root, nearAnkle: root + ShuPoint(x: 21 * actorScale),
                        farAnkle: root + ShuPoint(x: -17 * actorScale))
        }
        let fraction = smooth((t - lower) / (upper - lower))
        let root = mix(start, end, fraction), total = abs(end.x - start.x)
        let direction = end.x >= start.x ? 1.0 : -1.0
        let steps = max(1, ceil(total / 22)), stride = total / steps
        let distance = total * fraction, phase = stride > 0 ? distance / stride : 0
        func foot(offset: Double, base: Double) -> (ShuPoint, Double) {
            guard !reduceMotion else { return (root + ShuPoint(x: base), 0) }
            let q = phase + offset, whole = floor(q), partial = q - whole
            let swing = max(0, (partial - 0.5) * 2)
            let advance = stride * (whole + smooth(swing))
            let lift = sin(swing * .pi) * 4
            return (ShuPoint(x: start.x + direction * advance + base, y: root.y - lift), lift)
        }
        let near = foot(offset: 0, base: 21 * actorScale)
        let far = foot(offset: 0.5, base: -17 * actorScale)
        return Walk(root: root, nearAnkle: near.0, farAnkle: far.0, nearLift: near.1, farLift: far.1,
                    distance: distance, amount: reduceMotion ? 0 : sin(fraction * .pi), phase: phase, direction: direction)
    }

    private static func arm(shoulder: ShuPoint, target: ShuPoint, outward: Double, grip: Double,
                            palmAngle: Double? = nil) -> ShuArmPose {
        let delta = target - shoulder
        let reach = min(maximumArmLength, max(13, delta.length))
        let wrist = shoulder + (delta.length > 0.0001 ? delta * (reach / delta.length) : ShuPoint(y: 1))
        let rotation = angle(wrist - shoulder)
        return ShuArmPose(shoulder: shoulder, elbow: mix(shoulder, wrist, 0.5), wrist: wrist,
                          upperRotation: rotation, forearmRotation: rotation,
                          palmRotation: palmAngle ?? rotation, gripClosed: grip)
    }
    private static func leg(actor: ShuActorPose, localHip: ShuPoint, ankle: ShuPoint,
                            lift: Double, outward: Double, direction: Double) -> ShuLegPose {
        let hip = actor.worldPoint(local: localHip)
        let knee = joints(root: hip, target: ankle, upper: 19 * actorScale,
                          lower: 20 * actorScale, outward: outward).0
        return ShuLegPose(hip: hip, knee: knee, ankle: ankle, rotation: angle(ankle - hip),
                          footRotation: lift > 0.001 ? direction * lift * -1.5 : 0,
                          lift: lift, isPlanted: lift < 0.001)
    }
    /// Leg-only two-bone calculation. Arms use one continuous shoulder-to-wrist span.
    private static func joints(root: ShuPoint, target: ShuPoint, upper: Double, lower: Double,
                               outward: Double) -> (ShuPoint, ShuPoint) {
        let delta = target - root
        let distance = min(upper + lower - 0.0001, max(abs(upper - lower) + 0.0001, delta.length))
        let axis = delta.length > 0.0001 ? delta * (1 / delta.length) : ShuPoint(y: 1)
        let end = root + axis * distance
        let projection = (upper * upper - lower * lower + distance * distance) / (2 * distance)
        let height = sqrt(max(0, upper * upper - projection * projection))
        let middle = root + axis * projection, normal = ShuPoint(x: -axis.y, y: axis.x) * height
        let a = middle + normal, b = middle - normal
        return (outward * a.x >= outward * b.x ? a : b, end)
    }
    private static func angle(_ vector: ShuPoint) -> Double { atan2(vector.y, vector.x) * 180 / .pi - 90 }
    private static func mix(_ a: ShuPoint, _ b: ShuPoint, _ t: Double) -> ShuPoint { a + (b - a) * t }
    private static func smooth(_ t: Double) -> Double { let v = min(1, max(0, t)); return v * v * (3 - 2 * v) }
    private static func envelope(_ t: Double, _ start: Double, _ end: Double, _ fade: Double) -> Double {
        smooth((t - start) / fade) * (1 - smooth((t - end + fade) / fade))
    }
    private static func keyframe(_ t: Double, _ frames: [(Double, Double)]) -> Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        if t <= first.0 { return first.1 }
        for i in 1..<frames.count where t <= frames[i].0 {
            let a = frames[i - 1], b = frames[i]
            return a.1 + (b.1 - a.1) * smooth((t - a.0) / (b.0 - a.0))
        }
        return last.1
    }
}
