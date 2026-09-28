import Foundation

public enum SpeakerNamingPolicy {
    /// Cosine-similarity bar above which a returning known speaker is auto-accepted
    /// (silently named) without asking the user to confirm.
    ///
    /// Raised 0.88 → 0.92 and decoupled from `EmbeddingClusterer.sameVoiceConsolidationThreshold`
    /// (which stays 0.88). The multi-meeting × audio-quality eval (SpeakerEvalHarness
    /// LADDER_SWEEP_REPORT.md §11 — NOT on main; that report lives only on the unmerged
    /// `eval/ladder-sweep-multi-meeting` branch, commit af869864) showed the old 0.88 bar
    /// silently mislabels 8–72% of auto-names
    /// on compressed/telephone/noisy audio; a higher bar + the margin guard below holds
    /// false-auto near 0 across all tested qualities (AMI-full N=175: 148 autos, 0 wrong).
    /// Within-meeting consolidation legitimately uses a *lower* bar (0.88) — it has
    /// temporal/contextual evidence two same-meeting clusters are one speaker — so the
    /// invariant is now `sameVoiceConsolidationThreshold <= autoAcceptSimilarityThreshold`.
    public static let autoAcceptSimilarityThreshold: Double = 0.92

    /// Minimum required gap between the best and second-best profile similarity before a
    /// returning speaker is auto-accepted. Degraded audio inflates the top similarity but
    /// rarely the *gap* to the runner-up, so this "clear winner" margin is the primary guard
    /// against silently naming the wrong person. A nil/absent runner-up (only one candidate
    /// cleared the match floor) is treated as unambiguous and passes.
    public static let autoAcceptMarginMin: Double = 0.12

    /// A person must be explicitly confirmed in this many distinct meetings
    /// before Transcripted may silently apply their name.
    public static let requiredConfirmedMeetings = 5

    /// Lower bars for calendar naming: used only when a voice's best match is a
    /// person on this meeting's calendar invite. The invite shrinks the lineup from
    /// everyone you've ever named to a handful of people, so a confident match is
    /// safe much earlier. Tuned in the YODAS3 speaker lab (Tools/SpeakerEvalHarness/
    /// YODAS_LAB_RESULTS.md): about half the naming work and silent naming from a
    /// person's second meeting, with no wrong names across ~200 silent namings.
    public struct InviteeBars: Sendable, Equatable {
        public var requiredConfirmedMeetings: Int
        public var similarity: Double
        public var marginMin: Double
        /// When no other saved person came close (no runner-up), the lower
        /// similarity bar alone isn't enough: the match must also clear
        /// `autoAcceptSimilarityThreshold`. Without an invite the lineup is
        /// just whoever you heard lately, so a stranger who sounds a bit like
        /// one of them has nobody to lose a margin to.
        public var needsRunnerUpBelowStandardBar: Bool

        public init(
            requiredConfirmedMeetings: Int,
            similarity: Double,
            marginMin: Double,
            needsRunnerUpBelowStandardBar: Bool = false
        ) {
            self.requiredConfirmedMeetings = requiredConfirmedMeetings
            self.similarity = similarity
            self.marginMin = marginMin
            self.needsRunnerUpBelowStandardBar = needsRunnerUpBelowStandardBar
        }

        public static let labTuned = InviteeBars(requiredConfirmedMeetings: 2, similarity: 0.80, marginMin: 0.10)
        /// Bars for the no-invite lineup (people heard most recently): the
        /// invite bars, but a lone match below 0.92 goes to review.
        public static let recentLineup = InviteeBars(
            requiredConfirmedMeetings: 2,
            similarity: 0.80,
            marginMin: 0.10,
            needsRunnerUpBelowStandardBar: true
        )
    }

    /// Who counts as "expected" in a meeting for lineup naming: the calendar invite,
    /// or, when there is none (a random Zoom), the people you've heard most recently.
    public struct LineupRequest: Sendable, Equatable {
        public var invitedNames: [String]
        /// With no invite, the this-many named people heard most recently form the
        /// lineup instead. 0 turns the fallback off.
        public var recentPeopleLimit: Int

        public init(invitedNames: [String], recentPeopleLimit: Int = 12) {
            self.invitedNames = invitedNames
            self.recentPeopleLimit = recentPeopleLimit
        }
    }

