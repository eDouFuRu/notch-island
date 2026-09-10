import XCTest
@testable import NotchInteractionCore

final class SystemToolCatalogTests: XCTestCase {
    func testPersistedIDsHaveExactlyOneDefinition() {
        let definitions = SystemToolCatalog.all.map(\.id)
        XCTAssertEqual(Set(definitions), Set(SystemToolID.allCases))
        XCTAssertEqual(definitions.count, Set(definitions).count)
        XCTAssertEqual(Set(SystemToolCatalog.defaultVisible).count, SystemToolCatalog.defaultVisible.count)
        XCTAssertTrue(Set(SystemToolCatalog.defaultVisible).isSubset(of: Set(definitions)))
    }

    func testRequestedCaptureAndUtilityEntriesRouteToTheirActualTools() {
        for id in [SystemToolID.captureScreen, .captureRegion, .captureWindow, .captureCustom,
                   .recordScreen, .recordRegion, .recordCustom] {
            XCTAssertEqual(SystemToolCatalog.tool(id).behavior, .capture)
        }
        XCTAssertEqual(SystemToolCatalog.tool(.stopwatch).behavior, .utility(.stopwatch))
        XCTAssertEqual(SystemToolCatalog.tool(.timer).behavior, .utility(.timer))
        XCTAssertEqual(SystemToolCatalog.tool(.alarm).behavior, .utility(.alarm))
        XCTAssertEqual(SystemToolCatalog.tool(.keyboardBrightness).behavior, .slider(.keyboardBrightness))
        XCTAssertEqual(SystemToolCatalog.tool(.wifi).behavior, .wifiPower)
        XCTAssertFalse(SystemToolCatalog.defaultVisible.contains(.wifi))
        XCTAssertEqual(SystemToolCatalog.tool(.darkMode).behavior, .appearanceToggle)
        XCTAssertEqual(SystemToolCatalog.tool(.darkMode).behavior.labelKey, "Toggle Dark Mode")
    }

    func testSettingsLaunchersNeverClaimToToggleSystemControls() {
        for entry in SystemToolCatalog.all {
            guard case let .systemSettings(pane) = entry.behavior else { continue }
            XCTAssertEqual(entry.behavior.labelKey, "Open Settings")
            XCTAssertEqual(URL(string: pane.urlString)?.scheme, "x-apple.systempreferences")
        }
    }

    func testLockAndScreenSaverRunExplicitActionsInsteadOfOpeningSettings() {
        XCTAssertEqual(SystemToolCatalog.tool(.lockScreen).behavior, .systemShortcut(.lockScreen))
        XCTAssertEqual(SystemToolCatalog.tool(.lockScreen).behavior.labelKey, "Run Action")
        XCTAssertEqual(SystemToolCatalog.tool(.screenSaver).behavior,
                       .nativeApp(bundleIdentifier: "com.apple.ScreenSaver.Engine",
                                  path: "/System/Library/CoreServices/ScreenSaverEngine.app"))
    }

    func testNativeSystemLaunchersHaveDistinctAppTargetsAndMatchingInstalledIdentity() throws {
        var bundleIDs = Set<String>()
        for id in [SystemToolID.spotlight, .siri, .accessibility] {
            guard case let .nativeApp(bundleIdentifier, path) = SystemToolCatalog.tool(id).behavior else {
                XCTFail("\(id.rawValue) must launch its native tool, not a preferences page")
                continue
            }
            XCTAssertTrue(bundleIDs.insert(bundleIdentifier).inserted)
            XCTAssertTrue(path.hasPrefix("/System/"))
            XCTAssertTrue(path.hasSuffix(".app"))
            // This is package-identity evidence only, not a claim that a panel opened.
            if let installed = Bundle(path: path) {
                XCTAssertEqual(installed.bundleIdentifier, bundleIdentifier)
            }
        }
        XCTAssertEqual(bundleIDs.count, 3)
    }
}
