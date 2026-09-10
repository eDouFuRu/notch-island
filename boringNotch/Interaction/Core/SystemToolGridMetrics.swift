// Custom changes for 工位充电岛: quick-tool grid geometry.
import CoreGraphics

/// Geometry shared by the quick-tool grid and the island height that has to contain it.
///
/// The page shows a whole number of rows and never a sliced one, so the scroll viewport is
/// pinned to an exact multiple of the row pitch instead of being left to absorb whatever
/// height the island happens to have. `ContentView` derives the island's expanded height
/// from `pageContentHeight`, so the two agree by construction — that is what stops a spare
/// half row reappearing whenever one of these numbers is tuned.
///
/// Lives in Core rather than beside the view so the carrier-window guard test can assert
/// against the same constants the layout actually uses.
public enum SystemToolGridMetrics {
    /// Painted and measured card height. Tiles report a smaller intrinsic size than they
    /// paint, so the grid pins every cell to this and the tiles paint at it.
    public static let cardHeight: CGFloat = 64
    public static let spacing: CGFloat = 8
    public static let visibleRows = 3

    /// Exactly `visibleRows` cards with gaps between them, and no trailing gap.
    public static var gridViewportHeight: CGFloat {
        CGFloat(visibleRows) * cardHeight + CGFloat(visibleRows - 1) * spacing
    }

    /// The page's header and status lines are pinned so the arithmetic stays exact;
    /// left intrinsic, their height drifts with font metrics and the total stops matching.
    public static let pageHeaderHeight: CGFloat = 18
    public static let pageFooterHeight: CGFloat = 14

    public static var pageContentHeight: CGFloat {
        pageHeaderHeight + spacing + gridViewportHeight + spacing + pageFooterHeight
    }

    /// `ContentView` adds this below the page when the island is open.
    public static let pageBottomPadding: CGFloat = 12

    /// Island height needed to show the page with no clipping and no spare row.
    public static func expandedHeight(headerHeight: CGFloat) -> CGFloat {
        headerHeight + pageContentHeight + pageBottomPadding
    }
}
