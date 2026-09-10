import XCTest
@testable import NotchInteractionCore

final class CaptureRegionPolicyTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testAppKitBottomLeftSelectionMapsToQuartzTopLeft() throws {
        let region = try XCTUnwrap(CaptureRegionPolicy.region(from: CGRect(x: 100, y: 200, width: 300, height: 180),
                                                              appKitScreen: main, quartzScreen: main))
        XCTAssertEqual(region.rect, CGRect(x: 100, y: 602, width: 300, height: 180))
        XCTAssertEqual(region.argument, "100,602,300,180")
    }

    func testDisplayAboveMainUsesItsQuartzOrigin() throws {
        let above = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        let quartz = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let result = try XCTUnwrap(CaptureRegionPolicy.region(from: CGRect(x: 80, y: 900, width: 300, height: 100),
                                                              appKitScreen: above, quartzScreen: quartz))
        XCTAssertEqual(result.rect, CGRect(x: 80, y: -1000, width: 300, height: 100))
    }

    func testDisplayLeftOfMainKeepsNegativeCoordinates() throws {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let result = try XCTUnwrap(CaptureRegionPolicy.region(from: CGRect(x: 50, y: 50, width: 150, height: 150),
                                                              appKitScreen: screen, quartzScreen: screen))
        XCTAssertEqual(result.rect, CGRect(x: -1870, y: 880, width: 150, height: 150))
    }

    func testDragCannotRecordAcrossAnotherDisplay() throws {
        let result = try XCTUnwrap(CaptureRegionPolicy.region(from: CGRect(x: -100, y: -100, width: 1700, height: 1300),
                                                              appKitScreen: main, quartzScreen: main))
        XCTAssertEqual(result.rect, main)
        XCTAssertNil(CaptureRegionPolicy.region(from: CGRect(x: 1520, y: 50, width: 300, height: 200),
                                                appKitScreen: main, quartzScreen: main))
    }

    func testTinyOrInvalidSelectionCannotStartRecording() {
        for selection in [CGRect.zero, CGRect(x: 0, y: 0, width: 15, height: 500),
                          CGRect(x: 0, y: 0, width: 500, height: 15), CGRect.infinite] {
            XCTAssertNil(CaptureRegionPolicy.region(from: selection, appKitScreen: main, quartzScreen: main))
        }
        XCTAssertNil(CaptureRegionPolicy.region(from: CGRect(x: 0, y: 0, width: 100, height: 100),
                                                appKitScreen: .zero, quartzScreen: main))
    }

    func testPixelAlignedBoundsCoverFractionalSelection() throws {
        let result = try XCTUnwrap(CaptureRegionPolicy.region(from: CGRect(x: 0.5, y: 1.5, width: 31, height: 40),
                                                              appKitScreen: main, quartzScreen: main))
        XCTAssertEqual(result.rect, CGRect(x: 0, y: 940, width: 32, height: 41))
    }

    func testRegionRecordingRequiresRegionAndNeverStartsToolbarOrInteractiveVideo() {
        let output = URL(fileURLWithPath: "/tmp/recording.mov")
        XCTAssertTrue(CaptureToolKind.areaRecording.arguments(output: output).isEmpty)
        let region = CaptureRegion(rect: CGRect(x: 10, y: 20, width: 320, height: 240))
        XCTAssertEqual(CaptureToolKind.areaRecording.arguments(output: output, region: region),
                       ["-v", "-R", "10,20,320,240", output.path])
        XCTAssertFalse(CaptureToolKind.areaRecording.usesSystemToolbar)
        XCTAssertFalse(CaptureToolKind.customRecording.usesSystemToolbar)
        XCTAssertTrue(CaptureToolKind.customRecording.arguments(output: output).isEmpty)
    }
}