    /// Name keys for a meeting's lineup. Pass the profiles as they were BEFORE this
    /// meeting was matched, so a voice can't put itself on its own lineup.
    public static func lineupNameKeys(_ request: LineupRequest, profilesBeforeMeeting: [SpeakerProfile]) -> Set<String> {
        let invited = Set(request.invitedNames.map(nameKey).filter { !$0.isEmpty })
        if !invited.isEmpty || request.recentPeopleLimit <= 0 { return invited }
        let recent = profilesBeforeMeeting
            .filter { ($0.displayName?.isEmpty == false) && $0.confirmedMeetingCount >= 1 }
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(request.recentPeopleLimit)
        return Set(recent.compactMap { $0.displayName.map(nameKey) })
    }

    /// Case- and spacing-insensitive key for matching a saved name to an invitee name.
    public static func nameKey(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Lineup bars for `profile` when its name is on the lineup, else nil (today's bars).
    /// `lineupIsFromInvite` false means the lineup is the recent-people fallback.
    public static func inviteeBars(
        for profile: SpeakerProfile,
        invitedNameKeys: Set<String>,
        lineupIsFromInvite: Bool = true
    ) -> InviteeBars? {
        guard !invitedNameKeys.isEmpty, let name = profile.displayName, !name.isEmpty,
              invitedNameKeys.contains(nameKey(name)) else { return nil }
        return lineupIsFromInvite ? .labTuned : .recentLineup
    }

    /// True when `request` builds its lineup from a real invite rather than
    /// from the people heard most recently.
    public static func lineupIsFromInvite(_ request: LineupRequest) -> Bool {
        request.invitedNames.contains { !nameKey($0).isEmpty }
    }

    /// Profile-level eligibility for silent recognition, shared by the
    /// auto-accept gate and the review sheet's "recognizes N people" roster so
    /// the promise and the behavior can never drift apart: named, explicitly
    /// confirmed in enough distinct meetings, and healthy per the lifeline (no
    /// disputes, no recent corrections). Passive appearances never graduate a
    /// profile. Match-level gates (similarity, margin) live in `shouldAutoAccept`.
    public static func isAutoRecognizable(
        profile: SpeakerProfile,
        recentOutcomes: [SpeakerMatchOutcomeKind],
        requiredConfirmations: Int = requiredConfirmedMeetings
    ) -> Bool {
        profile.displayName?.isEmpty == false
            && profile.confirmedMeetingCount >= requiredConfirmations
            && SpeakerProfileHealth.assess(
                disputeCount: profile.disputeCount,
                recentOutcomes: recentOutcomes
            ) == .trusted
    }

    /// - Parameters:
    ///   - similarity: best-of-representatives similarity (blended average OR any stored
    ///     multi-exemplar voiceprint, `SpeakerVectorMath.bestSimilarity`). Checked against the
    ///     0.92 bar so the multi-exemplar recall win is preserved on degraded audio.
    ///   - secondBestSimilarity: legacy runner-up similarity used for the margin when
    ///     `marginSimilarities` is not supplied (and the sentinel: `< 0` ⇒ no runner-up, `nil` ⇒
    ///     unknown ⇒ conservative).
    ///   - marginSimilarities: when supplied, the best-vs-second **margin** is computed against
    ///     each profile's *average* representative (`best` = winner's cosine to its blended
    ///     average, `secondBest` = highest average cosine among the other candidates, `< 0` ⇒
    ///     none). Decoupling the margin from the best-exemplar score restores the "0 false-auto"
    ///     guarantee: a genuine owner is close on BOTH its average and its best exemplar so the
    ///     margin still holds, while an impostor that only cleared the 0.92 bar via one lucky
    ///     exemplar is far from the average, so its average-based margin collapses and auto-accept
    ///     is withheld (routed to suggest/ask). Legacy callers and single-average profiles (where
    ///     average == best exemplar) pass `nil` and behave exactly as before. See
    ///     `docs/speaker-eval-exemplar-delta-2026-07.md`.
    public static func shouldAutoAccept(
        profile: SpeakerProfile,
        similarity: Double,
        secondBestSimilarity: Double?,
        marginSimilarities: (best: Double, secondBest: Double)? = nil,
        inviteeBars: InviteeBars? = nil
    ) -> Bool {
        let marginTop = marginSimilarities?.best ?? similarity
        let marginRunnerUp: Double? = marginSimilarities.map { $0.secondBest } ?? secondBestSimilarity
        let marginOK: Bool
        switch marginRunnerUp {
        case .none:
            // Runner-up unknown (e.g. a fallback path that didn't carry it) — be conservative
            // and route to confirm rather than silently auto-name.
            marginOK = false
        case .some(let second) where second < 0:
            // No confusable runner-up cleared the match floor. On the no-invite
            // lineup that only counts at the standard bar.
            marginOK = !(inviteeBars?.needsRunnerUpBelowStandardBar ?? false)
                || similarity > autoAcceptSimilarityThreshold
        case .some(let second):
            marginOK = (marginTop - second) >= (inviteeBars?.marginMin ?? autoAcceptMarginMin)
        }
        return isAutoRecognizable(
            profile: profile,
            recentOutcomes: [],
            requiredConfirmations: inviteeBars?.requiredConfirmedMeetings ?? requiredConfirmedMeetings
        )
            && similarity > (inviteeBars?.similarity ?? autoAcceptSimilarityThreshold)
            && marginOK
    }

    /// Health-aware auto-accept: same gates as above, plus per-profile demotion.
    /// A profile whose recent lifeline outcomes show corrections is put on
    /// probation and routed to confirm — it must earn back one explicit
    /// confirmation before silent recognition resumes. `recentOutcomes` is
    /// most-recent-first (see `SpeakerDatabase.recentMatchOutcomes`).
    public static func shouldAutoAccept(
        profile: SpeakerProfile,
        similarity: Double,
        secondBestSimilarity: Double?,
        recentOutcomes: [SpeakerMatchOutcomeKind],
        marginSimilarities: (best: Double, secondBest: Double)? = nil,
        inviteeBars: InviteeBars? = nil
    ) -> Bool {
        guard isAutoRecognizable(
            profile: profile,
            recentOutcomes: recentOutcomes,
            requiredConfirmations: inviteeBars?.requiredConfirmedMeetings ?? requiredConfirmedMeetings
        ) else {
            return false
        }
        return shouldAutoAccept(
            profile: profile,
            similarity: similarity,
            secondBestSimilarity: secondBestSimilarity,
            marginSimilarities: marginSimilarities,
            inviteeBars: inviteeBars
        )
    }

    public static func confidence(similarity: Double, callCount: Int) -> SpeakerConfidence {
        similarity > 0.85 && callCount > 3 ? .high : .medium
    }

    public static func initialMapping(
        speakerId: String,
        profile: SpeakerProfile,
        similarity: Double,
        secondBestSimilarity: Double?,
        recentOutcomes: [SpeakerMatchOutcomeKind] = [],
        marginSimilarities: (best: Double, secondBest: Double)? = nil,
        inviteeBars: InviteeBars? = nil
    ) -> SpeakerMapping {
        guard shouldAutoAccept(
            profile: profile,
            similarity: similarity,
            secondBestSimilarity: secondBestSimilarity,
            recentOutcomes: recentOutcomes,
            marginSimilarities: marginSimilarities,
            inviteeBars: inviteeBars
        ),
              let name = profile.displayName,
              !name.isEmpty else {
            return SpeakerMapping(speakerId: speakerId)
        }

        return SpeakerMapping(
            speakerId: speakerId,
            identifiedName: name,
            confidence: confidence(similarity: similarity, callCount: profile.callCount),
            isConfirmedIdentity: true
        )
    }

    /// Row-level manual names should stay row-level edits, even when a mic row
    /// is manually set to "You". Only the sheet-wide "Keep as You" toggle
    /// should emit `.collapsedToMe`.
    public static func typedNameUpdate(
        entry: SpeakerNamingEntry,
        typedName: String,
        optionsByLabel: [String: SpeakerIdentityOption]
    ) -> SpeakerNameUpdate? {
        let typed = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }

        if let option = option(
            matching: typed,
            optionsByLabel: optionsByLabel
        ) {
            return SpeakerNameUpdate(
                persistentSpeakerId: entry.id,
                diarizerSpeakerId: entry.diarizerSpeakerId,
                channel: entry.channel,
                newName: option.displayName,
                action: .merged(targetProfileId: option.id)
            )
        }

        let action: SpeakerNameUpdate.NamingAction
        if entry.suggestedProfileId != nil {
            action = .named
        } else if let current = entry.currentName, !current.isEmpty {
            action = typed.caseInsensitiveCompare(current) == .orderedSame
                ? .confirmed
                : .corrected
        } else {
            action = .named
        }

        return SpeakerNameUpdate(
            persistentSpeakerId: entry.id,
            diarizerSpeakerId: entry.diarizerSpeakerId,
            channel: entry.channel,
            newName: typed,
            previousName: entry.currentName,
            action: action
        )
    }

    private static func option(
        matching input: String,
        optionsByLabel: [String: SpeakerIdentityOption]
    ) -> SpeakerIdentityOption? {
        if let exact = optionsByLabel[input] {
            return exact
        }

        let normalizedInput = normalizedSearchText(input)
        let displayMatches = optionsByLabel.values.filter {
            normalizedSearchText($0.displayName) == normalizedInput
        }
        guard displayMatches.count == 1 else { return nil }
        return displayMatches[0]
    }

    private static func normalizedSearchText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
