import Foundation

public enum SpeakerNamingPolicy {
    /// Cosine-similarity bar above which a returning known speaker is auto-accepted
    /// (silently named) without asking the user to confirm.
    ///
    /// Raised 0.88 → 0.92 and decoupled from `EmbeddingClusterer.sameVoiceConsolidationThreshold`
    /// (which stays 0.88). The multi-meeting × audio-quality eval (SpeakerEvalHarness
    /// LADDER_SWEEP_REPORT §11) showed the old 0.88 bar silently mislabels 8–72% of auto-names
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

    /// Profile-level eligibility for silent recognition, shared by the
    /// auto-accept gate and the review sheet's "recognizes N people" roster so
    /// the promise and the behavior can never drift apart: named, mature
    /// (`callCount > 4`), and healthy per the lifeline (no disputes, no recent
    /// corrections). Match-level gates (similarity, margin) live in
    /// `shouldAutoAccept`.
    public static func isAutoRecognizable(
        profile: SpeakerProfile,
        recentOutcomes: [SpeakerMatchOutcomeKind]
    ) -> Bool {
        profile.displayName?.isEmpty == false
            && profile.callCount > 4
            && SpeakerProfileHealth.assess(
                disputeCount: profile.disputeCount,
                recentOutcomes: recentOutcomes
            ) == .trusted
    }

    public static func shouldAutoAccept(
        profile: SpeakerProfile,
        similarity: Double,
        secondBestSimilarity: Double?
    ) -> Bool {
        let marginOK: Bool
        switch secondBestSimilarity {
        case .none:
            // Runner-up unknown (e.g. a fallback path that didn't carry it) — be conservative
            // and route to confirm rather than silently auto-name.
            marginOK = false
        case .some(let second) where second < 0:
            marginOK = true   // no confusable runner-up cleared the match floor
        case .some(let second):
            marginOK = (similarity - second) >= autoAcceptMarginMin
        }
        return isAutoRecognizable(profile: profile, recentOutcomes: [])
            && similarity > autoAcceptSimilarityThreshold
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
        recentOutcomes: [SpeakerMatchOutcomeKind]
    ) -> Bool {
        guard isAutoRecognizable(profile: profile, recentOutcomes: recentOutcomes) else {
            return false
        }
        return shouldAutoAccept(
            profile: profile,
            similarity: similarity,
            secondBestSimilarity: secondBestSimilarity
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
        recentOutcomes: [SpeakerMatchOutcomeKind] = []
    ) -> SpeakerMapping {
        guard shouldAutoAccept(
            profile: profile,
            similarity: similarity,
            secondBestSimilarity: secondBestSimilarity,
            recentOutcomes: recentOutcomes
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
