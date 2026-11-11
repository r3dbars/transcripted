import Foundation

func testParakeetRouteReporting() {
    let builtIn = ParakeetCategoricalAudioRoute(
        inputDeviceClass: "built_in", outputDeviceClass: "built_in", routeShape: "built_in_to_built_in"
    )
    let usb = ParakeetCategoricalAudioRoute(
        inputDeviceClass: "usb", outputDeviceClass: "built_in", routeShape: "usb_to_built_in"
    )
    let unknown = ParakeetCategoricalAudioRoute(
        inputDeviceClass: "unknown", outputDeviceClass: "unknown", routeShape: "unknown"
    )

    runSuite("Route reporting rejects an unknown lookup without replacing the stable route") {
        var state = ParakeetRouteTransitionDebounceState()
        state.seedStableRouteIfNeeded(builtIn)
        state.observe(unknown)
        assertFalse(state.observeReportableRoute(unknown, selectedInputID: 0), "the recovery sentinel is not a reportable device")
        assertEqual(state.pendingRoute, nil, "unknown must clear the mailbox's pending candidate")
        assertEqual(state.stableRoute, builtIn, "lookup failure must preserve the known baseline")
        assertEqual(state.commitPendingRoute(), nil, "unknown must not emit a categorical transition")
        assertTrue(state.observeReportableRoute(builtIn, selectedInputID: 17), "a later known input remains reportable")
        assertEqual(state.commitPendingRoute(), nil, "A -> unknown -> A must stay quiet")
    }

    runSuite("Route reporting does not establish a baseline from unknown") {
        var state = ParakeetRouteTransitionDebounceState()
        assertFalse(state.observeReportableRoute(unknown, selectedInputID: 0), "zero is not a device identity")
        assertEqual(state.stableRoute, nil, "unknown must leave initial discovery unresolved")
        assertEqual(state.pendingRoute, nil, "unknown must leave no candidate to commit")
        assertTrue(state.observeReportableRoute(usb, selectedInputID: 23), "a known input may establish the baseline")
        assertEqual(state.commitPendingRoute(), nil, "initial discovery is not a route change")
        assertEqual(state.stableRoute, usb, "the first known route becomes the baseline")
    }

    runSuite("Route reporting discards an older pending route when the latest lookup fails") {
        var state = ParakeetRouteTransitionDebounceState()
        state.seedStableRouteIfNeeded(builtIn)
        state.observe(usb)
        assertFalse(state.observeReportableRoute(unknown, selectedInputID: 0), "failed latest lookup cannot confirm the older candidate")
        assertEqual(state.pendingRoute, nil, "the older candidate must not survive failed confirmation")
        assertEqual(state.commitPendingRoute(), nil, "failed confirmation emits nothing")
        assertEqual(state.stableRoute, builtIn, "failed confirmation preserves the prior baseline")
        assertTrue(state.observeReportableRoute(usb, selectedInputID: 23), "later successful confirmation is accepted")
        assertEqual(state.commitPendingRoute(), usb, "a confirmed later route still emits its transition")
    }

    runSuite("Route reporting accepts known identities without duplicating categorical events") {
        var state = ParakeetRouteTransitionDebounceState()
        state.seedStableRouteIfNeeded(builtIn)
        assertTrue(state.observeReportableRoute(usb, selectedInputID: 23), "known route may refresh identity and cache")
        assertEqual(state.commitPendingRoute(), usb, "a new category emits once")
        assertEqual(state.commitPendingRoute(), nil, "a burst is consumed once")
        assertTrue(state.observeReportableRoute(usb, selectedInputID: 24), "another known device in the same category may refresh identity and cache")
        assertEqual(state.commitPendingRoute(), nil, "same-category device replacement is not a duplicate categorical event")
        assertTrue(state.observeReportableRoute(builtIn, selectedInputID: 17), "a known return route is accepted")
        assertEqual(state.commitPendingRoute(), builtIn, "returning from a confirmed USB route is a real transition")
    }
}
