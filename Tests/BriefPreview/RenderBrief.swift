import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

func L(_ text: String) -> String { text }

/// This exactly reconstructs the former ContentView music-row geometry. The
/// legacy MarqueeText itself is compiled from its production source, not copied.
private struct ReconstructedLegacyRow: View {
    static let height: CGFloat = 40
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
            GeometryReader { geometry in
                MarqueeText(.constant(text), textColor: .gray, minDuration: 1, frameWidth: geometry.size.width)
            }
        }
        .foregroundStyle(.gray)
        .padding(.horizontal, 8)
        .frame(height: Self.height)
    }
}

@main @MainActor
struct RenderBrief {
    struct Fixture {
        let name, language, text, symbol: String
        var hi = false
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Brief preview failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let rowHeight = BriefPresentationLayout.rowHeight
        let legacyHeight = ReconstructedLegacyRow.height
        let hiPath = "/Applications/hi.app"
        let hiInstalled = FileManager.default.fileExists(atPath: hiPath)
        let hiIcon = hiInstalled ? NSWorkspace.shared.icon(forFile: hiPath) : nil
        let fixtures = [
            Fixture(name: "music-zh", language: "zh-Hans", text: "今日播放 · 清晨的微光 — 示例音乐人", symbol: "music.note"),
            Fixture(name: "music-en", language: "en", text: "Now playing · Morning Light — Example Artist", symbol: "music.note"),
            Fixture(name: "lyric-zh", language: "zh-Hans", text: "让风把今天的忙碌轻轻带走，沿着阳光慢慢向前，听见心里温柔的回答。", symbol: "text.quote"),
            Fixture(name: "lyric-en", language: "en", text: "Let the morning carry every little worry away, and follow the sunlight to a quieter day.", symbol: "text.quote"),
            Fixture(name: "hi-private-zh", language: "zh-Hans", text: "hi · 3 条新消息", symbol: "message.fill", hi: true),
            Fixture(name: "hi-private-en", language: "en", text: "hi · 3 new messages", symbol: "message.fill", hi: true),
            Fixture(name: "hi-detail-zh", language: "zh-Hans", text: "示例项目群 · 这是一条仅用于排版的测试消息，稍后一起确认设计稿。", symbol: "message.fill", hi: true),
            Fixture(name: "hi-detail-en", language: "en", text: "Example team · This is synthetic layout text. Let us review the draft together later today.", symbol: "message.fill", hi: true),
        ]
        var results: [[String: Any]] = []
        for width in [257.0, 578.0] {
            for fixture in fixtures {
                for reduced in [false, true] {
                    let name = "\(fixture.name)-w\(Int(width))-\(reduced ? "reduced" : "normal")"
                    let actual = BriefPromptRow(text: fixture.text, symbol: fixture.symbol,
                        applicationIcon: fixture.hi ? hiIcon : nil, previewReduceMotion: reduced,
                        action: fixture.hi ? {} : nil)
                        .environment(\.locale, Locale(identifier: fixture.language))
                    try hosted(actual, width: width, height: rowHeight, name: name, output: output)
                    results.append(["name": name, "widthPoints": width, "heightPoints": rowHeight,
                                    "language": fixture.language, "reduceMotion": reduced,
                                    "source": "BriefPromptRow.swift", "hiIcon": fixture.hi && hiInstalled])
                }
            }
            for fixture in fixtures.prefix(2) {
                try hosted(ReconstructedLegacyRow(text: fixture.text)
                    .environment(\.locale, Locale(identifier: fixture.language)), width: width,
                    height: legacyHeight, name: "legacy-reconstructed-\(fixture.name)-w\(Int(width))", output: output)
            }
        }
        for width in [257, 578] {
            for language in ["zh", "en"] {
                let old = output.appendingPathComponent("legacy-reconstructed-music-\(language)-w\(width)-2x.png")
                let new = output.appendingPathComponent("music-\(language)-w\(width)-normal-2x.png")
                let comparison = VStack(alignment: .leading, spacing: 10) {
                    Text("\(width)-point content area · \(Int(legacyHeight)) → \(Int(rowHeight))-point row").font(.system(size: 15, weight: .semibold))
                    Text("Before: reconstructed legacy geometry (not a historical screenshot)").font(.system(size: 11))
                    annotatedImage(old, width: CGFloat(width), height: legacyHeight)
                    Text("After: actual BriefPromptRow.swift · shared \(Int(rowHeight))-point height").font(.system(size: 11))
                    annotatedImage(new, width: CGFloat(width), height: rowHeight)
                    Text("Green: each row's center (\(Int(legacyHeight / 2)) / \(Int(rowHeight / 2)) pt). Cyan: actual bounds.").font(.system(size: 10))
                }.padding(16).foregroundStyle(.white).background(Color(white: 0.12))
                try rendered(comparison, to: output.appendingPathComponent("comparison-\(language)-w\(width).png"), scale: 2)
            }
        }
        for width in [257, 578] {
            let sheet = VStack(alignment: .leading, spacing: 10) {
                Text("Actual BriefPromptRow · \(width) × \(Int(rowHeight)) points").font(.system(size: 15, weight: .semibold))
                Text("Synthetic fixtures · macOS NSHostingView · static initial layout").font(.system(size: 10))
                ForEach(results.filter { ($0["widthPoints"] as? Double) == Double(width) }, id: \.description) { result in
                    let name = result["name"] as! String
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.system(size: 9, design: .monospaced))
                        annotatedImage(output.appendingPathComponent(name + "-2x.png"), width: CGFloat(width), height: rowHeight)
                    }
                }
            }.padding(16).foregroundStyle(.white).background(Color(white: 0.12))
            try rendered(sheet, to: output.appendingPathComponent("overview-w\(width).png"), scale: 1)
        }
        let summary: [String: Any] = ["actualSourceFixtures": results, "legacyReconstructedRows": 4,
            "actualRowHeightPoints": rowHeight, "legacyRowHeightPoints": legacyHeight,
            "hiIconLoadedViaNSWorkspace": hiInstalled, "hiIconApplicationPath": hiPath,
            "windowsOrderedFront": false, "applicationActivated": false,
            "privateNotificationContentRead": false, "productionPreferencesRead": false,
            "reduceMotionEvidence": "Explicit view preview override; actual macOS accessibility preference switching is not tested"]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("render-summary.json"))
        print("Rendered 32 actual rows and 4 reconstructed legacy rows at 1x/2x; application never activated.")
    }

    private static func hosted<V: View>(_ view: V, width: Double, height: CGFloat, name: String, output: URL) throws {
        let content = view.frame(width: width, height: height).background(Color.black).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        // Let legacy preference-based text measurement settle without showing
        // or activating a window. Animation's two-second initial hold remains.
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale,
                pixelsHigh: Int(height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw NSError(domain: "BriefPreview", code: 1)
            }
            bitmap.size = CGSize(width: width, height: height)
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "BriefPreview", code: 2)
            }
            try data.write(to: output.appendingPathComponent("\(name)-\(scale)x.png"))
        }
        window.close()
    }

    private static func annotatedImage(_ url: URL, width: CGFloat, height: CGFloat) -> some View {
        Image(nsImage: NSImage(contentsOf: url)!).resizable().frame(width: width, height: height)
            .overlay(Rectangle().stroke(.cyan.opacity(0.7), lineWidth: 0.5))
            .overlay(alignment: .center) { Rectangle().fill(.green.opacity(0.5)).frame(height: 0.5) }
    }

    private static func rendered<V: View>(_ view: V, to url: URL, scale: CGFloat) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "BriefPreview", code: 3)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "BriefPreview", code: 4) }
    }
}
