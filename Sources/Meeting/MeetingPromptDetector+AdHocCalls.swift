import AppKit
import Foundation

@available(macOS 14.0, *)
extension MeetingPromptDetector {
    // Members here that drop `private` do so only because another
    // MeetingPromptDetector file uses them; treat them as private to the type.

    // MARK: - Mic-activity candidates (ad-hoc call detection)

    /// Pushed by `MicActivityMonitor` with the set of non-self bundle IDs holding
    /// the mic input. Stores it and re-evaluates; existing pending/dismiss
    /// cooldowns survive inactive edges so mute/unmute cannot re-prompt early.
    func updateMicInputUsers(_ bundleIDs: Set<String>) {
        guard bundleIDs != micActiveBundleIDs else { return }
        micActiveBundleIDs = bundleIDs
        if bundleIDs.contains(where: MeetingPromptProvider.isBrowserBundleID) {
            browserMicEndTask?.cancel()
            browserMicEndTask = nil
            if browserMicSince == nil {
                browserMicSince = Date()
            }
        } else if browserMicSince != nil, browserMicEndTask == nil {
            scheduleBrowserMicSessionEnd()
        }
        scheduleEvaluation()
    }

    /// Pushed by `MicActivityMonitor` with the browser processes playing audio
    /// while a browser holds the mic. Someone talking back makes an
    /// unrecognized browser mic look like a call, so the prompt comes sooner.
    func updateBrowserOutputUsers(_ bundleIDs: Set<String>) {
        guard bundleIDs != browserOutputActiveBundleIDs else { return }
        browserOutputActiveBundleIDs = bundleIDs
        guard browserMicSince != nil else { return }
        scheduleEvaluation()
    }

    /// Pushed by `CameraActivityMonitor`: `true` when a camera is confirmed in
    /// use. Re-evaluates so a camera-on, mic-muted call can prompt; de-dupes with
    /// the mic signal in `callSignals` so a normal video call raises one prompt.
    func updateCameraInUse(_ inUse: Bool) {
        guard inUse != cameraInUse else { return }
        cameraInUse = inUse
        cameraOnSince = inUse ? Date() : nil
        cameraEvidenceFamilies = []
        cameraEvidenceSince = nil
        if !inUse, browserMicSince == nil {
            // A camera-only browser call just ended; forget its title verdict.
            endBrowserMicSession()
        }
        scheduleEvaluation()
    }

    /// Pushed by `MicActivityMonitor`'s output side with the set of native
    /// conferencing bundle IDs confirmed to be playing audio output. Catches the
    /// listen-only / hard-muted join where nothing holds the mic; de-dupes with
    /// the mic and camera signals in `callSignals`.
    func updateAudioOutputUsers(_ bundleIDs: Set<String>) {
        guard bundleIDs != audioOutputActiveBundleIDs else { return }
        audioOutputActiveBundleIDs = bundleIDs
        scheduleEvaluation()
    }

    /// What the ad-hoc sensors see right now, for prompt-decision telemetry.
    func currentSignalSnapshot() -> MeetingPromptSignalSnapshot {
        MeetingPromptSignalSnapshot(
            micActive: !micInputProviders().isEmpty,
            speakerActive: !audioOutputProviders().isEmpty,
            cameraActive: cameraInUse
        )
    }

    // The live detected-call session assembled from the ad-hoc signals (mic /
    // output / camera). Tracked across evaluate() passes so a call that ends
    // unrecorded can raise the missed-call nudge.
    struct DetectedCallSession {
        var providers: Set<MeetingPromptProvider>
        // Every ad-hoc reason seen during the call (mic/output/camera), for the
        // coarse signal_kinds funnel property.
        var seenReasons: Set<MeetingPromptReason>
        let startedAt: Date
        var sawMeetingRecording: Bool
        var userDeclined: Bool
        var promptShown: Bool
        // Learning kinds the user said Not now to during this call, and when,
        // so the same call is not asked about again after the quiet window
        // ends (capped by `declinedThisCallLimit`).
        var declinedKinds: [String: Date] = [:]
        // Learning kinds this call actually produced a candidate for. Only
        // these count as a "yes" when the user records during the call.
        var candidateKinds: Set<String> = []
        // The provider a call-only tab title named, for the funnel event and
        // the nudge (the signal itself only says "some browser").
        var namedBrowserProvider: MeetingPromptProvider?
        // The prompt was held back by earlier Not nows. The user taught it to
        // stop, so the missed-call nudge stays quiet too.
        var learnedQuietSeen = false
        // Browser title verdicts seen during the call. A browser mic that was
        // only ever a known non-call site (ChatGPT voice) is not a call, so it
        // must not feed the funnel event or the missed-call nudge.
        var sawBrowserCallTitle = false
        var sawBrowserNonCallSite = false
        // Whether a meeting recording during this call already counted as a
        // "yes" for the learning.
        var countedRecordingForLearning = false
    }

