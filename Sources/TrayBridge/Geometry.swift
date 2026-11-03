import Foundation
import CoreGraphics

enum ItemPlacement: String {
    case obscured
    case visible
    case unknown
}

/// A display's menu bar in Accessibility / Quartz coordinates (origin at top left).
struct MenuBarRegion {
    let displayBounds: CGRect
    let rightSafeStart: CGFloat?
    let applicationMenuEnd: CGFloat?
    let menuBarHeight: CGFloat
}

enum MenuBarGeometry {
    /// Geometry identifies items that may be obscured; it does not inspect pixels.
    /// Missing or invalid Accessibility geometry is deliberately kept as unknown.
    static func placement(of frame: CGRect?, regions: [MenuBarRegion]) -> ItemPlacement {
        guard let frame, isUsable(frame) else { return .unknown }
        let validRegions = regions.filter(isUsable)
        guard !validRegions.isEmpty else { return .unknown }

        // AX can report a menu extra a few points above/below the display top.
        // Require its complete height to fit the menu bar, so ordinary windows
        // farther down a screen never become "visible" menu extras.
        let verticalTolerance: CGFloat = 3
        let matchingRows = validRegions.filter { region in
            frame.minY >= region.displayBounds.minY - verticalTolerance &&
            frame.maxY <= region.displayBounds.minY + region.menuBarHeight + verticalTolerance &&
            frame.maxY > region.displayBounds.minY - verticalTolerance
        }
        guard !matchingRows.isEmpty else { return .unknown }

        let containingRegions = matchingRows.filter { region in
            frame.minX >= region.displayBounds.minX && frame.maxX <= region.displayBounds.maxX
        }
        // Includes negative/offscreen coordinates, and items crossing a display
        // edge. An icon must fit completely in one menu bar to be clickable.
        guard !containingRegions.isEmpty else { return .obscured }

        // Mirrored displays may share a rectangle. Prefer the conservative
        // result when their safe areas differ.
        for region in containingRegions {
            if let rightSafeStart = region.rightSafeStart {
                if frame.minX < rightSafeStart { return .obscured }
            } else if let applicationMenuEnd = region.applicationMenuEnd,
                      frame.minX < applicationMenuEnd {
                return .obscured
            }
        }
        return .visible
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.size.width.isFinite && rect.size.height.isFinite &&
        rect.size.width > 0 && rect.size.height > 0
    }

    private static func isUsable(_ region: MenuBarRegion) -> Bool {
        guard isUsable(region.displayBounds),
              region.menuBarHeight.isFinite,
              region.menuBarHeight > 0,
              region.menuBarHeight <= region.displayBounds.height else { return false }
        for boundary in [region.rightSafeStart, region.applicationMenuEnd].compactMap({ $0 }) {
            guard boundary.isFinite,
                  boundary >= region.displayBounds.minX,
                  boundary <= region.displayBounds.maxX else { return false }
        }
        return true
    }
}
