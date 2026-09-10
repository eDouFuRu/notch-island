//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @EnvironmentObject var pointer: NotchPointerCoordinator
    @ObservedObject private var visibility = IslandVisibility.shared
    @ObservedObject private var rest = IslandRestModel.shared
    @ObservedObject private var systemHUD = SystemHUDPresentation.shared
    @ObservedObject private var brief = BriefPresentationCoordinator.shared
    @ObservedObject private var lyrics = LyricsStore.shared
    @ObservedObject private var shelf = ShelfStateViewModel.shared
    private var lyricsAppearance = LyricsAppearance()
    @ObservedObject private var hi = HiNotificationManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentationID = UUID()
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    @Default(.coloredSpectrogram) private var coloredSpectrogram
    @Default(.cornerRadiusScaling) private var cornerRadiusScaling
    @Default(.enableHaptics) private var enableHaptics
    @Default(.enableShadow) private var enableShadow
    @Default(.inlineHUD) private var inlineHUD
    @Default(.hudReplacement) private var hudReplacement
    @Default(.playerColorTinting) private var playerColorTinting
    @Default(.showPowerStatusNotifications) private var showPowerStatusNotifications
    @Default(.showRestTimerOnClosed) private var showRestTimerOnClosed
    @Default(.sneakPeekStyles) private var sneakPeekStyles
    @Default(.boringShelf) private var boringShelf

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && cornerRadiusScaling)
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && cornerRadiusScaling)
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    private var closedMediaLayout: ClosedMediaLayout {
        ClosedMediaLayout(notchWidth: vm.closedNotchSize.width,
                          height: vm.effectiveClosedNotchHeight,
                          inlineMetadata: coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                            && sneakPeekStyles == .inline,
                          maximumWidth: openNotchSize.width)
    }

    private var computedChinWidth: CGFloat {
        if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
            return closedMediaLayout.shellWidth
        }
        if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle)
            && showNotHumanFace && !vm.hideOnClosed {
            return vm.closedNotchSize.width + 2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20
        }
        return vm.closedNotchSize.width
    }

    private var resting: Bool { rest.phase == .running || rest.phase == .paused }
    /// Whether the closed shell gives the countdown its wings. The header and the width both
    /// read this one value rather than testing `resting` apiece: those are two hand-written
    /// branch chains, and letting them disagree is how a shell ends up 88pt wider than the
    /// thing it was widened for.
    private var showsRestOnClosed: Bool { resting && showRestTimerOnClosed }
    private var isOpen: Bool { vm.notchState == .open }
    private var headerHeight: CGFloat {
        max(24, max(vm.closedNotchSize.height, vm.screenUUID.flatMap { NSScreen.screen(withUUID: $0)?.safeAreaInsets.top } ?? 0))
    }
    private var bottomRadius: CGFloat { isOpen && cornerRadiusScaling ? 24 : 14 }
    private var systemHUDVisible: Bool { visibility.isAvailable && systemHUD.activeKind != nil }
    /// The charging notice rides the HUD chrome so it can appear while the island is open.
    /// It used to live in `closedHeader`, which is only ever used when the island is closed —
    /// so with a pinned page (the shelf) holding the island open, the notice silently expired
    /// against its 3s timer without ever being drawn.
    private var powerNoticeVisible: Bool {
        visibility.isAvailable && showPowerStatusNotifications && hudReplacement
            && coordinator.expandingView.show && coordinator.expandingView.type == .battery
    }
    /// The system HUD wins a tie: a deliberate key press outranks a passive power event.
    private var noticeChromeActive: Bool { systemHUDVisible || powerNoticeVisible }
    private var briefSource: BriefPresentationSource {
        brief.state.selection(now: ProcessInfo.processInfo.systemUptime, hudActive: noticeChromeActive,
                              hiEnabled: hi.current != nil,
                              songEnabled: coordinator.sneakPeek.show && sneakPeekStyles == .standard && (isOpen || !vm.hideOnClosed),
                              lyricAvailable: lyrics.shouldShowNotch && (isOpen || !vm.hideOnClosed))
    }
    private var briefVisible: Bool { briefSource.usesBriefRow }
    private var briefHeaderHeight: CGFloat { briefVisible ? headerHeight : max(0, vm.effectiveClosedNotchHeight) }
    private var briefLayout: BriefPresentationLayout {
        BriefPresentationLayout(active: briefVisible, standardHUD: noticeChromeActive && !inlineHUD,
                                expanded: isOpen,
                                baseClosedSize: CGSize(width: baseClosedWidth, height: briefHeaderHeight),
                                baseExpandedHeight: baseExpandedHeight, headerHeight: headerHeight,
                                minimumBriefWidth: briefSource == .hi ? BriefPresentationLayout.noticeMinimumWidth : 0)
    }
    private var baseExpandedHeight: CGFloat {
        // Derived from the grid's own constants so the island is exactly tall enough for a
        // whole number of rows. A hand-tuned floor here is what previously left a spare
        // half row visible below the third one.
        if coordinator.currentView == .tools {
            return max(openNotchSize.height, SystemToolGridMetrics.expandedHeight(headerHeight: headerHeight))
        }
        return coordinator.currentView == .island ? max(250, headerHeight + 214) : max(openNotchSize.height, headerHeight + 156)
    }
    private var baseClosedWidth: CGFloat {
        if vm.hideOnClosed { return vm.closedNotchSize.width }
        if showsRestOnClosed { return vm.closedNotchSize.width + 88 }
        return max(vm.closedNotchSize.width + 12, computedChinWidth)
    }
    private var hudLayout: SystemHUDLayout {
        SystemHUDLayout(active: noticeChromeActive, inline: inlineHUD, expanded: isOpen,
                        notchWidth: vm.closedNotchSize.width, headerHeight: headerHeight,
                        baseClosedSize: isOpen ? CGSize(width: baseClosedWidth, height: briefHeaderHeight) : briefLayout.size,
                        baseExpandedHeight: baseExpandedHeight + briefLayout.addedHeight, expandedWidth: openNotchSize.width)
    }
    private var visibleWidth: CGFloat { hudLayout.size.width }
    private var visibleHeight: CGFloat { hudLayout.size.height }
    private var shellAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: isOpen ? 0.42 : 0.45,
                       dampingFraction: isOpen ? 0.8 : 1.0, blendDuration: 0)
    }

    /// The shelf is pinned open, so it needs a dismiss control that does not depend on the
    /// pointer leaving. It floats clear of the island rather than sitting on the panel,
    /// where it would cover the rightmost item.
    ///
    /// Drawn here, outside the clipped black shape, and positioned from the same constants
    /// `NotchPointerCoordinator` uses to widen the hit region — the window is otherwise
    /// click-through out here, so the two must agree or the button renders but never
    /// responds.
    private var showsFloatingCollapse: Bool { isOpen && coordinator.currentView == .shelf }

    @ViewBuilder
    private var floatingAccessoryControls: some View {
        if showsFloatingCollapse {
            accessoryButton(slot: .collapse, symbol: "chevron.up", label: L("Collapse the island"),
                            enabled: true) { vm.close(force: true) }
            // Always drawn, dimmed when there is nothing to clear: hiding it would leave the
            // collapse button alone in the upper half and break the symmetry the pair is for.
            accessoryButton(slot: .clearShelf, symbol: "trash", label: L("Clear the shelf"),
                            enabled: !shelf.isEmpty) { shelf.clearAll() }
        }
    }

    private func accessoryButton(slot: NotchAccessorySlot, symbol: String, label: String,
                                 enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.35))
                .frame(width: NotchAccessoryControl.diameter,
                       height: NotchAccessoryControl.diameter)
                .background(Circle().fill(Color.black.opacity(0.82)))
                .overlay(Circle().stroke(.white.opacity(enabled ? 0.22 : 0.1), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // `.overlay(alignment: .top)` aligns the button's *top edge* to the window's top
        // edge, so the y offset must be a top-edge offset; `topEdgeOffset` is the only place
        // that arithmetic lives. Horizontally the overlay *is* centre aligned, so
        // `centerOffsetX` is a centre offset. Two different conventions on purpose.
        .offset(x: NotchAccessoryControl.centerOffsetX(visibleWidth: visibleWidth),
                y: NotchAccessoryControl.topEdgeOffset(visibleHeight: visibleHeight, slot: slot))
        .help(label)
        .accessibilityLabel(label)
        .transition(.opacity)
    }

    var body: some View {
        NotchLayout()
            .padding(.horizontal, isOpen ? 31 : 6)
            .padding(.bottom, isOpen ? 12 : 0)
            .frame(width: visibleWidth, height: visibleHeight, alignment: .top)
            .background(.black)
            .clipShape(NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomRadius))
            .overlay(alignment: .top) {
                Rectangle().fill(.black).frame(height: 1).padding(.horizontal, topCornerRadius)
            }
            .shadow(color: isOpen && enableShadow ? .black.opacity(0.6) : .clear, radius: 6)
            .modifier(NotchPresentationReporter(width: visibleWidth, height: visibleHeight,
                                                topRadius: topCornerRadius, bottomRadius: bottomRadius,
                                                coordinator: pointer))
            .animation(shellAnimation, value: vm.notchState)
            .animation(shellAnimation, value: visibleWidth)
            .animation(shellAnimation, value: visibleHeight)
            .animation(shellAnimation, value: systemHUD.activeKind)
            .frame(width: windowSize.width, height: windowSize.height, alignment: .top)
            // Overlaid on the full window, not on the island: SwiftUI will not reliably hit
            // test a child that overflows its parent's bounds, and this one sits outside
            // the island by design. The island is centred in the window, so the offsets
            // below are still measured from the island's centre.
            .overlay(alignment: .top) { floatingAccessoryControls }
            .opacity(!isOpen && !systemHUDVisible && !briefVisible && vm.effectiveClosedNotchHeight == 0 ? 0 : 1)
            .preferredColorScheme(.dark)
            .modifier(IslandLocalization())
            .onAppear {
                syncPresentation()
                pointer.setAccessoryControlVisible(showsFloatingCollapse)
            }
            .onChange(of: showsFloatingCollapse) { _, visible in
                pointer.setAccessoryControlVisible(visible)
            }
            .onChange(of: vm.notchState) {
                syncPresentation(); pointer.reevaluate()
                if isOpen && enableHaptics { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            }
            .onChange(of: coordinator.currentView) { syncPresentation() }
            .onChange(of: briefSource) { syncBriefPresentation() }
            .onChange(of: lyrics.shouldShowNotch) { syncBriefPresentation() }
            .onChange(of: vm.hideOnClosed) { syncBriefPresentation() }
            .onChange(of: boringShelf) {
                if !boringShelf && coordinator.currentView == .shelf { coordinator.currentView = .home }
            }
            .onChange(of: visibility.isHidden) { syncPresentation() }
            .onChange(of: visibility.screenUnavailable) { syncPresentation() }
            .onChange(of: vm.isBatteryPopoverActive) { pointer.reevaluate() }
            .onChange(of: hudLayout.showsInline) {
                // Replacing the header dismisses its popover and its keep-open claim.
                if hudLayout.showsInline { vm.isBatteryPopoverActive = false }
            }
            .onDisappear {
                rest.removePresentation(sourceID: presentationID)
                lyrics.removeNotchPresentation(sourceID: presentationID)
                brief.setHovered(sourceID: presentationID, hovered: false)
            }
    }

    private func syncPresentation() {
        syncBriefPresentation()
        rest.setPresentation(sourceID: presentationID, notchOpen: isOpen,
                             isIslandPage: coordinator.currentView == .island,
                             hidden: visibility.isHidden, locked: visibility.screenUnavailable)
    }

    private func syncBriefPresentation() {
        // Keep the eligible lyric clock alive through a blank intro/interlude,
        // so the next real cue can reveal the row without a metadata event.
        let lyricMayPresent = visibility.isAvailable && (isOpen || !vm.hideOnClosed)
            && (briefSource == .lyric || briefSource == .none)
        lyrics.setNotchPresentation(sourceID: presentationID, visible: lyricMayPresent)
        pointer.configureBriefRow(topInset: briefVisible ? briefLayout.rowTopInset : nil,
                                  interactive: briefSource == .hi, horizontalInset: isOpen ? 31 : 6) { hovered in
            brief.setHovered(sourceID: presentationID, hovered: hovered)
        }
    }

    @ViewBuilder private var briefRow: some View {
        switch briefSource {
        case .hi:
            if let notice = hi.current {
                BriefPromptRow(text: hi.displayText(for: notice), applicationIcon: hi.icon(for: notice),
                               action: { hi.clickLatest() })
            }
        case .songChange:
            BriefPromptRow(text: musicManager.songTitle + " – " + musicManager.artistName,
                           tint: playerColorTinting ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray)
        case .lyric:
            BriefPromptRow(text: lyrics.displayText, symbol: "text.quote", tint: lyricsAppearance.color)
        default: EmptyView()
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                if hudLayout.showsInline {
                    Group {
                        if systemHUDVisible {
                            InlineHUD(state: systemHUD.state, layout: hudLayout)
                        } else {
                            PowerNoticeRow(inline: true, layout: hudLayout)
                        }
                    }
                    .transition(.opacity)
                } else if isOpen {
                    BoringHeader().frame(height: headerHeight)
                } else {
                    closedHeader
                        .frame(height: noticeChromeActive ? headerHeight : briefHeaderHeight)
                }
                if hudLayout.showsRow {
                    Group {
                        if systemHUDVisible {
                            SystemHUDRow(state: systemHUD.state)
                        } else {
                            PowerNoticeRow(inline: false, layout: hudLayout)
                        }
                    }
                    .transition(.opacity)
                } else if briefVisible {
                    briefRow.transition(.opacity)
                }
            }
            .zIndex(2)

            if isOpen {
                Group {
                    switch coordinator.currentView {
                    case .island:
                        IslandPage(presentationID: presentationID)
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    case .tools:
                        SystemToolsPage()
                    }
                }
                .padding(.top, 8)
                // Inserting a default HUD row never compresses the page's controls.
                .frame(height: max(0, baseExpandedHeight - headerHeight - 12), alignment: .top)
                .transition(.scale(scale: 0.8, anchor: .top).combined(with: .opacity)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.35)))
                .zIndex(1)
                .allowsHitTesting(isOpen)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting, onEnter: openShelfForDrag))
    }

    /// Landing on the media page with a file in hand leaves nowhere to drop it, so a drag
    /// always lands on the shelf. This goes through `open(preferredPage:)`, which bypasses
    /// the `openShelfByDefault` branch entirely — the setting keeps governing plain hovering
    /// and needs no companion switch of its own.
    private func openShelfForDrag() {
        guard boringShelf else { return }
        withAnimation(vm.animationLibrary.animation) {
            vm.open(preferredPage: .shelf)
        }
    }

    @ViewBuilder
    private var closedHeader: some View {
        if vm.hideOnClosed {
            Color.clear.frame(width: vm.closedNotchSize.width)
        } else if showsRestOnClosed {
            HStack(spacing: 0) {
                Image(systemName: rest.mode == .focus ? "timer" : "flame.fill")
                    .foregroundStyle(ShuPalette.flesh).frame(maxWidth: .infinity)
                Color.clear.frame(width: vm.closedNotchSize.width)
                Text(rest.clockText).font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity)
            }
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
                    && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled {
            MusicLiveActivity()
        } else if !coordinator.expandingView.show && !musicManager.isPlaying && musicManager.isPlayerIdle && showNotHumanFace {
            BoringFaceAnimation()
        } else {
            Color.clear.frame(width: vm.closedNotchSize.width)
        }
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        let layout = closedMediaLayout
        HStack(spacing: 0) {
            HStack(spacing: layout.itemSpacing) {
                Image(nsImage: musicManager.albumArt)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: layout.artworkSize, height: layout.artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed))
                    .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                if layout.metadataWidth > 0 {
                    Text(musicManager.songTitle)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: layout.metadataWidth, alignment: .leading)
                }
            }
            .padding(.horizontal, layout.wingInset)
            .frame(width: layout.wingWidth)

            Color.clear.frame(width: layout.physicalGapWidth)
                .accessibilityHidden(true)

            HStack(spacing: layout.itemSpacing) {
                if layout.metadataWidth > 0 {
                    Text(musicManager.artistName)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: layout.metadataWidth, alignment: .trailing)
                }
                Group {
                    if useMusicVisualizer {
                        Rectangle()
                            .fill(coloredSpectrogram
                                  ? Color(nsColor: musicManager.avgColor).gradient : Color.gray.gradient)
                            .frame(width: ClosedMediaLayout.spectrumSize.width,
                                   height: ClosedMediaLayout.spectrumSize.height)
                            .mask {
                                AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                                    .frame(width: ClosedMediaLayout.spectrumSize.width,
                                           height: ClosedMediaLayout.spectrumSize.height)
                            }
                    } else {
                        LottieAnimationContainer()
                            .frame(width: layout.artworkSize, height: layout.artworkSize)
                    }
                }
                .frame(width: layout.artworkSize, height: layout.artworkSize)
            }
            .padding(.horizontal, layout.wingInset)
            .frame(width: layout.wingWidth)
        }
        .foregroundStyle(coloredSpectrogram ? Color(nsColor: musicManager.avgColor) : .gray)
        .frame(width: layout.contentWidth, height: layout.height)
    }


}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    /// Carrying a file is an unambiguous statement of intent, so it overrides whatever page
    /// hovering alone would have picked. Empty-handed hovering still follows the setting.
    var onEnter: () -> Void = {}

    func dropEntered(info: DropInfo) {
        isTargeted = true
        onEnter()
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}
