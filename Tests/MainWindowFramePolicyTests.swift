import Foundation

func testMainWindowFramePolicy() {
    let builtIn = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let size = CGSize(width: 980, height: 760)
    let centeredOnBuiltIn = CGRect(x: 230, y: 70, width: 980, height: 760)

    func placed(
        saved: CGRect?,
        on screens: [CGRect] = [builtIn],
        preferred: CGRect? = nil
    ) -> CGRect {
        MainWindowFramePolicy.frame(
            savedFrame: saved,
            windowSize: size,
            visibleFrames: screens,
            preferredVisibleFrame: preferred ?? screens[0]
        )
    }

    runSuite("First launch with no saved frame centers on the preferred screen") {
        assertEqual(
            placed(saved: nil),
            centeredOnBuiltIn,
            "no autosave means center on the mouse or main display, not the constructor origin"
        )
        let laptop = CGRect(x: 1920, y: 0, width: 1440, height: 900)
        assertEqual(
            placed(saved: nil, on: [laptop], preferred: laptop),
            CGRect(x: 2150, y: 70, width: 980, height: 760),
            "centering uses the preferred screen's origin, not global (0, 0)"
        )
    }

    runSuite("An offscreen saved frame is recentered on the preferred screen") {
        let offscreen = CGRect(x: 8000, y: -4000, width: 980, height: 760)
        assertEqual(
            placed(saved: offscreen),
            centeredOnBuiltIn,
            "a frame that misses every connected screen must not stay in a corner off-canvas"
        )
    }

    runSuite("A saved frame on a now-missing second display moves onto the main display") {
        let onExternal = CGRect(x: 1680, y: 160, width: 980, height: 760)
        assertEqual(
            placed(saved: onExternal, on: [builtIn, external], preferred: builtIn),
            onExternal,
            "the same frame is kept while that display is still connected"
        )
        assertEqual(
            placed(saved: onExternal, on: [builtIn], preferred: builtIn),
            centeredOnBuiltIn,
            "unplugging the display it lived on moves it onto the remaining screen"
        )
    }

    runSuite("A saved frame that still sits on a connected screen is kept") {
        let whereTheUserLeftIt = CGRect(x: 120, y: 80, width: 1100, height: 800)
        assertEqual(
            placed(saved: whereTheUserLeftIt, on: [builtIn, external], preferred: builtIn),
            whereTheUserLeftIt,
            "a usable saved frame is the user's last position, including size"
        )
        let bottomRight = CGRect(x: 460, y: 0, width: 980, height: 760)
        assertEqual(
            placed(saved: bottomRight),
            bottomRight,
            "bottom-right is kept when that is where the user put it, not when it is a first-launch default"
        )
    }
}
