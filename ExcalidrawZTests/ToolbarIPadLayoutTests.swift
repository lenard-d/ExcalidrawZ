#if os(iOS)
import SwiftUI
import XCTest
@testable import ExcalidrawZ

final class ToolbarIPadLayoutTests: XCTestCase {
    func testNativeControlsStartAtTheExistingTopToolbarWidth() {
        XCTAssertFalse(usesNativeControls(width: 819))
        XCTAssertTrue(usesNativeControls(width: 820))
        XCTAssertTrue(usesNativeControls(width: 1194))
    }

    func testCompactIPadKeepsTheCompactControlsEvenInAWideContainer() {
        XCTAssertFalse(ExcalidrawToolbarLayoutPolicy.usesNativeIPadControls(
            isPad: true, horizontalSizeClass: .compact, containerWidth: 1194
        ))
    }

    func testPhoneAndUnmeasuredContainerDoNotHideWebControls() {
        XCTAssertFalse(ExcalidrawToolbarLayoutPolicy.usesNativeIPadControls(
            isPad: false, horizontalSizeClass: .regular, containerWidth: 1194
        ))
        XCTAssertFalse(usesNativeControls(width: 0))
    }

    func testCollaborationAndNoninteractiveCanvasesKeepWebControls() {
        XCTAssertFalse(ExcalidrawToolbarLayoutPolicy.usesNativeIPadControls(
            isPad: true, horizontalSizeClass: .regular, containerWidth: 1194,
            isNormalEditor: false
        ))
        XCTAssertFalse(ExcalidrawToolbarLayoutPolicy.usesNativeIPadControls(
            isPad: true, horizontalSizeClass: .regular, containerWidth: 1194,
            isInteractionEnabled: false
        ))
    }

    private func usesNativeControls(width: CGFloat) -> Bool {
        ExcalidrawToolbarLayoutPolicy.usesNativeIPadControls(
            isPad: true, horizontalSizeClass: .regular, containerWidth: width
        )
    }
}
#endif
