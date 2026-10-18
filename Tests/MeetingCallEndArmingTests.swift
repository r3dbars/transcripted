import Foundation

func testMeetingCallEndArming() {
    let zoom: Set<String> = ["us.zoom.xos"]
    let chrome: Set<String> = ["com.google.Chrome"]
    let identity = UUID()

    func families(_ snapshot: MeetingCallActivitySnapshot, at time: TimeInterval,
                  detectedPrompt: Bool = true, cameraOnly: Bool = false) -> Set<String>? {
        MeetingCallEndArming.lateBindingFamilies(
            isRecording: true, isArmed: false,
            pendingIdentity: detectedPrompt ? identity : nil, activeIdentity: identity,
            inputUsers: snapshot.inputUsers,
            families: snapshot.sourceFamilies(detectedPrompt: detectedPrompt, provider: .zoom,
                isBrowserCall: false, cameraOnly: cameraOnly, sampledAt: time, now: time))
    }
    let joined = MeetingCallActivitySnapshot(inputUsers: zoom, outputUsers: [], isReliable: true)
    let ended = MeetingCallActivitySnapshot(inputUsers: [], outputUsers: [], isReliable: true)
    let notification = MeetingCallActivitySnapshot(inputUsers: [], outputUsers: zoom, isReliable: true)

    runSuite("Call-end arming — accepting before joining eventually warns after the actual call ends") {
        var arming = MeetingCallEndArming()
        assertNil(arming.confirm(families: families(ended, at: 0), sampledAt: 0, now: 0))
        for time in [100.0, 105] {
            assertNil(arming.confirm(families: families(joined, at: time), sampledAt: time, now: time))
        }
        let bound = arming.confirm(families: families(joined, at: 110), sampledAt: 110, now: 110)
        assertEqual(bound, zoom, "joining after accepting must eventually arm the end prompt")
        guard let bound else { return }
        var tracking = MeetingCallEndTracking(recordingIdentity: identity, families: bound)
        for time in [115.0, 120, 125] {
            assertEqual(tracking.policy.observe(joined.activity(in: bound, cameraInUse: false),
                sampledAt: time, at: time), .none, "a silent call retaining its stream is still active")
        }
        assertEqual(tracking.policy.observe(ended.activity(in: bound, cameraInUse: false),
            sampledAt: 130, at: 130), .none)
        assertEqual(tracking.policy.observe(ended.activity(in: bound, cameraInUse: false),
            sampledAt: 140, at: 140), .warningStarted)
        for time in [150.0, 160, 170] { _ = tracking.policy.observe(.inactive, sampledAt: time, at: time) }
        assertTrue(tracking.canStop(currentIdentity: identity, warningIdentity: identity, activity: .inactive, at: 170))
    }

    runSuite("Call-end arming — a brief notification cannot arm a recording before the call starts") {
        var arming = MeetingCallEndArming()
        for time in [0.0, 5] {
            assertNil(arming.confirm(families: families(notification, at: time), sampledAt: time, now: time))
        }
        assertNil(arming.confirm(families: families(ended, at: 10), sampledAt: 10, now: 10))
        assertNil(arming.confirm(families: families(joined, at: 15), sampledAt: 15, now: 15),
                  "the later real call cannot inherit time from the notification")
        assertNil(arming.confirm(families: zoom, sampledAt: 20, now: 20))
        assertEqual(arming.confirm(families: zoom, sampledAt: 25, now: 25), zoom)
    }

    runSuite("Call-end arming — sustained output alone never confirms a call") {
        var arming = MeetingCallEndArming()
        for time in [0.0, 5, 10, 15, 20, 25, 30] {
            assertNil(arming.confirm(families: families(notification, at: time), sampledAt: time, now: time),
                      "playback alone is not evidence that a call joined")
        }
    }

    runSuite("Call-end arming — brief microphone ownership and output interrupt confirmation") {
        var arming = MeetingCallEndArming()
        for time in [0.0, 5] {
            assertNil(arming.confirm(families: families(joined, at: time), sampledAt: time, now: time))
        }
        assertNil(arming.confirm(families: families(notification, at: 10), sampledAt: 10, now: 10))
        for time in [15.0, 20] {
            assertNil(arming.confirm(families: families(joined, at: time), sampledAt: time, now: time),
                      "input must earn a fresh interval after output-only activity")
        }
        assertEqual(arming.confirm(families: families(joined, at: 25), sampledAt: 25, now: 25), zoom)
    }

    runSuite("Call-end arming — quiet microphone ownership qualifies and output preserves an armed call") {
        var arming = MeetingCallEndArming()
        // Ownership, not audio amplitude: a muted app retaining its input stream qualifies.
        for time in [0.0, 5] {
            assertNil(arming.confirm(families: families(joined, at: time), sampledAt: time, now: time))
        }
        let bound = arming.confirm(families: families(joined, at: 10), sampledAt: 10, now: 10)
        assertEqual(bound, zoom)
        guard let bound else { return }
        var tracking = MeetingCallEndTracking(recordingIdentity: identity, families: bound)
        for time in [15.0, 20, 25, 30] {
            assertEqual(tracking.policy.observe(notification.activity(in: bound, cameraInUse: false),
                                               sampledAt: time, at: time), .none,
                        "losing the mic while retaining output must not warn after arming")
        }
    }

    runSuite("Call-end arming — microphone ownership must belong to the selected source family") {
        let otherMic = MeetingCallActivitySnapshot(inputUsers: chrome, outputUsers: zoom, isReliable: true)
        assertNil(families(otherMic, at: 0), "another app's microphone cannot qualify call-app playback")
        let helperMic = MeetingCallActivitySnapshot(inputUsers: ["us.zoom.xos.helper"], outputUsers: [], isReliable: true)
        assertEqual(families(helperMic, at: 0), zoom, "dotted helpers belong to the source family")
        let lookalike = MeetingCallActivitySnapshot(inputUsers: ["us.zoom.xosOther"], outputUsers: zoom, isReliable: true)
        assertNil(families(lookalike, at: 0), "a shared string prefix is not a bundle-family match")
    }

    runSuite("Call-end arming — manual recordings and camera-only prompts remain unarmed") {
        for (detectedPrompt, cameraOnly) in [(false, false), (true, true)] {
            var arming = MeetingCallEndArming()
            for time in [0.0, 5, 10, 15] {
                let eligible = families(joined, at: time, detectedPrompt: detectedPrompt, cameraOnly: cameraOnly)
                assertNil(arming.confirm(families: eligible, sampledAt: time, now: time))
            }
        }
    }

    runSuite("Call-end arming — missing evidence and changed source families restart confirmation") {
        for interruption in [nil, Set<String>(), chrome] as [Set<String>?] {
            var arming = MeetingCallEndArming()
            _ = arming.confirm(families: zoom, sampledAt: 0, now: 0)
            assertNil(arming.confirm(families: interruption, sampledAt: 5, now: 5))
            assertNil(arming.confirm(families: zoom, sampledAt: 10, now: 10))
            assertNil(arming.confirm(families: zoom, sampledAt: 15, now: 15))
            assertEqual(arming.confirm(families: zoom, sampledAt: 20, now: 20), zoom)
        }
    }

    runSuite("Call-end arming — stale future duplicate and missing samples earn no elapsed activity") {
        for sample in [nil, -20, 20] as [TimeInterval?] {
            var arming = MeetingCallEndArming()
            _ = arming.confirm(families: zoom, sampledAt: 0, now: 0)
            assertNil(arming.confirm(families: zoom, sampledAt: sample, now: 5))
            assertNil(arming.confirm(families: zoom, sampledAt: 10, now: 10))
        }
        var arming = MeetingCallEndArming()
        _ = arming.confirm(families: zoom, sampledAt: 0, now: 0)
        assertNil(arming.confirm(families: zoom, sampledAt: 0, now: 10))
        assertNil(arming.confirm(families: zoom, sampledAt: -1, now: 10))
        assertNil(arming.confirm(families: zoom, sampledAt: 20, now: 20), "a monitoring gap restarts the interval")
        assertNil(arming.confirm(families: zoom, sampledAt: 25, now: 25))
        assertEqual(arming.confirm(families: zoom, sampledAt: 30, now: 30), zoom)
    }
}
