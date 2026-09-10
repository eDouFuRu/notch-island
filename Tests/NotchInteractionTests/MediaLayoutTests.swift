import XCTest
@testable import NotchInteractionCore

final class MediaLayoutTests: XCTestCase {
    func testInlineMetadataIsIncludedInShellWidthAndLeavesPhysicalGapUnchanged() {
        let normal = ClosedMediaLayout(notchWidth: 185, height: 32, inlineMetadata: false)
        let inline = ClosedMediaLayout(notchWidth: 185, height: 32, inlineMetadata: true)
        XCTAssertEqual(normal.shellWidth, 269)
        XCTAssertEqual(inline.shellWidth, 485)
        XCTAssertEqual(inline.physicalGapWidth, normal.physicalGapWidth)
        XCTAssertEqual(inline.contentWidth + 2 * inline.shellInset, inline.shellWidth)
        let constrained = ClosedMediaLayout(notchWidth: 400, height: 32, inlineMetadata: true)
        XCTAssertEqual(constrained.shellWidth, 640)
    }

    func testArtworkAndFullHeightSpectrumStayInsideRoundedClosedOutline() {
        for height: CGFloat in [15, 24, 29, 32, 38, 45] {
            for notchWidth: CGFloat in [120, 185, 210] {
                for inline in [false, true] {
                    let layout = ClosedMediaLayout(notchWidth: notchWidth, height: height, inlineMetadata: inline)
                    let outline = NotchHitRegion.outline(size: CGSize(width: layout.shellWidth, height: layout.height),
                                                        topRadius: 6, bottomRadius: 14)
                    for rect in [layout.artworkFrame, layout.spectrumFrame] {
                        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                            XCTAssertTrue(outline.contains(corner), "Clipped corner at \(corner), height \(height)")
                        }
                    }
                    XCTAssertEqual(layout.spectrumFrame.height, 14)
                }
            }
        }
    }

    func testMinimumMediaHeightMatchesCarrierAndSpectrumFitsItsReservedSlot() {
        for height: CGFloat in [24, 25, 29, 32, 45, 60] {
            let layout = ClosedMediaLayout(notchWidth: 185, height: height, inlineMetadata: true)
            XCTAssertEqual(layout.height, height, "Do not silently exceed ContentView's closed height")
            let rightSlot = CGRect(x: layout.shellWidth - layout.artworkFrame.maxX,
                                   y: layout.artworkFrame.minY,
                                   width: layout.artworkSize, height: layout.artworkSize)
            XCTAssertTrue(rightSlot.contains(layout.spectrumFrame), "The 16×14 spectrum must fit its actual SwiftUI frame")
        }
        XCTAssertEqual(ClosedMediaLayout(notchWidth: 120, height: 0, inlineMetadata: false).height, 24)
    }

    func testVisualMediaExpansionDoesNotExpandPhysicalTrigger() {
        let screen = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let trigger = NotchHitRegion.triggerRect(screenFrame: screen, safeTop: 32,
                                                 leftAuxiliaryWidth: 707.5, rightAuxiliaryWidth: 707.5)
        for inline in [false, true] {
            let layout = ClosedMediaLayout(notchWidth: trigger.width, height: 32, inlineMetadata: inline)
            let region = NotchHitRegion(triggerRect: trigger,
                visibleFrame: CGRect(x: screen.midX - layout.shellWidth / 2, y: screen.maxY - layout.height,
                                     width: layout.shellWidth, height: layout.height), topRadius: 6, bottomRadius: 14)
            XCTAssertFalse(region.containsTrigger(CGPoint(x: trigger.minX - 10, y: trigger.midY)))
            XCTAssertTrue(region.containsTrigger(CGPoint(x: trigger.midX, y: trigger.midY)))
        }
    }

    func testSlotNormalizationPreservesFirstOccurrenceAndPadsFiveSlots() {
        XCTAssertEqual(MediaSlotReducer.normalize(["play", "play", "next"], empty: ""),
                       ["play", "", "next", "", ""])
        XCTAssertEqual(MediaSlotReducer.normalize(["a", "b", "c", "d", "e", "f"], empty: ""),
                       ["a", "b", "c", "d", "e"])
    }

    func testSlotMoveSwapAndReturnToLibraryAreAtomicAndUnique() {
        let source = ["previous", "play", "next", "", ""]
        let moved = MediaSlotReducer.drop("play", from: 1, to: 3, in: source, empty: "")
        XCTAssertEqual(moved, ["previous", "", "next", "play", ""])
        let swapped = MediaSlotReducer.drop("play", from: 3, to: 0, in: moved, empty: "")
        XCTAssertEqual(swapped, ["play", "", "next", "previous", ""])
        XCTAssertEqual(MediaSlotReducer.drop("play", from: 0, to: nil, in: swapped, empty: ""),
                       ["", "", "next", "previous", ""])
        XCTAssertEqual(MediaSlotReducer.drop("next", from: nil, to: 0, in: source, empty: ""),
                       ["next", "play", "previous", "", ""])
    }

    func testPaletteInsertReplacesTargetAndStaleInvalidDragsDoNothing() {
        let source = ["previous", "play", "next", "", ""]
        XCTAssertEqual(MediaSlotReducer.drop("shuffle", from: nil, to: 0, in: source, empty: ""),
                       ["shuffle", "play", "next", "", ""])
        for invalidTarget in [-1, 5, 99] {
            XCTAssertEqual(MediaSlotReducer.drop("play", from: 1, to: invalidTarget, in: source, empty: ""), source)
        }
        XCTAssertEqual(MediaSlotReducer.drop("play", from: 2, to: 0, in: source, empty: ""), source)
        XCTAssertEqual(MediaSlotReducer.drop("play", from: nil, to: nil, in: source, empty: ""), source)
        XCTAssertEqual(MediaSlotReducer.drop("play", from: 1, to: 1, in: source, empty: ""), source)
    }

    func testPrivateDragPayloadRoundTripRetainsSourceIdentity() throws {
        let payload = MediaControlDragPayload(controlID: "playPause", sourceSlot: 2)
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(MediaControlDragPayload.self, from: data), payload)
        XCTAssertThrowsError(try JSONDecoder().decode(MediaControlDragPayload.self, from: Data("slot:2".utf8)))
    }

    func testEveryOccupiedSlotCanMoveOrSwapAndReturnWithoutLosingControls() {
        let original = ["previous", "play", "next", "", "favorite"]
        for source in original.indices where !original[source].isEmpty {
            for target in original.indices {
                let value = original[source]
                let moved = MediaSlotReducer.drop(value, from: source, to: target, in: original, empty: "")
                XCTAssertEqual(moved[target], value)
                XCTAssertEqual(moved.sorted(), original.sorted())
                let returned = MediaSlotReducer.drop(value, from: target, to: source, in: moved, empty: "")
                XCTAssertEqual(returned, original)
                let removed = MediaSlotReducer.drop(value, from: target, to: nil, in: moved, empty: "")
                XCTAssertEqual(removed[target], "")
                XCTAssertFalse(removed.contains(value))
                XCTAssertEqual(removed.count, 5)
            }
        }
    }

    func testLateSlotDropCannotRemoveANewOccupantAfterSettingsChanged() {
        let afterReset = ["", "previous", "play", "next", ""]
        // The payload was created earlier, when slot 2 held "favorite".
        XCTAssertEqual(MediaSlotReducer.drop("favorite", from: 2, to: nil, in: afterReset, empty: ""), afterReset)
        XCTAssertEqual(MediaSlotReducer.drop("favorite", from: 2, to: 0, in: afterReset, empty: ""), afterReset)
    }

    func testUnknownMediaSourceDoesNotHideUnrelatedFullscreenApplications() {
        let spaces = [FullscreenMediaPolicy.Space(screenID: "internal", applicationIDs: ["editor"])]
        XCTAssertEqual(FullscreenMediaPolicy.status(spaces: spaces, mode: .currentMediaApp, mediaSource: nil), ["internal": false])
        XCTAssertEqual(FullscreenMediaPolicy.status(spaces: spaces, mode: .currentMediaApp, mediaSource: "  "), ["internal": false])
    }

    func testFullscreenPolicyAndMediaSourceCanChangeWithoutSpaceTransition() {
        let spaces = [FullscreenMediaPolicy.Space(screenID: "internal", applicationIDs: ["music"]),
                      FullscreenMediaPolicy.Space(screenID: "external", applicationIDs: ["editor"])]
        XCTAssertEqual(FullscreenMediaPolicy.status(spaces: spaces, mode: .never, mediaSource: "music"),
                       ["internal": false, "external": false])
        XCTAssertEqual(FullscreenMediaPolicy.status(spaces: spaces, mode: .allApps, mediaSource: nil),
                       ["internal": true, "external": true])
        XCTAssertEqual(FullscreenMediaPolicy.status(spaces: spaces, mode: .currentMediaApp, mediaSource: "music"),
                       ["internal": true, "external": false])
        XCTAssertEqual(FullscreenMediaPolicy.status(spaces: spaces, mode: .currentMediaApp, mediaSource: "editor"),
                       ["internal": false, "external": true])
    }

    func testSplitScreenMatchesAnyMediaAppAndLeavingFullscreenClearsState() {
        let spaces = [FullscreenMediaPolicy.Space(screenID: "display", applicationIDs: ["music"]),
                      FullscreenMediaPolicy.Space(screenID: "display", applicationIDs: ["editor"])]
        XCTAssertEqual(FullscreenMediaPolicy.status(spaces: spaces, mode: .currentMediaApp, mediaSource: "music"),
                       ["display": true])
        XCTAssertEqual(FullscreenMediaPolicy.status(spaces: [], mode: .currentMediaApp, mediaSource: "music"), [:])
    }
}