    // MARK: - Detected-call session (missed-call nudge)

    /// Folds the current ad-hoc call signals into the running session. A
    /// nonempty→empty transition ends the call; if it was long enough,
    /// unrecorded, and not explicitly declined, `onUnrecordedCallEnded` fires.
    /// Runs every evaluate() pass, so signal-inactive edges from the monitors
    /// end the session promptly and the 20s poll bounds recording-overlap
    /// sampling. Meeting recordings keep the underlying app's signals alive
    /// (only our own bundle is filtered), so recording never splits a session.
    func updateDetectedCallSession(
        signals: [(provider: MeetingPromptProvider, reason: MeetingPromptReason)],
        now: Date
    ) {
        let providers = Set(signals.map(\.provider))
        let reasons = Set(signals.map(\.reason))
        let isMeetingRecording = currentOwnCaptureActivity() == .meetingRecording

        guard var session = detectedCallSession else {
            if !providers.isEmpty {
                detectedCallSession = DetectedCallSession(
                    providers: providers,
                    seenReasons: reasons,
                    startedAt: now,
                    sawMeetingRecording: isMeetingRecording,
                    userDeclined: false,
                    promptShown: false
                )
            }
            return
        }

        if providers.isEmpty {
            detectedCallSession = nil
            finishDetectedCallSession(session, endedAt: now)
        } else {
            session.providers.formUnion(providers)
            session.seenReasons.formUnion(reasons)
            session.sawMeetingRecording = session.sawMeetingRecording || isMeetingRecording
            if isMeetingRecording, !session.countedRecordingForLearning {
                // The user started a meeting (from the menu, the hotkey, or a
                // prompt) while this call was going on: a "yes" for the kinds
                // of prompt this call raised (or held back), which clears
                // their learned quiet. A recording started before any prompt
                // was considered (⌥M, then join) teaches nothing.
                let kinds = session.candidateKinds.union(session.declinedKinds.keys)
                if !kinds.isEmpty {
                    session.countedRecordingForLearning = true
                    for kind in kinds {
                        learnedBackoff.recordAccepted(kind: kind, now: now)
                    }
                }
            }
            detectedCallSession = session
        }
    }

