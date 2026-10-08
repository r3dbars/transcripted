import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Keeps Core's naming and ranking policies at the Meeting boundary.
enum SpeakerReviewBridge {
    static func ranked(_ entries: [SpeakerNamingEntry]) -> [SpeakerNamingEntry] {
        SpeakerReviewPrioritizer.ranked(entries)
    }

    static func typedNameUpdate(
        entry: SpeakerNamingEntry,
        typedName: String,
        optionsByLabel: [String: SpeakerNameChoice]
    ) -> SpeakerReviewUpdate? {
        let options = optionsByLabel.mapValues {
            SpeakerIdentityOption(id: $0.id, displayName: $0.displayName, callCount: $0.callCount)
        }
        return SpeakerNamingPolicy.typedNameUpdate(entry: entry, typedName: typedName, optionsByLabel: options)
            .map(reviewUpdate)
    }

    static func matchOutcome(for update: SpeakerReviewUpdate) -> String? {
        SpeakerMatchOutcomeKind(reviewAction: coreAction(update.action))?.rawValue
    }

    static func coreUpdate(_ update: SpeakerReviewUpdate) -> SpeakerNameUpdate {
        SpeakerNameUpdate(
            persistentSpeakerId: update.persistentSpeakerId,
            diarizerSpeakerId: update.diarizerSpeakerId,
            channel: coreChannel(update.channel),
            newName: update.newName,
            previousName: update.previousName,
            action: coreAction(update.action),
            resolvedPersistentSpeakerId: update.resolvedPersistentSpeakerId
        )
    }

    static func reviewUpdate(_ update: SpeakerNameUpdate) -> SpeakerReviewUpdate {
        let action: SpeakerReviewUpdate.NamingAction
        switch update.action {
        case .named: action = .named
        case .confirmed: action = .confirmed
        case .corrected: action = .corrected
        case .merged(let target): action = .merged(targetProfileId: target)
        case .collapsedToMe: action = .collapsedToMe
        case .discardedFromDatabase: action = .discardedFromDatabase
        }
        return SpeakerReviewUpdate(
            persistentSpeakerId: update.persistentSpeakerId,
            diarizerSpeakerId: update.diarizerSpeakerId,
            channel: channel(update.channel),
            newName: update.newName,
            previousName: update.previousName,
            action: action,
            resolvedPersistentSpeakerId: update.resolvedPersistentSpeakerId
        )
    }

    static func channel(_ value: UtteranceChannel) -> SpeakerReviewUpdate.Channel {
        switch value {
        case .mic: return .mic
        case .system: return .system
        }
    }

    private static func coreChannel(_ value: SpeakerReviewUpdate.Channel) -> UtteranceChannel {
        switch value {
        case .mic: return .mic
        case .system: return .system
        }
    }

    private static func coreAction(_ action: SpeakerReviewUpdate.NamingAction) -> SpeakerNameUpdate.NamingAction {
        switch action {
        case .named: return .named
        case .confirmed: return .confirmed
        case .corrected: return .corrected
        case .merged(let target): return .merged(targetProfileId: target)
        case .collapsedToMe: return .collapsedToMe
        case .discardedFromDatabase: return .discardedFromDatabase
        }
    }
}
