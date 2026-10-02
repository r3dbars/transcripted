// ParakeetMicrophoneSharingTests.swift
// A call app (Zoom, Meet, Teams) opening while dictation holds the mic through
// Apple voice processing. These suites drive the decisions ParakeetEngine and
// ParakeetDeviceRecovery consult; the AVAudioEngine wiring around them is in
// ParakeetMicrophoneSharingSourceContractTests.swift.

import Foundation

func testParakeetMicrophoneSharing() {
    func route(_ id: UInt32) -> ParakeetAudioRouteIdentity {
        let mic = DictationAudioDevice(id: id, name: "Mic \(id)", transport: .usb, inputChannelCount: 1, uid: "mic-\(id)")
        return ParakeetAudioRouteIdentity(selection: DictationInputDeviceSelection(
            defaultInput: mic, selectedInput: mic, defaultOutput: nil, reason: .defaultIsSafe
        ))
    }

    runSuite("Voice processing is asked for only while no call app is open, and the saved mode stays") {
        assertTrue(
            DictationVoiceProcessingRoutePolicy.isRequested(savedPreference: true, callAppRunning: false),
            "with no call app, the user's saved VPIO setting decides"
        )
        assertFalse(
            DictationVoiceProcessingRoutePolicy.isRequested(savedPreference: true, callAppRunning: true),
            "an open call app keeps dictation off VPIO so the call can still read the mic"
        )
        assertFalse(
            DictationVoiceProcessingRoutePolicy.isRequested(savedPreference: false, callAppRunning: false),
            "VPIO stays off when the user turned it off"
        )
        // The decision only reads the saved value: the same value that was
        // suppressed during a call turns VPIO back on once the call closes.
        let saved = true
        assertFalse(DictationVoiceProcessingRoutePolicy.isRequested(savedPreference: saved, callAppRunning: true))
        assertTrue(
            DictationVoiceProcessingRoutePolicy.isRequested(savedPreference: saved, callAppRunning: false),
            "VPIO comes back once the call app closes"
        )
    }

    runSuite("A call app launch downgrades only a live dictation on its own graph") {
        func mayDowngrade(
            callAppRunning: Bool = true,
            isRecording: Bool = true,
            borrowsMeetingMic: Bool = false,
            starting: Bool = false,
            stopping: Bool = false,
            shuttingDown: Bool = false
        ) -> Bool {
            ParakeetMicrophoneSharingPolicy.mayDowngrade(
                callAppRunning: callAppRunning,
                isRecording: isRecording,
                borrowsMeetingMic: borrowsMeetingMic,
                audioStartInProgress: starting,
                audioStopInProgress: stopping,
                isShuttingDown: shuttingDown
            )
        }
        assertTrue(mayDowngrade(), "a recording on dictation's own graph gives the mic back to the call")
        assertFalse(mayDowngrade(callAppRunning: false), "no call app, nothing to share")
        assertFalse(mayDowngrade(isRecording: false), "an idle engine is left alone")
        assertFalse(mayDowngrade(borrowsMeetingMic: true), "a dictation borrowing the meeting mic has no graph to downgrade")
        assertFalse(mayDowngrade(starting: true), "a start in progress owns the graph")
        assertFalse(mayDowngrade(stopping: true), "a stop in progress owns the graph")
        assertFalse(mayDowngrade(shuttingDown: true), "shutdown owns the graph")
    }

    runSuite("A call app downgrade skips our own suppression and always rebuilds") {
        let engine = NSObject()
        let stable = route(7)
        assertTrue(
            ParakeetSelfInducedConfigChangePolicy.shouldIgnore(
                source: .audioEngine, observedAt: 100.1,
                ignoreWindowUntil: 102.5, windowDuration: 2.5,
                stableRoute: stable, observedRoute: stable,
                bindingToken: nil, currentEngine: engine,
                forceForMicrophoneSharing: false
            ),
            "a normal same-route echo inside the restore window is ignored"
        )
        assertFalse(
            ParakeetSelfInducedConfigChangePolicy.shouldIgnore(
                source: .audioEngine, observedAt: 100.1,
                ignoreWindowUntil: 102.5, windowDuration: 2.5,
                stableRoute: stable, observedRoute: stable,
                bindingToken: nil, currentEngine: engine,
                forceForMicrophoneSharing: true
            ),
            "self-generated route suppression cannot postpone call app sharing"
        )

        assertTrue(
            ParakeetConfigChangeContinuityPolicy.shouldProbe(
                wasRecording: true, hadSampleFlow: true, inputWasReady: true,
                graphEndpointsMatch: true, forceForMicrophoneSharing: false
            ),
            "a healthy live graph normally gets a continuity probe"
        )
        assertFalse(
            ParakeetConfigChangeContinuityPolicy.shouldProbe(
                wasRecording: true, hadSampleFlow: true, inputWasReady: true,
                graphEndpointsMatch: true, forceForMicrophoneSharing: true
            ),
            "our healthy samples cannot suppress a call app sharing downgrade"
        )

        assertEqual(
            ParakeetConfigChangeGraphPolicy.strategy(
                source: .audioEngine, wasRecording: true, hadSampleFlow: true, inputWasReady: true,
                stableRouteIdentity: stable, observedRouteIdentity: stable,
                forceForMicrophoneSharing: false
            ),
            .reuseCurrentGraph,
            "an unchanged proven route normally reuses its graph"
        )
        assertEqual(
            ParakeetConfigChangeGraphPolicy.strategy(
                source: .audioEngine, wasRecording: true, hadSampleFlow: true, inputWasReady: true,
                stableRouteIdentity: stable, observedRouteIdentity: stable,
                forceForMicrophoneSharing: true
            ),
            .rebuildGraph,
            "a call app downgrade rebuilds even when the route endpoints stay the same"
        )
    }
}
