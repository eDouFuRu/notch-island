import Defaults
import SwiftUI

struct PotatoTimerSettings: View {
    @ObservedObject private var model = IslandRestModel.shared
    var body: some View {
        Form {
            Section("Duration") {
                durationRow("Rest duration", value: Binding(get: { model.restDurationMinutes }, set: model.setRestDurationMinutes))
                durationRow("Focus duration", value: Binding(get: { model.focusDurationMinutes }, set: model.setFocusDurationMinutes))
                Text("Choose 1–120 minutes. Changes apply to the next session.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Closed notch") {
                Defaults.Toggle(key: .showRestTimerOnClosed) {
                    Text("Show the countdown on the closed notch")
                }
                Text("Off hides both the icon and the remaining time, and the notch keeps its normal width. The session itself keeps running and still settles on time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("How it works") {
                Label("30s planting + 30s roasting = 1 sweet potato", systemImage: "flame")
                Label("Finish a focus session to eat one. Canceling never uses stock.", systemImage: "timer")
                Label("You can focus with zero stock, too.", systemImage: "heart")
                Text("Focus finishes with a quiet island reminder. Start your next rest when you are ready.").foregroundStyle(.secondary)
                Text("Hidden or locked? Your reminder waits until the island is available.").foregroundStyle(.secondary)
            }
            Section("Your sweet potatoes") {
                LabeledContent("In stock", value: String(model.potatoCount))
                Text("The garden displays up to 12 potatoes. The counter keeps your entire stock.").foregroundStyle(.secondary)
            }
        }.navigationTitle(Text(verbatim: L("Sweet Potato Timer")))
    }
    private func durationRow(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(L(title))
            Spacer()
            TextField(L("Minutes"), value: value, format: .number.grouping(.never))
                .multilineTextAlignment(.trailing).frame(width: 64)
                .accessibilityLabel(L(title))
            Text("min").foregroundStyle(.secondary)
            Stepper(L(title), value: value, in: 1...120).labelsHidden()
        }
    }
}

struct IslandIconPicker: View {
    @ObservedObject private var icons = IslandIconManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                ForEach(IslandIcon.allCases, id: \.rawValue) { icon in
                    Button { icons.selected = icon } label: {
                        VStack(spacing: 8) {
                            Image(icon.assetName).resizable().frame(width: 76, height: 76)
                                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(icons.selected == icon ? Color.accentColor : .clear, lineWidth: 3))
                            Text(icon.title).font(.caption).foregroundStyle(.primary)
                            Image(systemName: icons.selected == icon ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(icons.selected == icon ? Color.accentColor : .secondary)
                        }
                    }.buttonStyle(.plain).accessibilityLabel(icon.title)
                }
            }
            Text("Applies inside the app and to the running Dock icon. Finder uses Captain Shu.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
}
