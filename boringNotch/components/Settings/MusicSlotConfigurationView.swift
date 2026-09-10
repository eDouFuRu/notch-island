// Derived from boring.notch v2.7.3. Pure configuration preview and private drag payloads.
import Defaults
import SwiftUI

@MainActor
struct MusicSlotConfigurationView: View {
    @Default(.musicControlSlots) private var musicControlSlots
    @State private var selectedSlot: Int?
    @State private var needsTarget = false
    private var slots: [MusicControlButton] { MusicControlButton.normalized(musicControlSlots) }

    /// The close button is drawn half outside the tile, so only this much of it overlaps the
    /// drag handle and has to be carved out of the handle's hit area.
    private static let closeButtonCorner = CGSize(width: 11, height: 11)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Layout Preview").font(.headline).foregroundStyle(.secondary)
            Text(L("Drag to move or swap. Return a control to the library to remove it."))
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                HStack(spacing: 6) {
                    ForEach(0..<MediaSlotReducer.slotCount, id: \.self) { index in
                        previewSlot(at: index)
                    }
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                VStack(spacing: 6) {
                    // Both a click target and a drop target. `LocalReorderDropView.hitTest`
                    // returns nil, so the overlay marks the drop zone without taking the click.
                    Button(action: clearAllSlots) {
                        Image(systemName: "trash")
                            .font(.system(size: 17))
                            .frame(width: 48, height: 48)
                            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasOccupiedSlot)
                    .opacity(hasOccupiedSlot ? 1 : 0.4)
                    .help(L("Clear every slot, or drop a control here to remove just that one."))
                    .overlay { removalTarget(cornerRadius: 8) }
                    .accessibilityLabel(Text(L("Clear slot")))
                    Text("Clear slot").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text(L("Control library")).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(MusicControlButton.pickerOptions, id: \.self) { control in
                        VStack(spacing: 5) {
                            libraryTile(control)
                            Text(L(control.label))
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(width: 62).multilineTextAlignment(.center).lineLimit(2)
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.visible)
            .overlay { removalTarget(cornerRadius: 8) }
            if needsTarget {
                Text(L("Select a slot to replace, or drag a control onto it."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    musicControlSlots = MusicControlButton.defaultLayout
                    selectedSlot = nil
                    needsTarget = false
                }.buttonStyle(.borderless)
            }
        }
        .onAppear {
            let canonical = slots
            if canonical != musicControlSlots { musicControlSlots = canonical }
        }
    }

    @ViewBuilder private func previewSlot(at index: Int) -> some View {
        let control = slots[index]
        let occupied = control != .none
        controlTile(control)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selectedSlot == index ? Color.accentColor : .clear, lineWidth: 2)
            }
            .overlay {
                NativeMediaSlotDropTarget(cornerRadius: 8, canDrop: { _ in true },
                                          performDrop: { apply($0, to: index); return true })
            }
            .overlay(alignment: .topTrailing) {
                if occupied {
                    Button { removeSlot(index) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.primary, Color(NSColor.controlBackgroundColor))
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .help(L("Remove control"))
                    .accessibilityLabel(Text(L("Remove control") + ": " + L(control.label)))
                    .offset(x: 4, y: -4)
                }
            }
            // Topmost on purpose: the handle owns the whole tile, so the tap and the context
            // menu it would otherwise swallow are handed back to it explicitly, and the close
            // button keeps its corner via closeButtonCorner.
            .overlay {
                NativeMediaSlotDragHandle(
                    payload: occupied
                        ? MediaControlDragPayload(controlID: control.rawValue, sourceSlot: index) : nil,
                    symbolName: control.iconName,
                    prefersLargeScale: control.prefersLargeScale,
                    accessibilityHint: occupied ? L("Drag to move or swap. Return a control to the library to remove it.") : "",
                    onClick: { selectedSlot = index; needsTarget = false },
                    removeTitle: occupied ? L("Remove control") : nil,
                    onRemove: occupied ? { removeSlot(index) } : nil,
                    closeButtonCorner: Self.closeButtonCorner)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("\(L("Slot")) \(index + 1): \(L(control.label))"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { selectedSlot = index; needsTarget = false }
    }

    private func libraryTile(_ control: MusicControlButton) -> some View {
        controlTile(control)
            .overlay(alignment: .topTrailing) {
                if slots.contains(control) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(Color.accentColor)
                        .offset(x: 3, y: -3).accessibilityHidden(true)
                }
            }
            .overlay {
                NativeMediaSlotDragHandle(
                    payload: MediaControlDragPayload(controlID: control.rawValue, sourceSlot: nil),
                    symbolName: control.iconName,
                    prefersLargeScale: control.prefersLargeScale,
                    accessibilityHint: L(control.label),
                    onClick: { addFromLibrary(control) },
                    removeTitle: nil,
                    onRemove: nil,
                    closeButtonCorner: .zero)
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(L(control.label)))
            .accessibilityAction { addFromLibrary(control) }
    }

    /// Trash and library both mean the same thing to the reducer: put the control back.
    /// Only a control that currently occupies a slot can be returned.
    private func removalTarget(cornerRadius: CGFloat) -> some View {
        NativeMediaSlotDropTarget(cornerRadius: cornerRadius,
                                  canDrop: { $0.sourceSlot != nil },
                                  performDrop: { apply($0, to: nil); return true })
    }

    /// No player, notch state, side effects, or runtime controls enter this preview.
    private func controlTile(_ control: MusicControlButton) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor))
            if control == .none {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.4)).padding(6)
            } else {
                Image(systemName: control.iconName)
                    .font(.system(size: control.prefersLargeScale ? 18 : 15, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var hasOccupiedSlot: Bool { slots.contains { $0 != .none } }

    private func clearAllSlots() {
        musicControlSlots = MusicControlButton.normalized(
            Array(repeating: .none, count: MediaSlotReducer.slotCount))
        selectedSlot = nil
        needsTarget = false
    }

    private func apply(_ payload: MediaControlDragPayload, to target: Int?) {
        musicControlSlots = MusicControlButton.applying(payload, to: target, in: musicControlSlots)
        selectedSlot = target
        needsTarget = false
    }

    private func removeSlot(_ index: Int) {
        apply(MediaControlDragPayload(controlID: slots[index].rawValue, sourceSlot: index), to: nil)
    }

    private func addFromLibrary(_ control: MusicControlButton) {
        guard let target = selectedSlot ?? slots.firstIndex(of: control) ?? slots.firstIndex(of: .none) else {
            needsTarget = true
            return
        }
        apply(MediaControlDragPayload(controlID: control.rawValue, sourceSlot: nil), to: target)
    }
}
