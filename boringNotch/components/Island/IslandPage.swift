import SwiftUI

struct IslandPage: View {
    let presentationID: UUID
    @ObservedObject private var model = IslandRestModel.shared
    @EnvironmentObject private var vm: BoringViewModel
    @EnvironmentObject private var pointer: NotchPointerCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var busy: Bool { model.phase == .running || model.phase == .paused }
    private var focusFinished: Bool { model.mode == .focus && model.phase == .completed }

    var body: some View {
        HStack(spacing: 16) {
            PotatoGardenScene(activity: activity, elapsed: model.elapsedSeconds,
                              inventory: model.potatoCount, isRunning: model.phase == .running,
                              harvestPulse: model.harvestAnimationSourceID == presentationID ? model.harvestAnimationID : nil,
                              harvestCount: model.harvestAnimationCount,
                              isVisible: vm.notchState == .open,
                              maximumElapsed: Double(model.durationMinutes * 60))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Sweet Potato Timer").font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer(minLength: 2)
                    Button { SettingsWindowController.shared.showTimerSettings() } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                    }.buttonStyle(.plain).help(L("Custom duration…"))
                }
                HStack(spacing: 4) {
                    modeButton(.rest, title: "Roast & recharge", icon: "flame")
                    modeButton(.focus, title: "Focus", icon: "timer")
                }
                if focusFinished {
                    Text("Ding! Your focus potato is finished. Roast the next one with Captain Shu?")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        Button("Let's roast") { model.selectMode(.rest); model.start() }.buttonStyle(ShuButtonStyle())
                        Button("Later") {
                            model.consumeFocusReminder()
                            pointer.keepExpandedForUserCommand(duration: 0)
                            vm.close(force: true)
                        }.buttonStyle(ShuButtonStyle(prominent: false))
                    }
                } else if busy {
                    runningStatus
                    Spacer(minLength: 0)
                    HStack(spacing: 14) {
                        Button(model.phase == .paused ? L("Resume") : L("Pause")) {
                            if model.phase == .paused { model.resume() } else { model.pause() }
                        }.buttonStyle(ShuButtonStyle())
                        Button("End") { model.cancel() }.buttonStyle(ShuButtonStyle(prominent: false))
                    }
                } else {
                    Text(model.phase == .completed ? L("Hot sweet potatoes are ready. Take a little sweetness back to work!") : L(model.mode == .rest ? "A little rest, a warm sweet potato." : "One bite at a time. One thing at a time."))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(ShuPalette.paper.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    Spacer(minLength: 0)
                    presets
                    HStack(spacing: 7) {
                        Button {
                            model.start()
                        } label: {
                            Text(String(format: L(model.mode == .rest ? "Roast for %lld min" : "Focus for %lld min"), model.durationMinutes))
                        }.buttonStyle(ShuButtonStyle())
                        Button("Custom…") { SettingsWindowController.shared.showTimerSettings() }
                            .buttonStyle(ShuButtonStyle(prominent: false))
                    }
                }
            }
            .frame(width: 220, height: 186, alignment: .topLeading)
        }
        .foregroundStyle(ShuPalette.paper)
        .frame(height: 194)
        .padding(.horizontal, 8)
        .onAppear { model.mountPage(presentationID) }
        .onDisappear { model.unmountPage(presentationID) }
    }

    private var activity: GardenActivity {
        guard busy else { return .idle }
        if model.mode == .focus { return .focusing }
        return model.restCycleProgress < 0.5 ? .planting : .roasting
    }

    private func modeButton(_ mode: PotatoSessionMode, title: String, icon: String) -> some View {
        Button { model.selectMode(mode) } label: {
            Label(L(title), systemImage: icon)
                .font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(model.mode == mode ? ShuPalette.shirt.opacity(0.34) : .white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain).disabled(busy)
        .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
    }

    @ViewBuilder private var runningStatus: some View {
        if model.mode == .focus {
            HStack(spacing: 15) {
                VStack(spacing: 3) {
                    ZStack {
                        Circle().stroke(ShuPalette.paper.opacity(0.12), lineWidth: 3)
                        Circle().trim(from: 0, to: max(0, 1 - model.progress))
                            .stroke(ShuPalette.flesh, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        RoastPotatoView(bites: model.focusBitesTaken).frame(width: 53, height: 34)
                    }.frame(width: 64, height: 64)
                    Text(model.clockText).font(.system(size: 17, weight: .medium, design: .rounded).monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.phase == .paused ? L("Paused. No rush.") : L("Captain Shu is saving you a warm seat."))
                        .font(.system(size: 10)).lineSpacing(2)
                    if model.potatoCount == 0 {
                        Text("A tasting potato — no stock needed").font(.system(size: 9)).foregroundStyle(ShuPalette.paper.opacity(0.5))
                    }
                }
            }
        } else {
            Text(restStageText)
                .font(.system(size: 11, weight: .medium))
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(model.clockText).font(.system(size: 25, weight: .medium, design: .rounded).monospacedDigit())
                Text(model.phase == .paused ? L("Paused") : L("remaining"))
                    .font(.system(size: 10)).foregroundStyle(ShuPalette.paper.opacity(0.5))
            }
            GeometryReader { geometry in
                Capsule().fill(ShuPalette.paper.opacity(0.13))
                    .overlay(alignment: .leading) {
                        Capsule().fill(ShuPalette.flesh)
                            .frame(width: geometry.size.width * model.restCycleProgress)
                    }
            }.frame(height: 4)
                .accessibilityLabel(L("remaining"))
                .accessibilityValue(model.clockText)
            Text("Plant. Roast. Bring home one sweet potato.")
                .font(.system(size: 9)).foregroundStyle(ShuPalette.paper.opacity(0.5))
        }
    }

    private var restStageText: String {
        switch ShuAnimationTimeline.sample(elapsed: model.elapsedSeconds, inventory: model.potatoCount).stage {
        case .hoe: return L("Loosening a little patch…")
        case .plant: return L("Tucking a sweet potato into the soil…")
        case .water: return L("A little water for the little field…")
        case .pull: return L("Pulling up a sweet potato…")
        case .turn: return L("Taking the potato to the fire…")
        case .roast: return L("Turning the potato. Almost ready…")
        case .carry: return L("Bringing a warm potato home…")
        case .place: return L("One more sweet potato for your stock…")
        case .returnHome: return L("Heading back to the little field…")
        }
    }

    private var presets: some View {
        HStack(spacing: 7) {
            ForEach(model.mode == .rest ? [1, 3, 5] : [25, 45, 60], id: \.self) { minutes in
                Button { model.setDurationMinutes(minutes) } label: {
                    Text(String(format: L("%lld min"), minutes)).font(.system(size: 10))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(model.durationMinutes == minutes ? ShuPalette.paper.opacity(0.2) : .white.opacity(0.07), in: Capsule())
                }.buttonStyle(.plain)
            }
        }
    }
}

struct ShuButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(prominent ? ShuPalette.ink : ShuPalette.paper.opacity(0.75))
            .padding(.horizontal, prominent ? 11 : 2).frame(height: 29)
            .background(prominent ? ShuPalette.flesh : .clear, in: Capsule())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
