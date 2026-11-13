import AppKit
import Foundation

@available(macOS 14.0, *)
extension MeetingPromptDetector {
    // Members here that drop `private` do so only because another
    // MeetingPromptDetector file uses them; treat them as private to the type.

    @discardableResult
    func dismiss(candidate: Candidate) -> MeetingPromptBackoffDecision {
        // An explicit dismissal during a live call means the user chose not to
        // record it — the missed-call nudge must respect that and stay quiet.
        detectedCallSession?.userDeclined = true
        dismissStreaks[candidate.provider, default: 0] += 1
        let decision = dismiss(candidate: candidate, interval: nil)
        let result = applyLearnedDismissal(candidate: candidate, decision: decision)
        // A native call app holding the mic is a real call with clear edges:
        // Not now means "not this call". Its quiet (the provider-wide one, the
        // learned one) holds until the call ends, then the next call prompts.
        if candidate.callEvidence == .nativeApp, let kind = candidate.learnedBackoffKind {
            let now = Date()
            let notNow = NativeNotNow(
                provider: candidate.provider,
                kind: kind,
                candidateReason: cooldownReasons[candidate.id],
                providerReason: runtimeSuppressionReasons[candidate.provider],
                declinedAt: now
            )
            if detectedCallSession?.providers.contains(candidate.provider) == true {
                detectedCallSession?.nativeNotNows[candidate.id] = notNow
            } else {
                // The prompt outlived its call (the countdown keeps running
                // after hang-up): the call is already over, so cut now.
                nativeNotNowCallEnded([candidate.id: notNow], now: now)
            }
        }
        return result
    }

    /// The call a native Not now covered has ended. Cut that Not now's quiet
    /// to `recordedCallEndGrace` (a mic flap at hang-up stays quiet) and
    /// re-check then. Quiet something else wrote since (a calendar Not now,
    /// a Record) keeps its own window.
    func nativeNotNowCallEnded(_ notNows: [String: NativeNotNow], now: Date) {
        guard !notNows.isEmpty else { return }
        let until = now.addingTimeInterval(recordedCallEndGrace)
        var ended = endedNativeNotNowCall.flatMap { $0.graceEndsAt > now ? $0 : nil }
            ?? EndedNativeNotNowCall(notNows: [:], graceEndsAt: until)
        ended.notNows.merge(notNows) { _, newer in newer }
        ended.graceEndsAt = max(ended.graceEndsAt, until)
        endedNativeNotNowCall = ended
        for (id, notNow) in notNows {
            if notNow.candidateReason != nil, cooldownReasons[id] == notNow.candidateReason {
                if let current = snoozedUntil[id], current > until { snoozedUntil[id] = until }
                if let current = pendingUntil[id], current > until { pendingUntil[id] = until }
            }
            if notNow.providerReason != nil,
               runtimeSuppressionReasons[notNow.provider] == notNow.providerReason,
               let current = runtimeSuppressedUntil[notNow.provider], current > until {
                runtimeSuppressedUntil[notNow.provider] = until
            }
            learnedBackoff.endQuiet(kind: notNow.kind, by: until)
        }
        scheduleQuietEndRecheck(at: until, now: now)
    }

    /// A detected-call session is starting. If a call with a native Not now
    /// ended within the grace and this one is the same provider, it's that
    /// call coming back after a signal gap (AirPods connecting restart the
    /// app's audio): it stays declined, and its end cuts the quiet again.
    func carryOverEndedNativeNotNows(into session: inout DetectedCallSession, now: Date) {
        guard var ended = endedNativeNotNowCall else { return }
        guard ended.graceEndsAt > now else {
            endedNativeNotNowCall = nil
            return
        }
        let carried = ended.notNows.filter { session.providers.contains($0.value.provider) }
        guard !carried.isEmpty else { return }
        for (id, notNow) in carried {
            session.nativeNotNows[id] = notNow
            session.declinedKinds[notNow.kind] = notNow.declinedAt
            ended.notNows[id] = nil
        }
        session.userDeclined = true
        endedNativeNotNowCall = ended.notNows.isEmpty ? nil : ended
    }

