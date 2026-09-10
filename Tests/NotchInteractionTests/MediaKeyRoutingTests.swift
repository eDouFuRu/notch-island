import XCTest
@testable import NotchInteractionCore

final class MediaKeyRoutingTests: XCTestCase {
    private func event(_ key: Int = 0, down: Bool = true, repeat repeated: Bool = false) -> SystemMediaKeyEvent {
        SystemMediaKeyEvent(subtype: 8, data1: (key << 16) | (down ? 0x0a00 : 0x0b00) | (repeated ? 1 : 0))!
    }

    func testDecodesKnownKeysAndRejectsUnrelatedPackets() {
        for key in [0, 1, 2, 3, 7] {
            XCTAssertEqual(event(key).key.rawValue, key)
            XCTAssertTrue(event(key).isKeyDown)
            XCTAssertFalse(event(key, down: false).isKeyDown)
        }
        XCTAssertNil(SystemMediaKeyEvent(subtype: 7, data1: 0x0a00))
        XCTAssertNil(SystemMediaKeyEvent(subtype: 8, data1: (99 << 16) | 0x0a00))
        XCTAssertNil(SystemMediaKeyEvent(subtype: 8, data1: 0x0300))
    }

    func testHeldVolumeKeyActsOnDownAndRepeatsButConsumesMatchingUp() {
        var state = MediaKeyRoutingState()
        XCTAssertEqual(state.process(event(), canHandle: true), .consume(performAction: true))
        for _ in 0..<20 {
            XCTAssertEqual(state.process(event(repeat: true), canHandle: true), .consume(performAction: true))
        }
        XCTAssertEqual(state.process(event(down: false), canHandle: true), .consume(performAction: false))
        XCTAssertEqual(state.process(event(down: false), canHandle: true), .passThrough)
    }

    func testMuteAndDuplicateInitialDownCannotToggleRepeatedly() {
        var state = MediaKeyRoutingState()
        XCTAssertEqual(state.process(event(7), canHandle: true), .consume(performAction: true))
        XCTAssertEqual(state.process(event(7), canHandle: true), .consume(performAction: false))
        XCTAssertEqual(state.process(event(7, repeat: true), canHandle: true), .consume(performAction: false))
        XCTAssertEqual(state.process(event(7, down: false), canHandle: true), .consume(performAction: false))
    }

    func testRepeatAlreadyHeldBeforeTapActivationPassesThrough() {
        var state = MediaKeyRoutingState()
        XCTAssertEqual(state.process(event(repeat: true), canHandle: true), .passThrough)
        XCTAssertEqual(state.process(event(down: false), canHandle: true), .passThrough)
    }

    func testUnavailableAndResetDoNotKeepStaleOwnership() {
        var state = MediaKeyRoutingState()
        XCTAssertEqual(state.process(event(), canHandle: false), .passThrough)
        XCTAssertEqual(state.process(event(down: false), canHandle: false), .passThrough)
        _ = state.process(event(), canHandle: true)
        let generation = state.generation
        state.reset()
        XCTAssertNotEqual(state.generation, generation)
        XCTAssertEqual(state.process(event(down: false), canHandle: true), .passThrough)
    }

    func testIndependentKeysKeepIndependentPairsAndStopRepeatingWhenUnavailable() {
        var state = MediaKeyRoutingState()
        _ = state.process(event(0), canHandle: true)
        _ = state.process(event(2), canHandle: true)
        XCTAssertEqual(state.process(event(0, down: false), canHandle: true), .consume(performAction: false))
        XCTAssertEqual(state.process(event(2, repeat: true), canHandle: false), .consume(performAction: false))
        XCTAssertEqual(state.process(event(2, down: false), canHandle: false), .consume(performAction: false))
    }
}