    private func finishDetectedCallSession(_ session: DetectedCallSession, endedAt: Date) {
        // A disabled auto-detect toggle empties the signals artificially —
        // neither the funnel event nor the nudge should fire off the back of
        // the user turning detection off.
        guard isMicInputPromptEnabled?() != false else { return }
        // Browser mic use that only ever showed a known non-call site (ChatGPT
        // voice, Loom) was not a call: no funnel event, no missed-call nudge.
        // Unless the user treated it as one (a prompt showed, or they
        // recorded), which the funnel must still count.
        if session.providers == [.googleMeet], session.sawBrowserNonCallSite, !session.sawBrowserCallTitle,
           !session.sawMeetingRecording, !session.promptShown {
            return
        }

        let duration = endedAt.timeIntervalSince(session.startedAt)
        let provider: MeetingPromptProvider
        let isBrowserCall: Bool
        if session.providers == [.googleMeet], let named = session.namedBrowserProvider {
            provider = named
            isBrowserCall = true
        } else {
            provider = session.providers.sorted { $0.rawValue < $1.rawValue }.first ?? .googleMeet
            // Browser signals map to `.googleMeet`; native apps never do.
            isBrowserCall = provider == .googleMeet
        }

        if duration >= MeetingPromptCallTelemetry.minimumReportableCallDuration {
            onDetectedCallEnded?(
                MeetingPromptDetectedCallSummary(
                    provider: provider,
                    duration: duration,
                    wasRecorded: session.sawMeetingRecording,
                    promptOutcome: MeetingPromptCallTelemetry.promptOutcome(
                        promptShown: session.promptShown,
                        wasRecorded: session.sawMeetingRecording,
                        userDeclined: session.userDeclined
                    ),
                    signalKinds: MeetingPromptCallTelemetry.signalKinds(
                        micSeen: session.seenReasons.contains(.micInput),
                        speakerSeen: session.seenReasons.contains(.audioOutput),
                        cameraSeen: session.seenReasons.contains(.cameraInput)
                    ),
                    appSignal: MeetingPromptCallTelemetry.appSignal(
                        isBrowser: isBrowserCall,
                        micSeen: session.seenReasons.contains(.micInput),
                        outputSeen: session.seenReasons.contains(.audioOutput),
                        cameraSeen: session.seenReasons.contains(.cameraInput)
                    )
                )
            )
        }

        // The user taught the prompt to stay quiet for this kind of call; a
        // "you didn't record that" nudge afterwards would undo that.
        guard !session.learnedQuietSeen else { return }

        guard MissedCallNudgePolicy.shouldNudge(
            duration: duration,
            sawMeetingRecording: session.sawMeetingRecording,
            userDeclined: session.userDeclined,
            lastNudgeAt: lastMissedCallNudgeAt,
            now: endedAt
        ) else { return }

        lastMissedCallNudgeAt = endedAt
        onUnrecordedCallEnded?(MeetingPromptUnrecordedCall(provider: provider, duration: duration))
    }

    func micInputCandidates(now: Date, frontmostBundleID: String?) -> [ScoredCandidate] {
        let signals = callSignals(frontmostBundleID: frontmostBundleID)
        guard !signals.isEmpty else { return [] }
        guard isMicInputPromptEnabled?() != false else {
            signals.forEach {
                recordSuppression(
                    candidate: micInputCandidate(for: $0.provider, reason: $0.reason, evidence: .none, now: now).candidate,
                    reason: .micInputDisabled,
                    now: now
                )
            }
            return []
        }
        // Never prompt to record a call while we already hold the mic ourselves.
        let captureActivity = currentOwnCaptureActivity()
        guard captureActivity == .none else {
            signals.forEach {
                recordSuppression(
                    candidate: micInputCandidate(for: $0.provider, reason: $0.reason, evidence: .none, now: now).candidate,
                    reason: .ownCaptureActive,
                    now: now,
                    captureActivity: captureActivity
                )
            }
            return []
        }

        var candidates: [ScoredCandidate] = []
        for signal in signals {
            guard let scored = adHocCandidate(for: signal, frontmostBundleID: frontmostBundleID, now: now) else {
                continue
            }
            let candidate = scored.candidate
            if let kind = candidate.learnedBackoffKind {
                detectedCallSession?.candidateKinds.insert(kind)
            }
            if candidate.isBrowserCall {
                // Decided for this browser session: a prompt now, or held back
                // by the user's own earlier answers. No more title re-reads.
                cancelBrowserEvidenceRecheck()
            }

            if let suppressedUntil = runtimeSuppressedUntil[candidate.provider], suppressedUntil > now {
                recordSuppression(
                    candidate: candidate,
                    reason: .runtimeSuppressed,
                    now: now,
                    cooldownReason: runtimeSuppressionReasons[candidate.provider]
                )
                continue
            }

            if let learned = learnedSuppression(for: candidate, now: now) {
                detectedCallSession?.learnedQuietSeen = true
                recordSuppression(
                    candidate: candidate,
                    reason: learned.reason,
                    now: now,
                    cooldownReason: learned.cooldownReason
                )
                continue
            }

            // The browser prompts have different ids (generic, call site, and
            // one per named provider) so a Not now to one does not snooze the
            // others. They are still one call on screen, so a prompt already
            // showing for any of them keeps the rest back.
            if candidate.isBrowserCall,
               browserCandidateIDs(besides: candidate.id).contains(where: { isPromptShowing(candidateID: $0, now: now) }) {
                recordSuppression(
                    candidate: candidate,
                    reason: .pendingCandidate,
                    now: now,
                    cooldownReason: "prompt_pending"
                )
                continue
            }

            candidates.append(scored)
        }
        return candidates
    }