    /// Feeds an explicit Not now on an ad-hoc prompt into the persisted
    /// learning: the same call is not asked about again, and consecutive Not
    /// nows for the same kind of call stay quiet longer. Returns the longer of
    /// the normal backoff and the learned one.
    private func applyLearnedDismissal(
        candidate: Candidate,
        decision: MeetingPromptBackoffDecision
    ) -> MeetingPromptBackoffDecision {
        guard let kind = candidate.learnedBackoffKind else { return decision }
        let now = Date()
        // A Not now to any browser prompt covers the whole browser call: the
        // user focusing the Meet tab a minute later must not re-ask it under
        // its real name.
        let declined = MeetingPromptLearnedBackoff.browserKinds.contains(kind)
            ? MeetingPromptLearnedBackoff.browserKinds
            : [kind]
        for declinedKind in declined {
            detectedCallSession?.declinedKinds[declinedKind] = now
        }
        if declined.count > 1 {
            // Also on the browser session, which outlives a muted Safari
            // briefly letting go of the mic (the detected call does not).
            for declinedKind in declined {
                browserTitles?.declinedKinds[declinedKind] = now
            }
        }
        let learnedUntil = learnedBackoff.recordDismissal(kind: kind, now: now)
        // A first Not now learns the same 30 minutes the normal backoff
        // already gives; only a longer learned window replaces the decision
        // (the slack absorbs the two clock reads being a moment apart).
        guard learnedUntil.timeIntervalSince(decision.until) > 60 else { return decision }

        let learned = MeetingPromptBackoffDecision(kind: .learnedQuiet, until: learnedUntil)
        snoozedUntil[candidate.id] = learnedUntil
        pendingUntil[candidate.id] = learnedUntil
        cooldownReasons[candidate.id] = learned.kind.rawValue
        if candidate.callEvidence.quietsProviderOnDismiss {
            suppressRuntimePrompts(for: candidate.provider, until: learnedUntil, reason: learned.kind.rawValue)
        }
        return learned
    }

    /// Forgets every learned Not now. Called when the user turns auto call
    /// detection back on, which is the reset for a prompt learned off.
    func resetLearnedBackoff() {
        learnedBackoff.reset()
    }

    /// Stop or Discard on an auto-started recording: stay quiet for the
    /// providers in this session until it ends. Does not stamp an 8-hour
    /// runtime suppress on every provider.
    func declineRestOfDetectedCall(now: Date = Date()) {
        guard var session = detectedCallSession else { return }
        session.userDeclined = true
        session.autoStartDeclinedProviders.formUnion(session.providers)
        if let named = session.namedBrowserProvider {
            session.autoStartDeclinedProviders.insert(named)
        }
        for kind in session.candidateKinds {
            session.declinedKinds[kind] = now
        }
        let wasBrowser = session.providers.contains(.googleMeet)
            || session.namedBrowserProvider != nil
            || session.sawBrowserCallTitle
        if wasBrowser {
            for kind in MeetingPromptLearnedBackoff.browserKinds {
                session.declinedKinds[kind] = now
            }
            if var titles = browserTitles {
                for kind in MeetingPromptLearnedBackoff.browserKinds {
                    titles.declinedKinds[kind] = now
                }
                browserTitles = titles
            }
        }
        detectedCallSession = session
    }

    /// Consecutive explicit dismissals for `provider` since the last accepted
    /// recording, for the dismiss-streak telemetry bucket.
    func dismissStreak(for provider: MeetingPromptProvider) -> Int {
        dismissStreaks[provider] ?? 0
    }

    @discardableResult
    func remindSoon(candidate: Candidate) -> MeetingPromptBackoffDecision {
        let now = Date()
        let until = now.addingTimeInterval(MeetingPromptHeuristics.remindSoonInterval)
        let decision = MeetingPromptBackoffDecision(
            kind: MeetingPromptHeuristics.remindSoonBackoffKind(for: candidate.source),
            until: until
        )
        suppressRuntimePrompts(for: candidate.provider, until: until, reason: decision.kind.rawValue)
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
        cooldownReasons[candidate.id] = decision.kind.rawValue
        return decision
    }

    /// The prompt countdown ran out with no interaction. That is weaker evidence
    /// of "don't record" than an explicit dismissal — the user may be heads-down
    /// in the call or on another Space — so schedule a short candidate-level
    /// re-offer instead of the provider-wide dismissal backoff. Capped at
    /// `MeetingPromptHeuristics.maxPromptExpiryReoffers` consecutive expiries;
    /// past the cap the candidate gets the same quiet backoff as `dismiss`,
    /// but is not marked `userDeclined` and does not increment the dismiss
    /// streak. An ignored call goes quiet without being recorded as an
    /// explicit no, so a missed-call nudge can still fire.
    @discardableResult
    func expire(candidate: Candidate) -> MeetingPromptBackoffDecision {
        let now = Date()
        var expiryCount = 1
        if let history = promptExpiryHistory[candidate.id],
           now.timeIntervalSince(history.lastExpiredAt) <= MeetingPromptHeuristics.promptExpiryStreakResetInterval {
            expiryCount = history.count + 1
        }
        promptExpiryHistory[candidate.id] = (expiryCount, now)

        guard MeetingPromptHeuristics.shouldReofferAfterExpiry(expiryCount: expiryCount) else {
            // Quiet suppress only. The public `dismiss(candidate:)` path is
            // the user's Not now tap — it sets userDeclined and grows the
            // streak. An unattended countdown past the cap must not.
            return dismiss(candidate: candidate, interval: nil)
        }

        // Candidate-level cooldown only — no `suppressRuntimePrompts` — so the
        // same call can re-offer once the interval passes.
        let until = now.addingTimeInterval(MeetingPromptHeuristics.promptExpiryReofferInterval)
        let decision = MeetingPromptBackoffDecision(kind: .expiredReoffer, until: until)
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
        cooldownReasons[candidate.id] = decision.kind.rawValue
        return decision
    }

