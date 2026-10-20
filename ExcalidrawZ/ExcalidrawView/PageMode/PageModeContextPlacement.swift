import Foundation

enum PageModeContextPlacement {
    /// Keeps controls at the visible frame header. Offscreen headers have no floating controls.
    static func origin(page: PageModePage, scroll: CGPoint, zoom: Double, viewport: CGSize, controls: CGSize) -> CGPoint? {
        guard let x = page.x, let y = page.y,
              [x, y, page.width, page.height, scroll.x, scroll.y, zoom,
               viewport.width, viewport.height, controls.width, controls.height].allSatisfy(\.isFinite),
              zoom > 0, page.width > 0, page.height > 0,
              controls.width > 0, controls.height > 0 else { return nil }
        let left = (x + scroll.x) * zoom
        let right = left + page.width * zoom
        let top = (y + scroll.y) * zoom
        guard right > 0, left < viewport.width,
              viewport.width >= controls.width + 16,
              top >= 0, top < viewport.height - controls.height - 8 else { return nil }
        let rowTop = top >= controls.height + 16 ? top - controls.height - 8 : top + 8
        let centered = (max(0, left) + min(viewport.width, right) - controls.width) / 2
        return CGPoint(x: min(max(8, centered), viewport.width - controls.width - 8), y: rowTop)
    }
}
