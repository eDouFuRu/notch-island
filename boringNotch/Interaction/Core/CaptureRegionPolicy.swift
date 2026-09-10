import Foundation

/// Converts one screen's AppKit selection into screencapture's global,
/// top-left coordinate space. Selections never cross into another display.
struct CaptureRegion: Equatable, Sendable {
    let rect: CGRect

    var argument: String {
        [rect.minX, rect.minY, rect.width, rect.height].map { String(Int($0)) }.joined(separator: ",")
    }
}

enum CaptureRegionPolicy {
    static let minimumSide: CGFloat = 16

    static func region(from localSelection: CGRect, appKitScreen: CGRect,
                       quartzScreen: CGRect) -> CaptureRegion? {
        guard !localSelection.isInfinite, !localSelection.isNull,
              [localSelection.minX, localSelection.minY, localSelection.width, localSelection.height,
               appKitScreen.width, appKitScreen.height, quartzScreen.minX, quartzScreen.minY,
               quartzScreen.width, quartzScreen.height].allSatisfy(\.isFinite),
              appKitScreen.width > 0, appKitScreen.height > 0,
              quartzScreen.width > 0, quartzScreen.height > 0 else { return nil }
        let bounded = localSelection.standardized.intersection(CGRect(origin: .zero, size: appKitScreen.size))
        guard !bounded.isNull, bounded.width >= minimumSide, bounded.height >= minimumSide else { return nil }
        let xScale = quartzScreen.width / appKitScreen.width
        let yScale = quartzScreen.height / appKitScreen.height
        let rect = CGRect(x: quartzScreen.minX + bounded.minX * xScale,
                          y: quartzScreen.minY + (appKitScreen.height - bounded.maxY) * yScale,
                          width: bounded.width * xScale, height: bounded.height * yScale).integral
            .intersection(quartzScreen)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        return CaptureRegion(rect: rect)
    }
}
