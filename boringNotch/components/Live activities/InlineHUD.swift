import Defaults
import SwiftUI

/// Two symmetric wings around the exact camera gap, in both closed and open shells.
struct InlineHUD: View {
    @EnvironmentObject private var vm: BoringViewModel
    let state: SystemHUDState
    let layout: SystemHUDLayout

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: state.symbolName).frame(width: 18)
                Text(L(vm.notchState == .closed && state.activeKind == .backlight ? "Backlight" : state.titleKey))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .help(L(state.titleKey))
                    .accessibilityLabel(Text(L(state.titleKey)))
            }
            .padding(.horizontal, 10)
            .frame(width: layout.wingWidth, alignment: .leading)

            Color.clear.frame(width: layout.physicalGapWidth)
                .accessibilityHidden(true)

            SystemHUDValue(state: state, inline: true)
                .padding(.horizontal, 10)
                .frame(width: layout.wingWidth)
        }
        .foregroundStyle(.white)
        .frame(height: layout.headerHeight)
        .accessibilityElement(children: .combine)
    }
}

/// Default HUD adds one row below the header; the page body keeps its own height.
struct SystemHUDRow: View {
    let state: SystemHUDState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: state.symbolName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22, height: 22)
            Text(L(state.titleKey)).font(.system(size: 12, weight: .medium)).lineLimit(1)
            SystemHUDValue(state: state, inline: false)
        }
        .padding(.horizontal, 16)
        .foregroundStyle(.white)
        .frame(height: SystemHUDLayout.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// The charging notice, wearing the HUD's geometry.
///
/// It deliberately shares `SystemHUDLayout` with volume and brightness instead of owning a
/// width: the old battery banner hardcoded 640pt and had no horizontal inset, so plugging in
/// produced a bar far wider than any other notice with its text jammed against both edges.
/// Only the *layout* is shared — the notice is driven by `expandingView`, not by
/// `HUDStateManager`, so it never depends on accessibility authorisation.
struct PowerNoticeRow: View {
    @ObservedObject private var battery = BatteryStatusViewModel.shared
    let inline: Bool
    let layout: SystemHUDLayout

    var body: some View {
        if inline {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: symbolName).frame(width: 18)
                    Text(L(battery.statusText))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                .padding(.horizontal, 10)
                .frame(width: layout.wingWidth, alignment: .leading)

                Color.clear.frame(width: layout.physicalGapWidth)
                    .accessibilityHidden(true)

                glyph
                    .padding(.horizontal, 10)
                    .frame(width: layout.wingWidth, alignment: .trailing)
            }
            .foregroundStyle(.white)
            .frame(height: layout.headerHeight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(L(battery.statusText)))
        } else {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22, height: 22)
                Text(L(battery.statusText)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                glyph
            }
            .padding(.horizontal, 16)
            .foregroundStyle(.white)
            .frame(height: SystemHUDLayout.rowHeight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(L(battery.statusText)))
        }
    }

    private var symbolName: String {
        battery.isPluggedIn ? "powerplug.fill" : "powerplug"
    }

    private var glyph: some View {
        BoringBatteryView(batteryWidth: 30, isCharging: battery.isCharging,
                          isInLowPowerMode: battery.isInLowPowerMode,
                          isPluggedIn: battery.isPluggedIn,
                          levelBattery: battery.levelBattery,
                          isForNotification: true)
    }
}

private struct SystemHUDValue: View {
    @EnvironmentObject private var vm: BoringViewModel
    @Default(.systemEventIndicatorUseAccent) private var useAccent
    let state: SystemHUDState
    let inline: Bool

    var body: some View {
        Group {
            if let error = state.error {
                Text(L(inline && vm.notchState == .closed ? "Unavailable" : error))
                    .font(.system(size: inline ? 10 : 11))
                    .foregroundStyle(.orange).lineLimit(inline ? 1 : 2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(L(error))
                    .accessibilityLabel(Text(L(error)))
            } else if state.activeKind == .mic {
                Text(L(state.value == 0 ? "muted" : "unmuted"))
                    .font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                HStack(spacing: 6) {
                    if inline {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.18))
                                Capsule().fill(useAccent ? Color.effectiveAccent : .white)
                                    .frame(width: geometry.size.width * state.value)
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                                guard geometry.size.width > 0 else { return }
                                updateValue(drag.location.x / geometry.size.width)
                            })
                            .allowsHitTesting(vm.notchState == .open)
                        }
                        .frame(height: 6)
                    } else {
                        DraggableProgressBar(value: Binding(get: { CGFloat(state.value) }, set: updateValue))
                            .frame(height: 9)
                            .allowsHitTesting(vm.notchState == .open)
                    }
                    Text("\(Int((state.value * 100).rounded()))%")
                        .font(.system(size: 10, design: .rounded).monospacedDigit())
                        .fixedSize()
                }
                .accessibilityValue(Text("\(Int((state.value * 100).rounded()))%"))
            }
        }
    }

    private func updateValue(_ value: CGFloat) {
        let clamped = Float(min(1, max(0, value)))
        switch state.activeKind {
        case .volume: VolumeManager.shared.setAbsolute(clamped)
        case .brightness: BrightnessManager.shared.setAbsolute(value: clamped)
        case .backlight: KeyboardBacklightManager.shared.setAbsolute(value: clamped)
        case .mic, nil: break
        }
    }
}

private extension SystemHUDState {
    var titleKey: String {
        switch activeKind {
        case .volume: return "Volume"
        case .brightness: return "Brightness"
        case .backlight: return "Keyboard backlight"
        case .mic: return "Microphone"
        case nil: return ""
        }
    }
    var symbolName: String {
        if error != nil { return "exclamationmark.triangle.fill" }
        if !icon.isEmpty { return icon }
        switch activeKind {
        case .volume: return value == 0 ? "speaker.slash.fill" : value < 0.34 ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .brightness: return "sun.max.fill"
        case .backlight: return value > 0.5 ? "light.max" : "light.min"
        case .mic: return value == 0 ? "mic.slash.fill" : "mic.fill"
        case nil: return "circle"
        }
    }
}
