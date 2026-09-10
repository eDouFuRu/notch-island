import XCTest
@testable import NotchIslandCore

final class ShuAnimationTimelineTests: XCTestCase {
    private let stocks = [0, 1, 12, 13]

    private func assertPoint(_ actual: ShuPoint, _ expected: ShuPoint, accuracy: Double = 0.000_01,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, message, file: file, line: line)
    }

    // An independent affine oracle catches omitted scale/rotation/translation,
    // rather than just comparing two callers of actor.worldPoint(local:).
    private func expectedWorld(_ local: ShuPoint, actor: ShuActorPose) -> ShuPoint {
        let angle = actor.rotation * Double.pi / 180
        let x = (local.x - 90) * actor.scale, y = (local.y - 210) * actor.scale
        return ShuPoint(x: actor.foot.x + x * cos(angle) - y * sin(angle) + actor.bodyOffset.x,
                        y: actor.foot.y + x * sin(angle) + y * cos(angle) + actor.bodyOffset.y)
    }

    func testNineStagesAndMinuteLoop() {
        let boundaries: [(Double, ShuGardenStage)] = [
            (0, .hoe), (6, .plant), (12, .water), (23, .pull), (30, .turn),
            (33, .roast), (51, .carry), (54, .place), (56, .returnHome)
        ]
        XCTAssertEqual(ShuGardenStage.allCases.count, 9)
        for (index, item) in boundaries.enumerated() {
            XCTAssertEqual(ShuAnimationTimeline.sample(elapsed: item.0).stage, item.1)
            let end = index + 1 < boundaries.count ? boundaries[index + 1].0 : 60
            XCTAssertEqual(ShuAnimationTimeline.sample(elapsed: end - 0.000_01).stage, item.1)
        }
        for stock in stocks {
            XCTAssertEqual(ShuAnimationTimeline.sample(elapsed: 12, inventory: stock),
                           ShuAnimationTimeline.sample(elapsed: 72, inventory: stock))
        }
        XCTAssertEqual(ShuAnimationTimeline.sample(elapsed: 60).stage, .hoe)
        XCTAssertEqual(ShuAnimationTimeline.sample(elapsed: 120).stage, .hoe)
    }

    func testWorldShouldersAndLogoBoundsIncludeTheCompleteBodyTransform() {
        for stock in stocks {
            for time in stride(from: 0.0, to: 60, by: 0.125) {
                let rig = ShuAnimationTimeline.sample(elapsed: time, inventory: stock).rig
                assertPoint(rig.nearArm.shoulder, expectedWorld(ShuRigLayout.nearShoulder, actor: rig.actor))
                assertPoint(rig.farArm.shoulder, expectedWorld(ShuRigLayout.farShoulder, actor: rig.actor))
                let logo = ShuRigLayout.logoLocal
                let corners = [ShuPoint(x: logo.minX, y: logo.minY), ShuPoint(x: logo.maxX, y: logo.minY),
                               ShuPoint(x: logo.minX, y: logo.maxY), ShuPoint(x: logo.maxX, y: logo.maxY)]
                    .map { expectedWorld($0, actor: rig.actor) }
                XCTAssertEqual(rig.logoProtection.minX, corners.map(\.x).min()!, accuracy: 0.000_01)
                XCTAssertEqual(rig.logoProtection.maxX, corners.map(\.x).max()!, accuracy: 0.000_01)
                XCTAssertEqual(rig.logoProtection.minY, corners.map(\.y).min()!, accuracy: 0.000_01)
                XCTAssertEqual(rig.logoProtection.maxY, corners.map(\.y).max()!, accuracy: 0.000_01)
                XCTAssertEqual(rig.actor.scale, 124.0 / 180, accuracy: 0.000_01)
            }
        }
    }

    func testOnePieceArmsStayShortAndToolGripsStayAtWorldWrist() {
        for stock in stocks {
            for time in stride(from: 0.0, to: 60, by: 0.125) {
                let rig = ShuAnimationTimeline.sample(elapsed: time, inventory: stock).rig
                for reduceMotion in [false, true] {
                    let pose = ShuAnimationTimeline.sample(elapsed: time, inventory: stock, reduceMotion: reduceMotion).rig
                    for arm in [pose.nearArm, pose.farArm] {
                        let span = (arm.wrist - arm.shoulder).length
                        // The visible sprite is a single sleeve-to-mitten shape;
                        // measure its full scene-space span, not unused IK segments.
                        XCTAssertGreaterThan(span, 0, "Collapsed arm at \(time)s, stock \(stock)")
                        XCTAssertLessThanOrEqual(span, 26.000_01, "Long arm at \(time)s, stock \(stock), Reduce Motion \(reduceMotion)")
                    }
                }
                for (tool, tip) in [(rig.hoe, ShuRigLayout.hoeTipLocal), (rig.wateringCan, ShuRigLayout.canEmitterLocal)] {
                    assertPoint(tool.grip, rig.nearArm.wrist)
                    let angle = tool.rotation * Double.pi / 180
                    assertPoint(tool.tip, ShuPoint(x: tool.grip.x + tip.x * cos(angle) - tip.y * sin(angle),
                                                  y: tool.grip.y + tip.x * sin(angle) + tip.y * cos(angle)))
                }
                if rig.hoe.opacity > 0.05 {
                    XCTAssertEqual(rig.nearArm.palmRotation, rig.hoe.rotation, accuracy: 0.000_01)
                } else if rig.wateringCan.opacity > 0.05 {
                    XCTAssertEqual(rig.nearArm.palmRotation, rig.wateringCan.rotation, accuracy: 0.000_01)
                }
            }
        }
    }

    func testArmCenterlinesStayOutsideTheProtectedChestLabel() {
        for time in stride(from: 0.0, to: 60, by: 0.05) {
            let rig = ShuAnimationTimeline.sample(elapsed: time, inventory: 13).rig
            for arm in [rig.nearArm, rig.farArm] {
                for fraction in stride(from: 0.0, through: 1, by: 0.1) {
                    XCTAssertFalse(rig.logoProtection.contains(arm.shoulder + (arm.wrist - arm.shoulder) * fraction), "Chest-label crossing at \(time)s")
                }
            }
        }
    }

    func testFullDownstrokesReachTheSoilWithTheActualToolTip() {
        for time in [0.96, 2.96, 4.96] {
            let rig = ShuAnimationTimeline.sample(elapsed: time).rig
            XCTAssertEqual(rig.hoe.opacity, 1)
            assertPoint(rig.hoe.tip, rig.stations.soil)
        }
    }

    func testOnePieceArmWristsStayContinuousAtMillisecondResolution() {
        for stock in stocks {
            var previous = ShuAnimationTimeline.sample(elapsed: 0, inventory: stock).rig
            var largestStep = 0.0, largestStepTime = 0.0
            // Stage-boundary checks alone miss a wrist snap within an action.
            for millisecond in 1...60_000 {
                let time = Double(millisecond) / 1_000
                let next = ShuAnimationTimeline.sample(elapsed: time, inventory: stock).rig
                for (before, after) in [(previous.nearArm.wrist, next.nearArm.wrist),
                                        (previous.farArm.wrist, next.farArm.wrist)] {
                    let distance = (after - before).length
                    if distance > largestStep { largestStep = distance; largestStepTime = time }
                }
                previous = next
            }
            XCTAssertLessThan(largestStep, 1, "Wrist discontinuity at \(largestStepTime)s, stock \(stock)")
        }
    }

    func testWalkingUsesStationTravelAndPlantedFeetDoNotSlide() {
        for stock in stocks {
            let stations = ShuRigLayout.stations(inventory: stock)
            for (lower, upper, start, end) in [(30.0, 33.0, stations.fieldFoot, stations.fireFoot),
                                              (51, 54, stations.fireFoot, stations.productFoot),
                                              (56, 60, stations.productFoot, stations.fieldFoot)] {
                assertPoint(ShuAnimationTimeline.sample(elapsed: lower, inventory: stock).rig.actor.foot, start)
                assertPoint(ShuAnimationTimeline.sample(elapsed: upper - 0.000_001, inventory: stock).rig.actor.foot, end, accuracy: 0.001)
                XCTAssertGreaterThan((end - start).length, 20)
                var previous: ShuRigSample?
                for frame in 0..<Int((upper - lower) * 120) {
                    let time = lower + Double(frame) / 120
                    let rig = ShuAnimationTimeline.sample(elapsed: time, inventory: stock).rig
                    XCTAssertTrue(rig.nearFoot.isPlanted || rig.farFoot.isPlanted, "Both feet floating at \(time)s")
                    if let previous {
                        for (before, after) in [(previous.nearFoot, rig.nearFoot), (previous.farFoot, rig.farFoot)]
                            where before.lift == 0 && after.lift == 0 {
                            assertPoint(after.ankle, before.ankle, accuracy: 0.000_01, "Planted foot slid at \(time)s")
                            XCTAssertEqual(after.footRotation, 0)
                        }
                    }
                    previous = rig
                }
            }
        }
    }

    func testRigAndVisiblePropsStayContinuousAtAllActionTransitions() {
        for stock in stocks {
            for boundary in [6.0, 7.2, 8.2, 9, 10.2, 12, 23, 24.4, 27.8, 30, 31.8, 33, 50.1, 51, 54, 55.7, 56, 60] {
                let before = ShuAnimationTimeline.sample(elapsed: boundary - 0.000_01, inventory: stock).rig
                let after = ShuAnimationTimeline.sample(elapsed: boundary + 0.000_01, inventory: stock).rig
                let message = "Boundary \(boundary)s, stock \(stock)"
                for (a, b) in [(before.actor.foot, after.actor.foot), (before.nearArm.wrist, after.nearArm.wrist),
                               (before.nearArm.elbow, after.nearArm.elbow), (before.farArm.wrist, after.farArm.wrist),
                               (before.nearFoot.ankle, after.nearFoot.ankle), (before.farFoot.ankle, after.farFoot.ankle)] {
                    assertPoint(a, b, accuracy: 0.003, message)
                }
                for (a, b) in [(before.plantPotato, after.plantPotato), (before.potato, after.potato)]
                    where a.opacity > 0.001 && b.opacity > 0.001 {
                    assertPoint(a.position, b.position, accuracy: 0.003, message)
                    XCTAssertEqual(a.width, b.width, accuracy: 0.003, message)
                    XCTAssertEqual(a.height, b.height, accuracy: 0.003, message)
                }
            }
        }
    }

    func testPlantingPotatoKeepsItsSizeAndMovesBehindSoil() {
        var previousBurial = 0.0
        for time in stride(from: 6.0, through: 11.5, by: 0.025) {
            let rig = ShuAnimationTimeline.sample(elapsed: time).rig
            let potato = rig.plantPotato
            XCTAssertEqual(potato.width, 30)
            XCTAssertEqual(potato.height, 22)
            XCTAssertGreaterThanOrEqual(potato.burial, previousBurial)
            previousBurial = potato.burial
            if time > 10.8 {
                XCTAssertGreaterThan(potato.position.y, rig.stations.soil.y)
                XCTAssertEqual(potato.attachment, .soil)
            }
        }
        XCTAssertEqual(previousBurial, 1)
    }

    func testDeliveredPotatoWaitsAtGroundReceiverUntilSixtySecondSettlement() {
        for stock in stocks {
            let receiver = ShuRigLayout.stations(inventory: stock).receiver
            if stock >= 12 { XCTAssertEqual(receiver.y, 168, "Overflow must stay on the ground") }
            for time in stride(from: 56.0, to: 60, by: 0.03125) {
                let rig = ShuAnimationTimeline.sample(elapsed: time, inventory: stock).rig
                assertPoint(rig.potato.position, receiver)
                XCTAssertEqual(rig.potato.attachment, .coolingTray)
                XCTAssertEqual(rig.potato.opacity, 1)
                XCTAssertEqual(rig.potato.width, 21)
                XCTAssertEqual(rig.potato.height, 16)
            }
            let endpoint = ShuDeliveryLayout.sample(cycleTime: 60, inventory: stock)
            XCTAssertEqual(endpoint.x, receiver.x)
            XCTAssertEqual(endpoint.y, receiver.y)
            XCTAssertEqual(ShuAnimationTimeline.sample(elapsed: 60, inventory: stock + 1).rig.potato.opacity, 0)
        }
    }

    func testPauseHiddenAndReduceMotionDoNotAdvanceRenderingClock() {
        XCTAssertEqual(ShuAnimationTimeline.renderElapsed(authoritative: 25.4, sampledAt: 10, frameTime: 10.2, running: true, visible: true) ?? -1, 25.6, accuracy: 0.0001)
        XCTAssertEqual(ShuAnimationTimeline.renderElapsed(authoritative: 25.4, sampledAt: 10, frameTime: 999, running: false, visible: true), 25.4)
        XCTAssertNil(ShuAnimationTimeline.renderElapsed(authoritative: 25.4, sampledAt: 10, frameTime: 999, running: true, visible: false))
        XCTAssertEqual(ShuAnimationTimeline.renderElapsed(authoritative: 25.4, sampledAt: 10, frameTime: 999, running: true, visible: true, reduceMotion: true), 25.4)
        XCTAssertEqual(ShuAnimationTimeline.renderElapsed(authoritative: 25.4, sampledAt: 10, frameTime: 999, running: true, visible: true), 25.9)
    }

    func testReducedMotionFreezesEachActionPoseAndKeepsSemantics() {
        for stage in ShuGardenStage.allCases {
            let start = ShuAnimationTimeline.sample(elapsed: stage.interval.lowerBound + 0.01, reduceMotion: true)
            let end = ShuAnimationTimeline.sample(elapsed: stage.interval.upperBound - 0.01, reduceMotion: true)
            XCTAssertEqual(start.rig, end.rig)
            XCTAssertEqual(start.stage, stage)
            // A fixed placing lean is a meaningful static action pose. Reduce
            // Motion requires it to stay frozen, not every pose to be upright.
            XCTAssertEqual(start.rig.nearFoot.lift, 0)
            XCTAssertEqual(start.rig.farFoot.lift, 0)
        }
        XCTAssertGreaterThan(ShuAnimationTimeline.sample(elapsed: 17, reduceMotion: true).waterAmount, 0)
    }

    func testAllSamplesStayFiniteAndEffectAmountsBounded() {
        for stock in stocks {
            for elapsed in stride(from: -1.0, through: 121, by: 0.125) {
                let sample = ShuAnimationTimeline.sample(elapsed: elapsed, inventory: stock)
                let rig = sample.rig
                for amount in [sample.stageProgress, rig.hoe.opacity, rig.wateringCan.opacity, rig.potato.opacity,
                               rig.plantPotato.opacity, rig.plantPotato.burial, sample.seedlingScale,
                               sample.seedlingOpacity, sample.waterAmount, sample.fireAmount, sample.steamAmount] {
                    XCTAssertTrue(amount.isFinite)
                    XCTAssertGreaterThanOrEqual(amount, 0)
                    XCTAssertLessThanOrEqual(amount, 1)
                }
                for point in [rig.actor.foot, rig.actor.bodyOffset, rig.nearArm.shoulder, rig.nearArm.elbow,
                              rig.nearArm.wrist, rig.farArm.elbow, rig.nearFoot.ankle, rig.farFoot.ankle,
                              rig.hoe.tip, rig.wateringCan.tip, rig.potato.position, rig.plantPotato.position] {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                }
            }
        }
        XCTAssertEqual(ShuAnimationTimeline.sample(elapsed: .nan).cycleTime, 0)
        XCTAssertEqual(ShuAnimationTimeline.sample(elapsed: .infinity).cycleTime, 0)
    }
}
