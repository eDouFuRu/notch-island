import AppKit
import SwiftUI

enum Shu25DAsset: String, CaseIterable {
    case captainBase = "captain-base", captainHolding = "captain-holding"
    case armNear = "arm-near", armFar = "arm-far"
    case shortArm = "short-arm"
    case upperArm = "upper-arm", forearm
    case palmBack = "palm-back", fingersFront = "fingers-front"
    case legNear = "leg-near", legFar = "leg-far"
    case hoe, wateringCan = "watering-can", seedling
    case rawPotato = "raw-potato", roastPotato = "roast-potato", firepit, ground
    var imageName: String { "Shu25D-" + rawValue }
}

/// Images are decoded once, outside the animation sampling loop. Asset-catalog
/// names and ordinary bundle PNGs are both supported by the static QA harness.
@MainActor enum Shu25DAssets {
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let id: String
            let pivot: [Double]
            let end: [Double]?
            let rigShoulder: [Double]?
            let hand: [Double]?
            let emitter: [Double]?
            let contentBounds: [Double]?
        }
        let assets: [Entry]
    }
    private static let entries: [String: Manifest.Entry] = {
        guard let url = Bundle.main.url(forResource: "Shu25DAssets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [:] }
        return Dictionary(manifest.assets.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }()
    private static let images: [Shu25DAsset: NSImage] = {
        var result: [Shu25DAsset: NSImage] = [:]
        for asset in Shu25DAsset.allCases {
            if let url = Bundle.main.url(forResource: asset.imageName, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                result[asset] = image
            } else if let image = NSImage(named: NSImage.Name(asset.imageName)) {
                result[asset] = image
            }
        }
        return result
    }()
    static func image(_ asset: Shu25DAsset) -> NSImage? { images[asset] }
    static func size(_ asset: Shu25DAsset, fitting limit: CGSize) -> CGSize {
        guard let source = image(asset)?.size, source.width > 0, source.height > 0 else { return limit }
        let scale = min(limit.width / source.width, limit.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
    static func hand(_ asset: Shu25DAsset) -> UnitPoint {
        point(entries[asset.rawValue]?.hand, fallback: UnitPoint(x: 0.5, y: 0.9))
    }
    /// Distal joint in the same unmodified sprite canvas as `pivot`.
    /// The renderer maps both landmarks to the sampled skeleton, keeping the
    /// elbow/wrist and hip/ankle attachments aligned throughout every pose.
    static func end(_ asset: Shu25DAsset) -> UnitPoint {
        point(entries[asset.rawValue]?.end, fallback: UnitPoint(x: 0.5, y: 0.9))
    }
    static func emitter(_ asset: Shu25DAsset) -> UnitPoint {
        point(entries[asset.rawValue]?.emitter, fallback: UnitPoint(x: 0.9, y: 0.55))
    }
    static func contentBounds(_ asset: Shu25DAsset) -> CGRect {
        guard let values = entries[asset.rawValue]?.contentBounds, values.count == 4,
              values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
    private static func point(_ values: [Double]?, fallback: UnitPoint) -> UnitPoint {
        guard let values, values.count == 2, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return fallback }
        return UnitPoint(x: values[0], y: values[1])
    }
    static var hasPuppet: Bool {
        [.captainBase, .shortArm, .fingersFront, .legNear, .legFar]
            .allSatisfy { image($0) != nil }
    }
    static func pivot(_ asset: Shu25DAsset) -> UnitPoint {
        if let values = entries[asset.rawValue]?.pivot, values.count == 2, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            return UnitPoint(x: values[0], y: values[1])
        }
        switch asset {
        case .armNear, .armFar: return UnitPoint(x: 0.5, y: 0.12)
        case .hoe: return UnitPoint(x: 0.5, y: 0.35)
        case .wateringCan: return UnitPoint(x: 0.27, y: 0.3)
        default: return .center
        }
    }
    static func shoulder(_ asset: Shu25DAsset) -> CGPoint {
        if let values = entries[asset.rawValue]?.rigShoulder, values.count == 2, values.allSatisfy(\.isFinite) {
            return CGPoint(x: values[0], y: values[1])
        }
        return asset == .armFar ? CGPoint(x: 53, y: 128) : CGPoint(x: 128, y: 126)
    }
}

struct ShuSprite: View {
    let asset: Shu25DAsset
    var body: some View {
        Group {
            if let image = Shu25DAssets.image(asset) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }
        }.accessibilityHidden(true)
    }
    @ViewBuilder private var placeholder: some View {
        switch asset {
        case .armNear, .armFar, .shortArm, .upperArm, .forearm, .palmBack, .fingersFront, .legNear, .legFar:
            Capsule().fill(LinearGradient(colors: [ShuPalette.skin.opacity(0.8), ShuPalette.skin, ShuPalette.skin.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .hoe:
            GeometryReader { g in
                Capsule().fill(Color(red: 0.50, green: 0.34, blue: 0.20)).frame(width: 4).position(x: g.size.width / 2, y: g.size.height / 2)
                RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.48, green: 0.55, blue: 0.50).gradient)
                    .frame(width: g.size.width, height: 10).position(x: g.size.width / 2, y: g.size.height - 5)
            }
        case .wateringCan:
            GeometryReader { geometry in
                let color = Color(red: 0.35, green: 0.61, blue: 0.58)
                Ellipse().stroke(color, lineWidth: 3)
                    .frame(width: geometry.size.width * 0.38, height: geometry.size.height * 0.57)
                    .position(x: geometry.size.width * 0.22, y: geometry.size.height * 0.37)
                Path { path in
                    path.move(to: CGPoint(x: geometry.size.width * 0.58, y: geometry.size.height * 0.48))
                    path.addLine(to: CGPoint(x: geometry.size.width * 0.92, y: geometry.size.height * 0.24))
                }.stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                RoundedRectangle(cornerRadius: 5).fill(color.gradient)
                    .frame(width: geometry.size.width * 0.58, height: geometry.size.height * 0.67)
                    .position(x: geometry.size.width * 0.43, y: geometry.size.height * 0.62)
            }
        case .seedling:
            Image(systemName: "leaf.fill").resizable().scaledToFit().foregroundStyle(ShuPalette.leaf.gradient)
        case .rawPotato, .roastPotato:
            LegacyRoastPotatoView()
        case .firepit:
            ZStack {
                Capsule().fill(Color(red: 0.39, green: 0.26, blue: 0.17).gradient).frame(height: 10).rotationEffect(.degrees(15))
                Capsule().fill(Color(red: 0.48, green: 0.31, blue: 0.18).gradient).frame(height: 10).rotationEffect(.degrees(-16))
            }
        case .ground:
            Ellipse().fill(Color(red: 0.68, green: 0.77, blue: 0.47).gradient)
        case .captainBase, .captainHolding:
            LegacyCaptainShuIllustration()
        }
    }
}