    private func dismiss(candidate: Candidate, interval: TimeInterval?) -> MeetingPromptBackoffDecision {
        let now = Date()
        let baseInterval = MeetingPromptHeuristics.snoozeInterval(
            for: candidate.source,
            explicit: interval,
            defaultInterval: defaultSnoozeInterval
        )
        let decision: MeetingPromptBackoffDecision
        let until: Date
        switch candidate.source {
        case .calendarEvent:
            let minimumInterval = MeetingPromptHeuristics.dismissMinimumInterval(
                for: candidate.provider,
                default: baseInterval
            )
            until = max(
                now.addingTimeInterval(minimumInterval),
                candidate.endDate.addingTimeInterval(MeetingPromptHeuristics.calendarReminderPostStartGrace)
            )
            decision = MeetingPromptBackoffDecision(
                kind: MeetingPromptHeuristics.backoffKind(for: candidate.provider, source: .calendarEvent),
                until: until
            )
            suppressRuntimePrompts(for: candidate.provider, until: until, reason: decision.kind.rawValue)
        case .runtimeApp:
            if let resumeDate = nextRuntimePromptResumeDate(for: candidate.provider, now: now) {
                until = resumeDate
                decision = MeetingPromptBackoffDecision(
                    kind: MeetingPromptHeuristics.backoffKind(for: candidate.provider, source: .runtimeApp, hasResumeDate: true),
                    until: until
                )
            } else {
                let fallbackInterval = MeetingPromptHeuristics.dismissMinimumInterval(
                    for: candidate.provider,
                    default: MeetingPromptHeuristics.defaultRuntimeDismissFallbackInterval
                )
                until = now.addingTimeInterval(fallbackInterval)
                decision = MeetingPromptBackoffDecision(
                    kind: MeetingPromptHeuristics.backoffKind(for: candidate.provider, source: .runtimeApp),
                    until: until
                )
            }
            // A browser prompt that could not name its call (a guess from
            // time on the mic, the camera, or a call site in front) backs off
            // on its own candidate id only. Silencing the whole provider would
            // also hide a real Meet tab that shows up a few minutes after a
            // Not now to ChatGPT voice, or native Teams after a Teams chat tab.
            if candidate.callEvidence.quietsProviderOnDismiss {
                suppressRuntimePrompts(for: candidate.provider, until: until, reason: decision.kind.rawValue)
            }
        }
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
        cooldownReasons[candidate.id] = decision.kind.rawValue
        return decision
    }

    /// What `markAccepted` changed, so `markRecordStartFailed` can put it back.
    struct RecordStartUndo {
        let callStartedAt: Date?
        let sawMeetingRecording: Bool
        let runtimeSuppressedUntil: Date?
        let runtimeSuppressionReason: String?
    }

    func markAccepted(candidate: Candidate) {
        recordStartUndo[candidate.id] = RecordStartUndo(
            callStartedAt: detectedCallSession?.startedAt,
            sawMeetingRecording: detectedCallSession?.sawMeetingRecording ?? false,
            runtimeSuppressedUntil: runtimeSuppressedUntil[candidate.provider],
            runtimeSuppressionReason: runtimeSuppressionReasons[candidate.provider]
        )
        // Recording is starting; the session is covered even if the recording
        // begins after the next evaluate() pass samples own-capture state.
        detectedCallSession?.sawMeetingRecording = true
        dismissStreaks[candidate.provider] = nil
        let now = Date()
        if let kind = candidate.learnedBackoffKind {
            learnedBackoff.recordAccepted(kind: kind, now: now)
            detectedCallSession?.countedRecordingForLearning = true
        }
        let until: Date
        switch candidate.source {
        case .calendarEvent:
            until = max(
                now.addingTimeInterval(defaultSnoozeInterval),
                candidate.endDate.addingTimeInterval(MeetingPromptHeuristics.calendarReminderPostStartGrace)
            )
            suppressRuntimePrompts(for: candidate.provider, until: until, reason: "record_selected")
        case .runtimeApp:
            until = runtimeSuppressionEndDate(for: candidate.provider, now: now)
                ?? now.addingTimeInterval(defaultSnoozeInterval)
            suppressRuntimePrompts(for: candidate.provider, until: until, reason: "record_selected")
            recordSelectedAdHocCandidateIDs.insert(candidate.id)
        }
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
        cooldownReasons[candidate.id] = "record_selected"
        recordedCallQuietCutPending = false
    }

