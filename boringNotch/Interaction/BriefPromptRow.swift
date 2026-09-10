import AppKit
import SwiftUI

/// Compact shared row; text, shell and pointer geometry use the same height.
struct BriefPromptRow: View {
    let text: String
    var symbol: String = "music.note"
    var applicationIcon: NSImage? = nil
    var tint: Color = .white.opacity(0.85)
    var scrolls = true
    /// Isolated preview override; production uses the system environment.
    var previewReduceMotion: Bool? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) { row }
                    .buttonStyle(.plain)
                    .accessibilityLabel(text)
                    .accessibilityHint(L("Open the latest hi conversation"))
            } else {
                row.allowsHitTesting(false)
            }
        }
        .frame(height: BriefPresentationLayout.rowHeight)
    }
    private var row: some View {
        HStack(alignment: .center, spacing: 9) {
            Group {
                if let applicationIcon {
                    Image(nsImage: applicationIcon).resizable().scaledToFit()
                } else {
                    Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            GeometryReader { geometry in
                BriefMarquee(text: text, width: geometry.size.width, color: tint, scrolls: scrolls,
                             previewReduceMotion: previewReduceMotion)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: BriefPresentationLayout.rowHeight, maxHeight: BriefPresentationLayout.rowHeight, alignment: .center)
        .contentShape(Rectangle())
    }
}

private struct BriefMarquee: View {
    let text: String
    let width: CGFloat
    let color: Color
    let scrolls: Bool
    let previewReduceMotion: Bool?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { previewReduceMotion ?? systemReduceMotion }
    @State private var origin = Date()
    private let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private var textWidth: CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    private var moving: Bool { scrolls && !reduceMotion && textWidth > width }

    var body: some View {
        Group {
            if moving {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let elapsed = context.date.timeIntervalSince(origin)
                    // Hold the beginning, reveal the rest once, then keep the
                    // ending readable until the next lyric resets this clock.
                    let offset = BriefMarqueeProgress.offset(textWidth: textWidth, viewportWidth: width, elapsed: elapsed)
                    label.fixedSize()
                        .offset(x: -offset)
                        .frame(width: max(0, width), alignment: .leading)
                }
            } else {
                label.lineLimit(1).truncationMode(.tail)
                    .frame(width: max(0, width), alignment: .leading)
            }
        }
        .frame(height: BriefPresentationLayout.rowHeight, alignment: .center)
        .clipped()
        .onChange(of: text) { origin = Date() }
        .onChange(of: width) { origin = Date() }
        .onChange(of: reduceMotion) { origin = Date() }
    }
    private var label: some View { Text(verbatim: text).font(.system(size: 13, weight: .medium)).foregroundStyle(color) }
}
