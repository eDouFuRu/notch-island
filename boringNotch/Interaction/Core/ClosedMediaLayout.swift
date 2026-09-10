import Foundation

/// One measurement for the closed media shell and its contents. The camera gap is
/// never enlarged to hold metadata; inline labels live in symmetric side wings.
struct ClosedMediaLayout: Equatable {
    let physicalGapWidth: CGFloat
    let height: CGFloat
    let artworkSize: CGFloat
    let metadataWidth: CGFloat
    let shellInset: CGFloat = 6
    let wingInset: CGFloat = 8
    let itemSpacing: CGFloat = 8
    static let spectrumSize = CGSize(width: 16, height: 14)

    init(notchWidth: CGFloat, height: CGFloat, inlineMetadata: Bool, maximumWidth: CGFloat = 640) {
        physicalGapWidth = max(0, notchWidth)
        self.height = max(24, height)
        // Reserve at least the spectrum's width, so the 16×14 view does not draw
        // outside a nominal 12×12 wing when the shell uses its 24-point minimum.
        artworkSize = min(24, max(Self.spectrumSize.width, self.height - 12))
        let availableLabel = (maximumWidth - physicalGapWidth - 12) / 2 - artworkSize - 16 - 8
        metadataWidth = inlineMetadata ? max(0, min(100, availableLabel)) : 0
    }

    var wingWidth: CGFloat { artworkSize + 2 * wingInset + (metadataWidth > 0 ? itemSpacing + metadataWidth : 0) }
    var contentWidth: CGFloat { physicalGapWidth + 2 * wingWidth }
    var shellWidth: CGFloat { contentWidth + 2 * shellInset }
    var artworkFrame: CGRect {
        CGRect(x: shellInset + wingInset, y: (height - artworkSize) / 2,
               width: artworkSize, height: artworkSize)
    }
    var spectrumFrame: CGRect {
        let centerX = shellWidth - shellInset - wingInset - artworkSize / 2
        return CGRect(x: centerX - Self.spectrumSize.width / 2, y: (height - Self.spectrumSize.height) / 2,
                      width: Self.spectrumSize.width, height: Self.spectrumSize.height)
    }
}