    /// Auto-start already reported `.autoStarted` but capture never began.
    /// Undo the early `markAccepted`, drop the 90-second pending window, then
    /// show the island prompt so the user is not left in a silent wait.
    func recoverFailedAutoStart(candidate: Candidate, now: Date = Date()) {
        markRecordStartFailed(candidate: candidate)
        snoozedUntil[candidate.id] = nil
        pendingUntil[candidate.id] = nil
        cooldownReasons[candidate.id] = nil
        // `markRecordStartFailed` already put back the provider's runtime
        // quiet and the call's earlier recording state. Clearing them here
        // would wipe an earlier Not now, or a recording this call already had
        // (which keeps auto-start off), along with the failed start's own.
        switch onPromptFallback?(candidate) ?? .skipped {
        case .presented:
            pendingUntil[candidate.id] = now.addingTimeInterval(pendingCooldown)
            cooldownReasons[candidate.id] = "prompt_pending"
            detectedCallSession?.promptShown = true
        case .autoStarted, .skipped:
            break
        }
    }

    /// The Record start `markAccepted` covered did not start. The call is
    /// unrecorded again (funnel, missed-call nudge) and may prompt again. The
    /// learned "yes" stays: the user did choose Record for this kind of call.
    func markRecordStartFailed(candidate: Candidate) {
        guard let undo = recordStartUndo.removeValue(forKey: candidate.id) else { return }
        recordSelectedAdHocCandidateIDs.remove(candidate.id)
        if let session = detectedCallSession, session.startedAt == undo.callStartedAt {
            detectedCallSession?.sawMeetingRecording = undo.sawMeetingRecording
        }
        if cooldownReasons[candidate.id] == "record_selected" {
            snoozedUntil[candidate.id] = nil
            pendingUntil[candidate.id] = nil
            cooldownReasons[candidate.id] = nil
        }
        if runtimeSuppressionReasons[candidate.provider] == "record_selected" {
            runtimeSuppressedUntil[candidate.provider] = undo.runtimeSuppressedUntil
            runtimeSuppressionReasons[candidate.provider] = undo.runtimeSuppressionReason
        }
    }

    /// The detected-call session ended. Record's quiet (the matching calendar
    /// event's end, or 30 minutes) is there so the recorded call doesn't prompt
    /// again, not the next one. If the recording has stopped, cut it to
    /// `recordedCallEndGrace` and re-check then, so a back-to-back call still
    /// prompts and a mic flap at hang-up doesn't. If it's still running, this
    /// may be a mute that let go of the mic (Safari does), so keep the quiet
    /// until a session ends, or a new one starts, with the recording stopped.
    func recordedCallSessionEnded(now: Date) {
        guard hasRecordedCallQuiet else { return }
        if isMeetingRecordingActive {
            recordedCallQuietCutPending = true
            return
        }
        cutRecordedCallQuiet(until: now.addingTimeInterval(recordedCallEndGrace), now: now)
    }

    /// A detected-call session started. The last one ended while still
    /// recording and that recording has stopped since: this is a new call, so
    /// it prompts now.
    func recordedCallSessionStarted(now: Date) {
        guard recordedCallQuietCutPending, !isMeetingRecordingActive else { return }
        cutRecordedCallQuiet(until: now, now: now)
    }

    private var hasRecordedCallQuiet: Bool {
        runtimeSuppressionReasons.values.contains("record_selected")
            || recordSelectedAdHocCandidateIDs.contains { cooldownReasons[$0] == "record_selected" }
    }

    private var isMeetingRecordingActive: Bool {
        switch currentOwnCaptureActivity() {
        case .meetingRecording, .unknown: true
        case .none, .dictation: false
        }
    }