    /// Ad-hoc call signals, tiered by attribution strength: the mic is the
    /// primary signal; native-app audio output is the standalone fallback when
    /// nothing holds the mic (the listen-only / hard-muted join, with real
    /// process attribution); the camera is the last standalone signal, so a
    /// normal mic-and-camera call is a single mic prompt and the camera's
    /// frontmost-based attribution never overrides or duplicates a stronger
    func callSignals(
        frontmostBundleID: String?
    ) -> [(provider: MeetingPromptProvider, reason: MeetingPromptReason)] {
        let micProviders = micInputProviders()
        if !micProviders.isEmpty {
            return micProviders.map { ($0, .micInput) }
        }

        let outputProviders = audioOutputProviders()
        if !outputProviders.isEmpty {
            return outputProviders.map { ($0, .audioOutput) }
        }

        if cameraInUse,
           let provider = MeetingPromptProvider.cameraCallProvider(forFrontmostBundleID: frontmostBundleID) {
            return [(provider, .cameraInput)]
        }

        return []
    }

    private func micInputProviders() -> [MeetingPromptProvider] {
        Set(micActiveBundleIDs.compactMap(MeetingPromptProvider.micInputProvider(forBundleID:)))
            .sorted { $0.rawValue < $1.rawValue }
    }

    private func audioOutputProviders() -> [MeetingPromptProvider] {
        Set(audioOutputActiveBundleIDs.compactMap(MeetingPromptProvider.audioOutputProvider(forBundleID:)))
            .sorted { $0.rawValue < $1.rawValue }
    }

    func micInputCandidate(
        for provider: MeetingPromptProvider,
        reason: MeetingPromptReason,
        evidence: MeetingPromptCallEvidence,
        now: Date
    ) -> ScoredCandidate {
        // A browser call we could not name (a guess from time on the mic, the
        // camera, or a call site in front) keeps the neutral title: it could
        // be Meet, Zoom web, or Teams web. A call-only tab title gets the
        // real name.
        let isGenericBrowserCall: Bool
        let id: String
        switch evidence {
        case .tabTitle, .nativeApp:
            isGenericBrowserCall = false
            id = micCandidateID(for: provider)
        case .none:
            isGenericBrowserCall = provider == .googleMeet
            id = micCandidateID(for: provider)
        case .callSite:
            isGenericBrowserCall = true
            id = Self.browserCallSiteCandidateID
        case .camera, .micAndOutput, .micOnly, .nonCallSite:
            isGenericBrowserCall = true
            id = Self.unverifiedBrowserCandidateID
        }
        let title = isGenericBrowserCall
            ? "Call detected in your browser"
            : "\(provider.displayName) call detected"
        let presentation = MeetingPromptHeuristics.micInputPresentation(
            title: title,
            meetingShortcut: meetingShortcutDisplay()
        )

        return ScoredCandidate(
            candidate: Candidate(
                id: id,
                title: presentation.title,
                detail: presentation.detail,
                provider: provider,
                reason: reason,
                source: .runtimeApp,
                startDate: now,
                endDate: now.addingTimeInterval(MeetingPromptHeuristics.runtimeReminderSnoozeInterval),
                meetingURL: nil,
                suggestedTranscriptTitle: nil,
                callEvidence: evidence
            ),
            score: presentation.score
        )
    }

    func micCandidateID(for provider: MeetingPromptProvider) -> String {
        "mic:\(provider.rawValue)"
    }

    /// The generic browser prompt with no call title behind it. Kept apart
    /// from `mic:googleMeet` so a Not now to it only snoozes itself.
    static let unverifiedBrowserCandidateID = "mic:browser"
    /// The generic browser prompt with a call app or site in front (Teams
    /// chat, a Slack huddle). Its own id for the same reason.
    static let browserCallSiteCandidateID = "mic:browser-call"
}
