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
        return applyLearnedDismissal(candidate: candidate, decision: decision)
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

    @discardableResult
    func snooze(candidate: Candidate, interval: TimeInterval? = nil) -> MeetingPromptBackoffDecision {
        detectedCallSession?.userDeclined = true
        dismissStreaks[candidate.provider, default: 0] += 1
        return dismiss(candidate: candidate, interval: interval)
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

    func markAccepted(candidate: Candidate) {
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
        }
        snoozedUntil[candidate.id] = until
        pendingUntil[candidate.id] = until
        cooldownReasons[candidate.id] = "record_selected"
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

    private func suppressRuntimePrompts(for provider: MeetingPromptProvider, until: Date) {
        suppressRuntimePrompts(for: provider, until: until, reason: nil)
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
