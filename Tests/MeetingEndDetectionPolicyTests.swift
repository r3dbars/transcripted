import Foundation

func testMeetingEndDetectionPolicy() {
    runSuite("Meeting end detection — camera read failures veto ending while input activity stays authoritative") {
        let ended = MeetingCallActivitySnapshot(inputUsers: [], outputUsers: [], isReliable: true)
        assertEqual(MeetingCallActivitySnapshot.cameraInUse(readings: nil), nil)
        assertEqual(MeetingCallActivitySnapshot.cameraInUse(readings: [false, nil]), nil)
        assertEqual(MeetingCallActivitySnapshot.cameraInUse(readings: []), false)
        assertEqual(MeetingCallActivitySnapshot.cameraInUse(readings: [true, nil]), true)
        assertEqual(ended.activity(in: ["us.zoom.xos"], cameraInUse: nil), .unknown)
        let active = MeetingCallActivitySnapshot(inputUsers: ["us.zoom.xos"], outputUsers: [], isReliable: true)
        assertEqual(active.activity(in: ["us.zoom.xos"], cameraInUse: nil), .active)
    }
    runSuite("Meeting end detection — source resumes while audio stays silent restores silence fallback") {
        var detector = MeetingAudioInactivityDetector()
        _ = detector.startRecording()
        _ = detector.tick(at: 300)
        let silence = detector.warning
        let ended = MeetingAudioInactivityWarning(inactiveDuration: 10, countdownSeconds: 30, kind: .callEnded)
        assertEqual(MeetingRecordingWarningOwner.displayed(callEnd: ended, silence: silence), ended)
        assertEqual(MeetingRecordingWarningOwner.displayed(callEnd: nil, silence: detector.warning), silence)
        assertTrue(silence != nil, "the silence fallback must still be available after temporary source loss")
    }
    runSuite("Meeting end detection — room speech clears only the hidden silence warning") {
        var detector = MeetingAudioInactivityDetector()
        _ = detector.startRecording()
        _ = detector.tick(at: 300)
        let ended = MeetingAudioInactivityWarning(inactiveDuration: 10, countdownSeconds: 30, kind: .callEnded)
        _ = detector.observe(micLevel: 1, systemLevel: 0, at: 310)
        assertEqual(MeetingRecordingWarningOwner.displayed(callEnd: ended, silence: detector.warning), ended)
        assertEqual(MeetingRecordingWarningOwner.displayed(callEnd: nil, silence: detector.warning), nil)
    }
    runSuite("Meeting end detection — Keep recording does not resurrect a hidden silence warning") {
        var detector = MeetingAudioInactivityDetector()
        _ = detector.startRecording()
        _ = detector.tick(at: 300)
        _ = detector.dismissWarning()
        assertEqual(MeetingRecordingWarningOwner.displayed(callEnd: nil, silence: detector.warning), nil)
        assertEqual(detector.tick(at: 1_000), .none, "dismissed silence stays snoozed until actual audio resumes")
    }
    let zoom: Set<String> = ["us.zoom.xos"]
    let chrome: Set<String> = ["com.google.Chrome"]

    runSuite("Meeting end detection binding — manual recordings and camera-only prompts never arm") {
        let native = MeetingCallActivitySnapshot(inputUsers: ["us.zoom.xos"], outputUsers: [], isReliable: true)
        assertNil(native.sourceFamilies(detectedPrompt: false, provider: .zoom, isBrowserCall: false,
                                        cameraOnly: false, sampledAt: 100, now: 100),
                  "starting manually never opts a recording into end detection")
        assertNil(native.sourceFamilies(detectedPrompt: true, provider: .zoom, isBrowserCall: false,
                                        cameraOnly: true, sampledAt: 100, now: 100),
                  "a camera-only prompt cannot identify which app owns the meeting")
    }

    runSuite("Meeting end detection binding — missing activity and unknown or stale observations cannot arm") {
        let native = MeetingCallActivitySnapshot(inputUsers: ["us.zoom.xos"], outputUsers: [], isReliable: true)
        for sample in [nil, 87.9, 101.0] as [TimeInterval?] {
            assertNil(native.sourceFamilies(detectedPrompt: true, provider: .zoom, isBrowserCall: false,
                                            cameraOnly: false, sampledAt: sample, now: 100),
                      "missing, stale, or future sample times cannot identify a current call")
        }
        assertEqual(native.sourceFamilies(detectedPrompt: true, provider: .zoom, isBrowserCall: false,
                                          cameraOnly: false, sampledAt: 88, now: 100), zoom,
                    "a sample exactly at the freshness boundary can bind")
        for snapshot in [MeetingCallActivitySnapshot.unknown,
                         MeetingCallActivitySnapshot(inputUsers: [], outputUsers: [], isReliable: true)] {
            assertNil(snapshot.sourceFamilies(detectedPrompt: true, provider: .zoom, isBrowserCall: false,
                                              cameraOnly: false, sampledAt: 100, now: 100),
                      "an unknown read or no app activity does not identify the recording source")
        }
    }

    runSuite("Meeting end detection binding — a named browser Zoom call binds its browser rather than native Zoom") {
        let snapshot = MeetingCallActivitySnapshot(
            inputUsers: ["com.google.Chrome.helper.renderer", "us.zoom.xos"], outputUsers: [], isReliable: true
        )
        assertEqual(snapshot.sourceFamilies(detectedPrompt: true, provider: .zoom, isBrowserCall: true,
                                            cameraOnly: false, sampledAt: 100, now: 100), chrome,
                    "the provider name must not bind a web call to the native app")
        let helpers = MeetingCallActivitySnapshot(
            inputUsers: ["com.google.Chrome.helper", "com.google.Chrome.helper.renderer"], outputUsers: [], isReliable: true
        )
        assertEqual(helpers.sourceFamilies(detectedPrompt: true, provider: .googleMeet, isBrowserCall: true,
                                           cameraOnly: false, sampledAt: 100, now: 100), chrome,
                    "multiple helper processes in the same browser still identify one source family")
    }

    runSuite("Meeting end detection binding — simultaneous browser families are ambiguous and cannot arm") {
        let snapshot = MeetingCallActivitySnapshot(
            inputUsers: ["com.google.Chrome.helper", "com.apple.WebKit.GPU"], outputUsers: [], isReliable: true
        )
        assertNil(snapshot.sourceFamilies(detectedPrompt: true, provider: .googleMeet, isBrowserCall: true,
                                          cameraOnly: false, sampledAt: 100, now: 100),
                  "a provider label alone cannot choose among two active browsers")
        let unrelated = MeetingCallActivitySnapshot(
            inputUsers: ["us.zoom.xos"], outputUsers: ["com.google.Chrome.helper"], isReliable: true
        )
        assertNil(unrelated.sourceFamilies(detectedPrompt: true, provider: .googleMeet, isBrowserCall: true,
                                           cameraOnly: false, sampledAt: 100, now: 100),
                  "browser playback alone cannot identify which browser owns the detected microphone call")
    }

    runSuite("Meeting end detection binding — native output-only activity binds a muted native meeting") {
        let snapshot = MeetingCallActivitySnapshot(inputUsers: [], outputUsers: ["us.zoom.xos"], isReliable: true)
        assertEqual(snapshot.sourceFamilies(detectedPrompt: true, provider: .zoom, isBrowserCall: false,
                                            cameraOnly: false, sampledAt: 100, now: 100), zoom,
                    "a muted native call can be bound from its output activity")
    }

    runSuite("Meeting end detection binding — Safari and WebKit belong to one jointly tracked browser") {
        let userSets: [Set<String>] = [["com.apple.Safari"], ["com.apple.WebKit.GPU"],
                                      ["com.apple.Safari", "com.apple.WebKit.GPU"]]
        for users in userSets {
            let snapshot = MeetingCallActivitySnapshot(inputUsers: users, outputUsers: [], isReliable: true)
            assertEqual(snapshot.sourceFamilies(detectedPrompt: true, provider: .googleMeet, isBrowserCall: true,
                                                cameraOnly: false, sampledAt: 100, now: 100),
                        ["com.apple.Safari", "com.apple.WebKit"],
                        "Safari and its WebKit helper must normalize to a single browser source")
        }
    }

    runSuite("Meeting end detection tracking — another browser cannot replace the recording's frozen source family") {
        let identity = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var tracking = MeetingCallEndTracking(recordingIdentity: identity, families: chrome)
        let safari = MeetingCallActivitySnapshot(inputUsers: ["com.apple.WebKit.GPU"], outputUsers: [], isReliable: true)
        let safariActivity = safari.activity(in: tracking.families, cameraInUse: false)
        assertTrue(safariActivity == .inactive, "a different browser's call does not sustain the recorded Chrome meeting")
        _ = tracking.policy.observe(safariActivity, sampledAt: 100, at: 100)
        assertEqual(tracking.policy.observe(safariActivity, sampledAt: 110, at: 110), .warningStarted,
                    "the bound browser ending still warns when another browser is active")
        assertEqual(tracking.families, chrome, "later snapshots do not retarget the recording")
    }

    runSuite("Meeting end detection tracking — only the matching recording and warning may stop on timeout") {
        let identity = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var tracking = MeetingCallEndTracking(recordingIdentity: identity, families: zoom)
        for time in [100.0, 110, 120, 130] { _ = tracking.policy.observe(.inactive, sampledAt: time, at: time) }
        assertFalse(tracking.canStop(currentIdentity: identity, warningIdentity: identity, activity: .inactive, at: 140),
                    "a reading sampled before the deadline cannot authorize the expired warning")
        _ = tracking.policy.observe(.inactive, sampledAt: 140, at: 140)
        assertTrue(tracking.canStop(currentIdentity: identity, warningIdentity: identity, activity: .inactive, at: 140),
                   "matching identities and post-deadline inactivity authorize the expired warning")
        for current in [nil, other, identity] as [UUID?] {
            for warning in [nil, other, identity] as [UUID?] where current != identity || warning != identity {
                assertFalse(tracking.canStop(currentIdentity: current, warningIdentity: warning, activity: .inactive, at: 140),
                            "a missing or replaced recording or warning cannot be stopped by an old timer")
            }
        }
        assertFalse(tracking.canStop(currentIdentity: identity, warningIdentity: identity, activity: .inactive, at: 139),
                    "matching identities still require the deadline")
        assertFalse(tracking.canStop(currentIdentity: identity, warningIdentity: identity, activity: .inactive, at: 153),
                    "matching identities still require fresh evidence")
    }

    runSuite("Meeting end detection tracking — active or unknown current evidence vetoes an expired warning") {
        let identity = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var tracking = MeetingCallEndTracking(recordingIdentity: identity, families: zoom)
        for time in [100.0, 110, 120, 130, 140] { _ = tracking.policy.observe(.inactive, sampledAt: time, at: time) }
        for activity in [MeetingEndDetectionPolicy.Activity.active, .unknown] {
            assertFalse(tracking.canStop(currentIdentity: identity, warningIdentity: identity, activity: activity, at: 140),
                        "current activity or a failed read vetoes timeout even before the next policy update")
        }
        assertTrue(tracking.canStop(currentIdentity: identity, warningIdentity: identity, activity: .inactive, at: 140),
                   "the same post-deadline evidence does stop while the call stays inactive")
    }

    struct ProcessProbe {
        let id: String?
        let input: Bool?
        let output: Bool?
    }
    func read(_ objects: [ProcessProbe]?) -> MeetingCallActivitySnapshot {
        MeetingCallActivitySnapshot.read(
            objects: objects, ownBundleID: "app.transcripted",
            bundleID: { $0.id }, input: { $0.input }, output: { $0.output }
        )
    }

    runSuite("Meeting end detection reads — missing process inventory is unknown while an empty inventory is reliable") {
        assertEqual(read(nil), .unknown, "a failed process-list read cannot establish that the call ended")
        let empty = read([])
        assertTrue(empty.isReliable, "a successful empty inventory is a reliable observation")
        assertTrue(empty.inputUsers.isEmpty && empty.outputUsers.isEmpty, "the successful inventory has no users")
        assertTrue(empty.activity(in: zoom, cameraInUse: false) == .inactive,
                   "empty inventory can begin an inactivity interval")
    }

    runSuite("Meeting end detection reads — failed identity or direction reads cannot establish inactivity") {
        for object in [
            ProcessProbe(id: nil, input: false, output: false),
            ProcessProbe(id: "us.zoom.xos", input: nil, output: false),
            ProcessProbe(id: "us.zoom.xos", input: false, output: nil),
        ] {
            let snapshot = read([object])
            assertFalse(snapshot.isReliable, "each failed required probe makes the inventory unreliable")
            assertTrue(snapshot.activity(in: zoom, cameraInUse: false) == .unknown,
                       "failure must never look like a released microphone or output")
        }
        let mixed = read([
            ProcessProbe(id: "us.zoom.xos", input: true, output: false),
            ProcessProbe(id: "com.google.Chrome.helper", input: false, output: nil),
        ])
        assertTrue(mixed.activity(in: zoom, cameraInUse: false) == .unknown,
                   "one readable process cannot disguise an incomplete overall observation")
    }

    runSuite("Meeting end detection reads — Transcripted and its helper family never keep their own recording alive") {
        let snapshot = read([
            ProcessProbe(id: "app.transcripted", input: true, output: true),
            ProcessProbe(id: "app.transcripted.helper", input: true, output: true),
        ])
        assertTrue(snapshot.isReliable, "excluded self processes do not invalidate the observation")
        assertTrue(snapshot.inputUsers.isEmpty && snapshot.outputUsers.isEmpty,
                   "self capture must be excluded from both directions")
        assertTrue(snapshot.activity(in: zoom, cameraInUse: false) == .inactive,
                   "Transcripted's recording activity cannot sustain the ended Zoom call")
    }

    runSuite("Meeting end detection reads — unrelated media apps are excluded without probing their audio") {
        var inputReads = 0
        var outputReads = 0
        let snapshot = MeetingCallActivitySnapshot.read(
            objects: ["com.spotify.client", "com.apple.Music"], ownBundleID: "app.transcripted",
            bundleID: { $0 },
            input: { _ in inputReads += 1; return nil },
            output: { _ in outputReads += 1; return nil }
        )
        assertEqual(inputReads, 0, "non-call apps do not require input sensor reads")
        assertEqual(outputReads, 0, "non-call apps do not require output sensor reads")
        assertTrue(snapshot.isReliable, "a non-call app's unavailable sensors do not invalidate call evidence")
        assertTrue(snapshot.inputUsers.isEmpty && snapshot.outputUsers.isEmpty,
                   "unrelated music does not become call activity")
    }

    runSuite("Meeting end detection reads — a muted browser's raw output remains visible without microphone activity") {
        let snapshot = read([
            ProcessProbe(id: "com.google.Chrome.helper.renderer", input: false, output: true),
        ])
        assertTrue(snapshot.isReliable, "successful raw input and output reads are reliable")
        assertTrue(snapshot.inputUsers.isEmpty, "muted browser input is absent")
        assertEqual(snapshot.outputUsers, ["com.google.Chrome.helper.renderer"],
                    "output must be collected even when the browser does not hold its microphone")
        assertTrue(snapshot.activity(in: chrome, cameraInUse: false) == .active,
                   "remote speakers keep the muted browser meeting active")
    }

    runSuite("Meeting end detection — the bound app using its microphone keeps the meeting active") {
        let snapshot = MeetingCallActivitySnapshot(
            inputUsers: ["us.zoom.xos"], outputUsers: [], isReliable: true
        )
        assertTrue(snapshot.activity(in: zoom, cameraInUse: false) == .active,
                   "a bound app holding its mic is active even when nobody is speaking")
    }

    runSuite("Meeting end detection — output from the bound app keeps a muted meeting active") {
        let snapshot = MeetingCallActivitySnapshot(
            inputUsers: [], outputUsers: ["us.zoom.xos"], isReliable: true
        )
        assertTrue(snapshot.activity(in: zoom, cameraInUse: false) == .active,
                   "muting the microphone must not end a call that still uses output")
    }

    runSuite("Meeting end detection — browser helpers sustain their bound browser family") {
        for snapshot in [
            MeetingCallActivitySnapshot(inputUsers: ["com.google.Chrome.helper"], outputUsers: [], isReliable: true),
            MeetingCallActivitySnapshot(inputUsers: [], outputUsers: ["com.google.Chrome.helper.renderer"], isReliable: true),
        ] {
            assertTrue(snapshot.activity(in: chrome, cameraInUse: false) == .active,
                       "a browser helper is evidence for the browser that owns the recording")
        }
        let safari = MeetingCallActivitySnapshot(
            inputUsers: [], outputUsers: ["com.apple.WebKit.GPU"], isReliable: true
        )
        assertTrue(safari.activity(in: ["com.apple.Safari", "com.apple.WebKit"], cameraInUse: false) == .active,
                   "Safari's WebKit audio helper must keep a Safari meeting alive")
    }

    runSuite("Meeting end detection — unrelated sound and microphone users cannot sustain the bound app") {
        let snapshot = MeetingCallActivitySnapshot(
            inputUsers: ["com.apple.VoiceMemos"],
            outputUsers: ["com.spotify.client", "com.google.Chrome.helper"],
            isReliable: true
        )
        assertTrue(snapshot.activity(in: zoom, cameraInUse: false) == .inactive,
                   "music and another app's microphone use say nothing about the Zoom call")
        let lookalike = MeetingCallActivitySnapshot(
            inputUsers: ["us.zoom.xosOtherApp"], outputUsers: [], isReliable: true
        )
        assertTrue(lookalike.activity(in: zoom, cameraInUse: false) == .inactive,
                   "a shared string prefix is not membership in the bound app's family")
    }

    runSuite("Meeting end detection — a reliable empty read differs from an unknown read") {
        let empty = MeetingCallActivitySnapshot(inputUsers: [], outputUsers: [], isReliable: true)
        assertTrue(empty.activity(in: zoom, cameraInUse: false) == .inactive,
                   "a successful process read with no users supplies inactivity evidence")
        assertTrue(MeetingCallActivitySnapshot.unknown.activity(in: zoom, cameraInUse: false) == .unknown,
                   "a failed read supplies no evidence that a call ended")
        let unreliable = MeetingCallActivitySnapshot(
            inputUsers: ["us.zoom.xos"], outputUsers: ["us.zoom.xos"], isReliable: false
        )
        assertTrue(unreliable.activity(in: zoom, cameraInUse: false) == .unknown,
                   "partial results cannot become reliable activity evidence")
    }

    runSuite("Meeting end detection — camera use conservatively keeps a meeting active") {
        let empty = MeetingCallActivitySnapshot(inputUsers: [], outputUsers: [], isReliable: true)
        assertTrue(empty.activity(in: zoom, cameraInUse: true) == .active,
                   "camera use can prevent stopping a muted call")
        assertTrue(MeetingCallActivitySnapshot.unknown.activity(in: zoom, cameraInUse: true) == .unknown,
                   "a camera signal must not disguise a failed process read")
    }

    runSuite("Meeting end detection — ten uninterrupted inactive seconds open a warning") {
        var policy = MeetingEndDetectionPolicy()
        assertEqual(policy.observe(.inactive, sampledAt: 100, at: 100), .none, "the first absent sample starts observation")
        assertEqual(policy.observe(.inactive, sampledAt: 109.9, at: 109.9), .none, "brief inactivity must not show the warning")
        assertEqual(policy.observe(.inactive, sampledAt: 110, at: 110), .warningStarted, "the warning opens at ten seconds")
        assertEqual(policy.observe(.inactive, sampledAt: 111, at: 111), .none, "the same warning must not open twice")
        assertFalse(policy.canStop(at: 111), "showing the warning does not stop the recording")
    }

    runSuite("Meeting end detection — thirty seconds of warning give the user time before stopping") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        assertEqual(policy.observe(.inactive, sampledAt: 110, at: 110), .warningStarted, "the warning begins after confirmed inactivity")
        for time in [120.0, 130.0, 139.9] {
            assertEqual(policy.observe(.inactive, sampledAt: time, at: time), .none, "the grace period remains open")
            assertFalse(policy.canStop(at: time), "a UI tick before the deadline cannot stop")
        }
        assertEqual(policy.observe(.inactive, sampledAt: 140, at: 140), .stop, "an untouched warning stops at its deadline")
        assertTrue(policy.canStop(at: 140), "the UI deadline agrees with current inactivity evidence")
    }

    runSuite("Meeting end detection — the full countdown starts when the warning is actually shown") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        _ = policy.observe(.inactive, sampledAt: 109, at: 109)
        assertEqual(policy.observe(.inactive, sampledAt: 112, at: 112), .warningStarted, "the first eligible poll opens the warning")
        _ = policy.observe(.inactive, sampledAt: 122, at: 122)
        _ = policy.observe(.inactive, sampledAt: 132, at: 132)
        assertEqual(policy.observe(.inactive, sampledAt: 140, at: 140), .none, "a late warning still allows a full thirty seconds")
        assertFalse(policy.canStop(at: 140), "the deadline is measured from presentation")
        assertEqual(policy.observe(.inactive, sampledAt: 142, at: 142), .stop, "the complete displayed grace period expires")
    }

    runSuite("Meeting end detection — activity returning before the warning restarts the absence interval") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        assertEqual(policy.observe(.active, sampledAt: 109, at: 109), .none, "returning activity discards the interrupted interval")
        assertEqual(policy.observe(.inactive, sampledAt: 110, at: 110), .none, "new inactivity starts fresh")
        assertEqual(policy.observe(.inactive, sampledAt: 119, at: 119), .none, "old inactivity earns no credit")
        assertEqual(policy.observe(.inactive, sampledAt: 120, at: 120), .warningStarted, "a new full interval can warn")
    }

    runSuite("Meeting end detection — activity returning during the warning cancels automatic stopping") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        _ = policy.observe(.inactive, sampledAt: 110, at: 110)
        _ = policy.observe(.inactive, sampledAt: 120, at: 120)
        _ = policy.observe(.inactive, sampledAt: 130, at: 130)
        assertEqual(policy.observe(.active, sampledAt: 140, at: 140), .warningCleared, "activity wins even at the stop deadline")
        assertFalse(policy.canStop(at: 140), "a dismissed warning cannot authorize a UI stop")
        _ = policy.observe(.inactive, sampledAt: 141, at: 141)
        assertEqual(policy.observe(.inactive, sampledAt: 151, at: 151), .warningStarted, "a later end gets a new warning")
        assertFalse(policy.canStop(at: 151), "the new warning never inherits the old expired deadline")
    }

    runSuite("Meeting end detection — an unknown read cancels the warning and cannot stop the call") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        _ = policy.observe(.inactive, sampledAt: 110, at: 110)
        _ = policy.observe(.inactive, sampledAt: 120, at: 120)
        _ = policy.observe(.inactive, sampledAt: 130, at: 130)
        assertEqual(policy.observe(.unknown, sampledAt: 140, at: 140), .warningCleared, "a failed read at expiry cancels the warning")
        assertFalse(policy.canStop(at: 140), "unknown evidence cannot authorize stopping")
        _ = policy.observe(.inactive, sampledAt: 141, at: 141)
        assertEqual(policy.observe(.inactive, sampledAt: 150, at: 150), .none, "recovery needs a new uninterrupted interval")
        assertEqual(policy.observe(.inactive, sampledAt: 151, at: 151), .warningStarted, "reliable recovered evidence can warn again")
    }

    runSuite("Meeting end detection — an unknown read also resets inactivity before a warning") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        assertEqual(policy.observe(.unknown, sampledAt: 109, at: 109), .none, "unknown does not show a warning")
        _ = policy.observe(.inactive, sampledAt: 110, at: 110)
        assertEqual(policy.observe(.inactive, sampledAt: 119, at: 119), .none, "absence before the failure is discarded")
        assertEqual(policy.observe(.inactive, sampledAt: 120, at: 120), .warningStarted, "only recovered reliable absence counts")
    }

    runSuite("Meeting end detection — Keep recording suppresses further end prompts for this recording") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        _ = policy.observe(.inactive, sampledAt: 110, at: 110)
        policy.keepRecording()
        for time in stride(from: 120.0, through: 200.0, by: 10.0) {
            assertEqual(policy.observe(.inactive, sampledAt: time, at: time), .none, "keeping the recording suppresses future warnings and stops")
            assertFalse(policy.canStop(at: time), "an old UI countdown must not override the user's choice")
        }
        _ = policy.observe(.active, sampledAt: 201, at: 201)
        _ = policy.observe(.inactive, sampledAt: 202, at: 202)
        assertEqual(policy.observe(.inactive, sampledAt: 212, at: 212), .none, "new activity does not revoke Keep recording")
        var nextRecording = MeetingEndDetectionPolicy()
        _ = nextRecording.observe(.inactive, sampledAt: 300, at: 300)
        assertEqual(nextRecording.observe(.inactive, sampledAt: 310, at: 310), .warningStarted, "suppression belongs only to the current recording")
    }

    runSuite("Meeting end detection — missed polls reset inactivity and clear an outstanding warning") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        assertEqual(policy.observe(.inactive, sampledAt: 112.1, at: 112.1), .none, "more than twelve seconds unobserved cannot establish absence")
        assertEqual(policy.observe(.inactive, sampledAt: 122.1, at: 122.1), .warningStarted, "fresh uninterrupted absence can warn")
        assertEqual(policy.observe(.inactive, sampledAt: 135, at: 135), .warningCleared, "a missed poll invalidates the countdown evidence")
        assertFalse(policy.canStop(at: 153), "an expired old warning cannot survive a monitoring gap")
        assertEqual(policy.observe(.inactive, sampledAt: 145, at: 145), .warningStarted, "a full fresh interval follows the monitoring gap")
    }

    runSuite("Meeting end detection — a poll exactly twelve seconds later is still continuous") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        assertEqual(policy.observe(.inactive, sampledAt: 112, at: 112), .warningStarted, "the maximum permitted sample gap is inclusive")
        _ = policy.observe(.inactive, sampledAt: 124, at: 124)
        _ = policy.observe(.inactive, sampledAt: 136, at: 136)
        assertEqual(policy.observe(.inactive, sampledAt: 142, at: 142), .stop, "permitted poll gaps preserve the countdown")
    }

    runSuite("Meeting end detection — time moving backwards invalidates absence and warning evidence") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        _ = policy.observe(.inactive, sampledAt: 109, at: 109)
        assertEqual(policy.observe(.inactive, sampledAt: 108, at: 108), .none, "backwards time starts a fresh absence interval")
        assertEqual(policy.observe(.inactive, sampledAt: 117, at: 117), .none, "earlier absence cannot count after time moves backwards")
        assertEqual(policy.observe(.inactive, sampledAt: 118, at: 118), .warningStarted, "a fresh ten seconds can warn")
        assertEqual(policy.observe(.inactive, sampledAt: 117, at: 117), .warningCleared, "backwards time also clears an existing warning")
        assertFalse(policy.canStop(at: 148), "the old deadline has been invalidated")
    }

    runSuite("Meeting end detection — a UI expiry needs a reading sampled at or after the deadline") {
        var policy = MeetingEndDetectionPolicy()
        assertFalse(policy.canStop(at: 100), "a new recording has no stop authorization")
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        _ = policy.observe(.inactive, sampledAt: 110, at: 110)
        _ = policy.observe(.inactive, sampledAt: 120, at: 120)
        _ = policy.observe(.inactive, sampledAt: 130, at: 130)
        _ = policy.observe(.inactive, sampledAt: 135, at: 135)
        assertFalse(policy.canStop(at: 139.9), "any evidence before the deadline is insufficient")
        assertFalse(policy.canStop(at: 140), "a sample at 135s cannot prove the call was still gone at the 140s deadline")
        assertFalse(policy.canStop(at: 142), "waiting does not turn older evidence into post-deadline evidence")
        assertEqual(policy.observe(.inactive, sampledAt: 141, at: 141), .stop,
                    "the first reading sampled after the deadline stops the recording")
        assertTrue(policy.canStop(at: 141), "the confirmed stop is authorized")
        assertFalse(policy.canStop(at: 154), "even a confirmed stop still needs fresh polling")
    }

    runSuite("Meeting end detection — a rejoin after the deadline cancels the call-ended warning") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        _ = policy.observe(.inactive, sampledAt: 110, at: 110)
        _ = policy.observe(.inactive, sampledAt: 120, at: 120)
        _ = policy.observe(.inactive, sampledAt: 130, at: 130)
        _ = policy.observe(.inactive, sampledAt: 135, at: 135)
        assertFalse(policy.canStop(at: 140), "an inactive sample at 135s and a 140s deadline cannot authorize a stop")
        assertEqual(policy.observe(.active, sampledAt: 141, at: 141), .warningCleared,
                    "an active sample at 141s means the call had already rejoined")
        assertFalse(policy.canStop(at: 141), "a cancelled warning cannot stop the recording")
    }

    runSuite("Meeting end detection — post-deadline inactivity is what permits the stop") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        _ = policy.observe(.inactive, sampledAt: 110, at: 110)
        _ = policy.observe(.inactive, sampledAt: 120, at: 120)
        _ = policy.observe(.inactive, sampledAt: 130, at: 130)
        _ = policy.observe(.inactive, sampledAt: 135, at: 135)
        assertFalse(policy.canStop(at: 140), "the deadline alone is not proof the call was still gone")
        assertEqual(policy.observe(.inactive, sampledAt: 141, at: 141), .stop,
                    "an inactive sample at 141s permits stopping")
    }

    runSuite("Meeting end detection — a pre-deadline reading delivered after the deadline proves nothing") {
        var policy = MeetingEndDetectionPolicy()
        _ = policy.observe(.inactive, sampledAt: 100, at: 100)
        _ = policy.observe(.inactive, sampledAt: 110, at: 110)
        _ = policy.observe(.inactive, sampledAt: 120, at: 120)
        _ = policy.observe(.inactive, sampledAt: 131, at: 131)
        assertEqual(policy.observe(.inactive, sampledAt: 139, at: 141), .none,
                    "a reading sampled at 139s but delivered at 141s cannot confirm the 140s deadline")
        assertFalse(policy.canStop(at: 141), "delivery time must not stand in for sampling time")
        assertEqual(policy.observe(.inactive, sampledAt: 146, at: 146), .stop,
                    "the next reading actually sampled after the deadline stops the recording")
    }
}
