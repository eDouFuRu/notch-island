import XCTest
@testable import NotchInteractionCore

final class GUISessionAvailabilityTests: XCTestCase {
    func testStartupIsUnavailableUntilKnownConsoleLogin() {
        var state = GUISessionAvailability()
        XCTAssertTrue(state.isUnavailable)
        for onConsole in [nil, false, true] as [Bool?] {
            for loginDone in [nil, false, true] as [Bool?] {
                state.refreshSession(onConsole: onConsole, loginDone: loginDone, locked: false)
                XCTAssertEqual(state.isUnavailable, !(onConsole == true && loginDone == true))
            }
        }
    }

    func testLaunchingInAlreadyLockedSessionDoesNotEnableHUD() {
        var state = GUISessionAvailability()
        state.refreshSession(onConsole: true, loginDone: true, locked: true)
        XCTAssertTrue(state.isUnavailable)
        state.setScreenLocked(false)
        XCTAssertFalse(state.isUnavailable)
    }

    func testOptionalPrivateLockFieldCanBeAbsentOnAnActiveConsole() {
        var state = GUISessionAvailability()
        state.refreshSession(onConsole: true, loginDone: true, locked: nil)
        XCTAssertFalse(state.isUnavailable)
        state.setScreenLocked(true)
        state.refreshSession(onConsole: true, loginDone: true, locked: nil)
        XCTAssertTrue(state.isUnavailable, "Missing optional data must not clear a known lock")
    }

    func testWakeDoesNotReactivateResignedSessionEvenWithAStaleReadySnapshot() {
        var state = GUISessionAvailability()
        state.refreshSession(onConsole: true, loginDone: true, locked: false)
        state.setSessionActive(false)
        state.setScreenSleeping(true)
        state.setScreenSleeping(false)
        state.refreshSession(onConsole: true, loginDone: true, locked: false)
        XCTAssertTrue(state.isUnavailable)
        state.setSessionActive(true)
        XCTAssertFalse(state.isUnavailable)
    }

    func testBecomeActiveDoesNotOverrideMissingCurrentSession() {
        var state = GUISessionAvailability()
        state.setSessionActive(false)
        state.setSessionActive(true)
        state.refreshSession(onConsole: nil, loginDone: nil, locked: nil)
        XCTAssertTrue(state.isUnavailable)
    }

    func testSessionActivationDoesNotOverrideDisplaySleepOrLock() {
        var state = GUISessionAvailability()
        state.refreshSession(onConsole: true, loginDone: true, locked: true)
        state.setScreenSleeping(true)
        state.setSessionActive(true)
        state.setScreenLocked(false)
        XCTAssertTrue(state.isUnavailable)
        state.setScreenSleeping(false)
        XCTAssertFalse(state.isUnavailable)
    }

    func testLosingSessionInformationClosesGateUntilValidRefresh() {
        var state = GUISessionAvailability()
        state.refreshSession(onConsole: true, loginDone: true, locked: false)
        XCTAssertFalse(state.isUnavailable)
        state.refreshSession(onConsole: nil, loginDone: nil, locked: nil)
        XCTAssertTrue(state.isUnavailable)
        state.refreshSession(onConsole: true, loginDone: true, locked: false)
        XCTAssertFalse(state.isUnavailable)
    }
}
