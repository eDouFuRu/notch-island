//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import AppKit
import SwiftUI
import Defaults

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let systemIcon: String?
    let view: NotchViews

    var icon: Image {
        if let systemIcon { return Image(systemName: systemIcon) }
        return Image(nsImage: PotatoStatusIcon.image).renderingMode(.template)
    }
}

private let tabs = [
    TabModel(label: "小岛", systemIcon: nil, view: .island),
    TabModel(label: "工具主页", systemIcon: "house.fill", view: .home),
    TabModel(label: "文件暂存", systemIcon: "tray.fill", view: .shelf),
    TabModel(label: "Quick tools", systemIcon: "square.grid.2x2.fill", view: .tools)
]

struct TabSelectionView: View {
    var compact = false
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.boringShelf) private var shelfEnabled
    @Default(.tabSwitchOnHover) private var switchOnHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace var animation
    @StateObject private var hover = TabHoverSwitchController<NotchViews> { view in
        // Same transition as `select(_:)`; without it a hover switch snapped while a click
        // switch animated, so the same page change looked like two different features.
        // The environment's `reduceMotion` is not reachable from this closure — it is built
        // once, outside the view update — so the AppKit reading of the same setting is used.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? nil : .smooth) {
            BoringViewCoordinator.shared.currentView = view
        }
        // A hover switch has no click to confirm it, so the tap is the only signal that
        // the tab really changed rather than the pointer merely passing through.
        // macOS exposes no intensity control — only the pattern — so there is nothing to
        // tune here beyond which pattern is used.
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private var availableTabs: [TabModel] {
        tabs.filter { $0.view != .shelf || shelfEnabled }
    }

    var body: some View {
        if compact {
            Menu {
                ForEach(availableTabs) { tab in
                    Button { select(tab) } label: {
                        Label { Text(L(tab.label)) } icon: { tab.icon }
                    }
                }
            } label: {
                let selected = tabs.first { $0.view == coordinator.currentView } ?? tabs[0]
                Label { Text(L(selected.label)) } icon: { selected.icon }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("切换小岛与工具")
        } else {
            segmentedTabs
        }
    }

    private var segmentedTabs: some View {
        HStack(spacing: 0) {
            ForEach(availableTabs) { tab in
                    TabButton(label: L(tab.label), icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        select(tab)
                    }
                    .help(L(tab.label))
                    .accessibilityLabel(L(tab.label))
                    .accessibilityAddTraits(tab.view == coordinator.currentView ? .isSelected : [])
                    .onHover { isHovering in
                        hover.hover(tab.view, isHovering: isHovering, current: coordinator.currentView)
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
        // A pointer that leaves the bar between two buttons produces no per-tab leave
        // callback, which would let a scheduled switch land after the fact.
        .onHover { if !$0 { hover.cancel() } }
        .onChange(of: switchOnHover) { _, enabled in if !enabled { hover.cancel() } }
    }

    private func select(_ tab: TabModel) {
        withAnimation(reduceMotion ? nil : .smooth) {
            coordinator.currentView = tab.view
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
