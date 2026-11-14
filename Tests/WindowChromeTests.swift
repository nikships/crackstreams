import XCTest
@testable import Crackstreams

final class WindowChromeTests: XCTestCase {
    func testTrafficLightsHideWhenWindowIsUnhovered() {
        XCTAssertFalse(
            ChromeVisibility.showsTrafficLights(
                isFullScreen: false,
                isWindowHovered: false,
                isImmersive: false,
                isPointerIdle: false
            )
        )
        XCTAssertFalse(
            ChromeVisibility.showsTrafficLights(
                isFullScreen: false,
                isWindowHovered: false,
                isImmersive: true,
                isPointerIdle: false
            )
        )
    }

    func testTrafficLightsShowOnHoverAndAutoHideOnIdleInImmersiveMode() {
        XCTAssertTrue(
            ChromeVisibility.showsTrafficLights(
                isFullScreen: false,
                isWindowHovered: true,
                isImmersive: false,
                isPointerIdle: false
            )
        )
        XCTAssertTrue(
            ChromeVisibility.showsTrafficLights(
                isFullScreen: false,
                isWindowHovered: true,
                isImmersive: true,
                isPointerIdle: false
            )
        )
        XCTAssertFalse(
            ChromeVisibility.showsTrafficLights(
                isFullScreen: false,
                isWindowHovered: true,
                isImmersive: true,
                isPointerIdle: true
            )
        )
        // Launch screen stays usable while hovered even if pointer rests.
        XCTAssertTrue(
            ChromeVisibility.showsTrafficLights(
                isFullScreen: false,
                isWindowHovered: true,
                isImmersive: false,
                isPointerIdle: true
            )
        )
    }

    func testFullScreenAlwaysKeepsSystemTrafficLightsAvailable() {
        XCTAssertTrue(
            ChromeVisibility.showsTrafficLights(
                isFullScreen: true,
                isWindowHovered: false,
                isImmersive: true,
                isPointerIdle: true
            )
        )
    }

    func testAutoHideRequiresActivePlaybackAndNoSheet() {
        XCTAssertTrue(ChromeVisibility.canAutoHidePointer(isPlayingAny: true, isSheetPresented: false))
        XCTAssertFalse(ChromeVisibility.canAutoHidePointer(isPlayingAny: false, isSheetPresented: false))
        XCTAssertFalse(ChromeVisibility.canAutoHidePointer(isPlayingAny: true, isSheetPresented: true))
    }
}
