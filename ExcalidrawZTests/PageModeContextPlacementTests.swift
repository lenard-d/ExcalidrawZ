import XCTest
@testable import ExcalidrawZ

final class PageModeContextPlacementTests: XCTestCase {
    private let controls = CGSize(width: 280, height: 44)
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testControlsFollowFrameHeaderThroughPanAndZoom() throws {
        let page = PageModePage(id: "page", title: "Notes", width: 595, height: 842, locked: false, x: 20, y: 200)
        let initial = try XCTUnwrap(PageModeContextPlacement.origin(page: page, scroll: .zero, zoom: 1, viewport: viewport, controls: controls))
        XCTAssertEqual(initial, CGPoint(x: 177.5, y: 148))
        let panned = try XCTUnwrap(PageModeContextPlacement.origin(page: page, scroll: CGPoint(x: 10, y: -50), zoom: 0.5, viewport: viewport, controls: controls))
        XCTAssertEqual(panned, CGPoint(x: 23.75, y: 23))
    }

    func testClippingStaysWithinVisibleHeaderAndOffscreenHeaderHidesControls() {
        let page = PageModePage(id: "page", title: "Notes", width: 595, height: 842, locked: false, x: 800, y: 200)
        XCTAssertEqual(PageModeContextPlacement.origin(page: page, scroll: .zero, zoom: 1, viewport: viewport, controls: controls), CGPoint(x: 712, y: 148))
        XCTAssertEqual(PageModeContextPlacement.origin(page: page, scroll: CGPoint(x: -800, y: -200), zoom: 1, viewport: viewport, controls: controls), CGPoint(x: 157.5, y: 8))
        XCTAssertNil(PageModeContextPlacement.origin(page: page, scroll: CGPoint(x: -800, y: 700), zoom: 1, viewport: viewport, controls: controls))
        XCTAssertEqual(PageModeContextPlacement.origin(page: page, scroll: CGPoint(x: -300, y: 0), zoom: 1, viewport: viewport, controls: controls), CGPoint(x: 610, y: 148))
    }

    func testInvalidCameraAndNarrowHeaderHaveNoDetachedControls() {
        let page = PageModePage(id: "page", title: "Notes", width: 595, height: 842, locked: false, x: 0, y: 200)
        for zoom in [Double.nan, .infinity, 0, -1] {
            XCTAssertNil(PageModeContextPlacement.origin(page: page, scroll: .zero, zoom: zoom, viewport: viewport, controls: controls))
        }
        XCTAssertEqual(PageModeContextPlacement.origin(page: page, scroll: .zero, zoom: 0.1, viewport: viewport, controls: controls), CGPoint(x: 8, y: 28))
        XCTAssertNil(PageModeContextPlacement.origin(page: page, scroll: CGPoint(x: 0, y: -201), zoom: 1, viewport: viewport, controls: controls))
    }

    func testNativeNavigationDoesNotCoverContextControls() throws {
        let visible = CGRect(x: 0, y: 86, width: 1076, height: 920)
        let page = PageModePage(id: "page", title: "Notes", width: 595, height: 842, locked: false, x: 200, y: 110)
        let origin = try XCTUnwrap(PageModeContextPlacement.origin(page: page, scroll: .zero,
            zoom: 1, viewport: visible, controls: controls))
        XCTAssertTrue(visible.contains(CGRect(origin: origin, size: controls)))
        XCTAssertEqual(origin.y, 118)
        XCTAssertNil(PageModeContextPlacement.origin(page: page, scroll: CGPoint(x: 0, y: -70),
            zoom: 1, viewport: visible, controls: controls))
    }

    func testClippedPageKeepsControlsInsideNativeSideInsets() throws {
        let visible = CGRect(x: 100, y: 86, width: 500, height: 700)
        let page = PageModePage(id: "page", title: "Notes", width: 595, height: 842, locked: false, x: 550, y: 110)
        let origin = try XCTUnwrap(PageModeContextPlacement.origin(page: page, scroll: .zero,
            zoom: 1, viewport: visible, controls: controls))
        XCTAssertTrue(visible.contains(CGRect(origin: origin, size: controls)))
        XCTAssertEqual(origin.x, 312)
    }
}
