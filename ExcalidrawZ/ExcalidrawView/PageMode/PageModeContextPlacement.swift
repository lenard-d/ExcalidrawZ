import Foundation
import CoreGraphics

enum PageModeContextPlacement {
    /// Keeps controls at the visible frame header. Offscreen headers have no floating controls.
    static func origin(page: PageModePage, scroll: CGPoint, zoom: Double, viewport: CGRect, controls: CGSize) -> CGPoint? {
        guard let x = page.x, let y = page.y,
              [x, y, page.width, page.height, scroll.x, scroll.y, zoom,
               viewport.origin.x, viewport.origin.y, viewport.width, viewport.height,
               controls.width, controls.height].allSatisfy(\.isFinite),
              zoom > 0, page.width > 0, page.height > 0,
              controls.width > 0, controls.height > 0 else { return nil }
        let left = (x + scroll.x) * zoom
        let right = left + page.width * zoom
        let top = (y + scroll.y) * zoom
        guard viewport.height > controls.height + 8,
              right > viewport.minX, left < viewport.maxX,
              viewport.width >= controls.width + 16,
              top >= viewport.minY, top < viewport.maxY - controls.height - 8 else { return nil }
        let rowTop = top >= viewport.minY + controls.height + 16 ? top - controls.height - 8 : top + 8
        // Keep the touch area clear of the frame's 28-point corner handle.
        let headerRight = min(viewport.maxX - 8, right - 24)
        return CGPoint(x: max(viewport.minX + 8, headerRight - controls.width), y: rowTop)
    }
}
