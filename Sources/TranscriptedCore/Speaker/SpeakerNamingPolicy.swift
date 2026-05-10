import Foundation

public enum SpeakerNamingPolicy {
    public static func shouldAutoAccept(profile: SpeakerProfile, similarity: Double) -> Bool {
        profile.displayName != nil
            && profile.disputeCount == 0
            && similarity > 0.88
            && profile.callCount > 4
    }

    public static func confidence(similarity: Double, callCount: Int) -> SpeakerConfidence {
        similarity > 0.85 && callCount > 3 ? .high : .medium
    }

    public static func initialMapping(
        speakerId: String,
        profile: SpeakerProfile,
        similarity: Double
    ) -> SpeakerMapping {
        guard shouldAutoAccept(profile: profile, similarity: similarity),
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
        if let current = entry.currentName, !current.isEmpty {
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

    public static func rowUpdate(
        entry: SpeakerNamingEntry,
        typedName: String,
        isConfirmed: Bool,
        isDiscarded: Bool,
        optionsByLabel: [String: SpeakerIdentityOption]
    ) -> SpeakerNameUpdate? {
        let typed = typedName.trimmingCharacters(in: .whitespacesAndNewlines)

        if isDiscarded {
            return SpeakerNameUpdate(
                persistentSpeakerId: entry.id,
                diarizerSpeakerId: entry.diarizerSpeakerId,
                channel: entry.channel,
                newName: entry.currentName ?? "Speaker \(entry.diarizerSpeakerId)",
                previousName: entry.currentName,
                action: .discardedFromDatabase
            )
        }

        if isConfirmed, let current = entry.currentName, !current.isEmpty {
            if !typed.isEmpty, typed != current {
                return typedNameUpdate(
                    entry: entry,
                    typedName: typed,
                    optionsByLabel: optionsByLabel
                )
            }

            if let suggestedProfileId = entry.suggestedProfileId {
                return SpeakerNameUpdate(
                    persistentSpeakerId: entry.id,
                    diarizerSpeakerId: entry.diarizerSpeakerId,
                    channel: entry.channel,
                    newName: current,
                    action: .merged(targetProfileId: suggestedProfileId)
                )
            }

            return SpeakerNameUpdate(
                persistentSpeakerId: entry.id,
                diarizerSpeakerId: entry.diarizerSpeakerId,
                channel: entry.channel,
                newName: current,
                previousName: current,
                action: .confirmed
            )
        }

        return typedNameUpdate(
            entry: entry,
            typedName: typed,
            optionsByLabel: optionsByLabel
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