    /// Cuts Record's quiet to `until`. A recorded calendar event keeps its own
    /// snooze, so its reminder doesn't come back.
    private func cutRecordedCallQuiet(until: Date, now: Date) {
        recordedCallQuietCutPending = false
        for (provider, reason) in runtimeSuppressionReasons where reason == "record_selected" {
            if let current = runtimeSuppressedUntil[provider], current > until {
                runtimeSuppressedUntil[provider] = until
            }
        }
        for id in recordSelectedAdHocCandidateIDs where cooldownReasons[id] == "record_selected" {
            if let current = snoozedUntil[id], current > until {
                snoozedUntil[id] = until
            }
            if let current = pendingUntil[id], current > until {
                pendingUntil[id] = until
            }
        }
        recordSelectedAdHocCandidateIDs.removeAll()
        scheduleQuietEndRecheck(at: until, now: now)
    }

    /// Re-evaluates once a cut quiet window ends, so a call already going on
    /// then still prompts without waiting for the next signal change.
    private func scheduleQuietEndRecheck(at until: Date, now: Date) {
        recordedCallQuietEndTask?.cancel()
        recordedCallQuietEndTask = nil
        let delay = until.timeIntervalSince(now)
        guard delay > 0 else { return }
        recordedCallQuietEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.recordedCallQuietEndTask = nil
            self.scheduleEvaluation()
        }
    }

    /// A prompt for `candidateID` was presented within the pending window and
    /// has not been answered. A dismissal also writes `pendingUntil` (for its
    /// whole backoff), so the cooldown reason tells the two apart.
    func isPromptShowing(candidateID: String, now: Date) -> Bool {
        guard let until = pendingUntil[candidateID], until > now else { return false }
        return cooldownReasons[candidateID] == "prompt_pending"
    }

    /// Why the persisted learning keeps this ad-hoc candidate quiet, or `nil`.
    func learnedSuppression(
        for candidate: Candidate,
        now: Date
    ) -> (reason: MeetingPromptSuppressionReason, cooldownReason: String)? {
        guard let kind = candidate.learnedBackoffKind else { return nil }
        if let declinedAt = detectedCallSession?.declinedKinds[kind] ?? browserTitles?.declinedKinds[kind],
           now.timeIntervalSince(declinedAt) < declinedThisCallLimit {
            return (.declinedThisCall, MeetingPromptSuppressionReason.declinedThisCall.rawValue)
        }
        // Turning a kind off for good needs the titles: without them a real
        // Meet call is just as "unrecognized" as ChatGPT voice.
        if browserTitles?.titlesReadable == true, learnedBackoff.isLearnedOff(kind: kind, now: now) {
            return (.learnedQuiet, "learned_off")
        }
        if learnedBackoff.quietUntil(for: kind, now: now) != nil {
            return (.learnedQuiet, MeetingPromptBackoffKind.learnedQuiet.rawValue)
        }
        return nil
    }

    private func suppressRuntimePrompts(for provider: MeetingPromptProvider, until: Date, reason: String?) {
        let existing = runtimeSuppressedUntil[provider] ?? .distantPast
        runtimeSuppressedUntil[provider] = max(existing, until)
        if let reason {
            runtimeSuppressionReasons[provider] = reason
        }
    }

    private func nextRuntimePromptResumeDate(for provider: MeetingPromptProvider, now: Date) -> Date? {
        guard let snapshot = nextRelevantCalendarSnapshot(for: provider, after: now) else { return nil }

        let promptDate = snapshot.startDate.addingTimeInterval(-MeetingPromptHeuristics.calendarReminderLeadTime)
        if promptDate > now {
            return promptDate
        }

        return snapshot.endDate.addingTimeInterval(MeetingPromptHeuristics.calendarReminderPostStartGrace)
    }

    private func runtimeSuppressionEndDate(for provider: MeetingPromptProvider, now: Date) -> Date? {
        nextRelevantCalendarSnapshot(for: provider, after: now)?
            .endDate
            .addingTimeInterval(MeetingPromptHeuristics.calendarReminderPostStartGrace)
    }

    private func nextRelevantCalendarSnapshot(
        for targetProvider: MeetingPromptProvider,
        after now: Date
    ) -> MeetingPromptCalendarEventSnapshot? {
        guard calendarAccessGranted() else { return nil }

        return calendarEventSnapshots
            .filter { isRuntimeResumeEligibleCalendarSnapshot($0, for: targetProvider, after: now) }
            .min { $0.startDate < $1.startDate }
    }

    private func isRuntimeResumeEligibleCalendarSnapshot(
        _ snapshot: MeetingPromptCalendarEventSnapshot,
        for targetProvider: MeetingPromptProvider,
        after now: Date
    ) -> Bool {
        guard !snapshot.isAllDay else { return false }
        guard snapshot.provider == targetProvider else { return false }
        guard snapshot.meetingURL != nil else { return false }
        return snapshot.endDate > now
    }
}
