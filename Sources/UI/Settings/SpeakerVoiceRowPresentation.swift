import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

// Foundation-pure presentation + policy helpers for the "voices to name" rows on
// the Speakers settings surface. Kept view-free so the play/pause state machine,
// the overflow-menu actions, and the name autocomplete data source can be unit
// tested without instantiating SwiftUI/AppKit views.

// MARK: - Play / pause button presentation

/// Drives the circular play/pause toggle on a voice row. The toggle itself is a
/// thin renderer over `SpeakerClipPlayback`, which already guarantees only one
/// clip plays at a time; this helper only decides what the button should look
/// and read like for a given (hasClip, isPlaying) pair.
enum SpeakerClipPlaybackPresentation {
    static let playSymbol = "play.fill"
    static let pauseSymbol = "pause.fill"

    /// SF Symbol name for the toggle: a pause glyph while this row's clip plays,
    /// otherwise the play glyph.
    static func symbolName(isPlaying: Bool) -> String {
        isPlaying ? pauseSymbol : playSymbol
    }

    /// Whether the row should render its "currently playing" highlight. Only a
    /// row that actually has a clip *and* is playing lights up, so with many
    /// rows on screen the active one stays unambiguous.
    static func isActiveHighlight(hasClip: Bool, isPlaying: Bool) -> Bool {
        hasClip && isPlaying
    }

    static func accessibilityLabel(isPlaying: Bool) -> String {
        isPlaying ? "Pause voice sample" : "Play voice sample"
    }

    static func helpText(hasClip: Bool, isPlaying: Bool) -> String {
        guard hasClip else { return "No voice clip was saved for this speaker" }
        return isPlaying ? "Pause this voice sample" : "Play a short clip of this voice"
    }
}

// MARK: - Overflow (three-dots) menu

/// Actions exposed by the three-dots overflow menu on a voice row. Replaces the
/// former bare transcript-document icon.
enum SpeakerVoiceRowMenuAction: String, CaseIterable {
    case showTranscript
    case deleteVoice

    var title: String {
        switch self {
        case .showTranscript: return "Show transcript"
        case .deleteVoice: return "Delete voice"
        }
    }

    /// Whether this action removes data and should be presented destructively
    /// (and behind a confirmation prompt).
    var isDestructive: Bool {
        switch self {
        case .showTranscript: return false
        case .deleteVoice: return true
        }
    }
}

enum SpeakerVoiceRowMenuPolicy {
    /// Menu items in display order. "Show transcript" first (the safe,
    /// previously icon-only action), then the destructive "Delete voice".
    static let actions: [SpeakerVoiceRowMenuAction] = SpeakerVoiceRowMenuAction.allCases

    /// Error copy to surface when a delete request did not actually remove the
    /// speaker. Returns `nil` on success so callers never show a false error,
    /// and never let a failed delete silently no-op.
    static func deleteErrorMessage(didDelete: Bool) -> String? {
        didDelete ? nil : "Couldn't delete this voice. The speaker may still be saved — try again."
    }

    static let deleteConfirmationTitle = "Delete this voice?"
    static let deleteConfirmationMessage =
        "This removes the saved voice profile and sample clip. Past transcripts stay unchanged."
}

// MARK: - Name autocomplete data source

/// Builds the suggestion list that feeds the "Who is this?" autocomplete. Reuses
/// the same `SpeakerIdentityOption` shape that the post-meeting naming sheet
/// passes into `SpeakerNameSelectionPolicy`, so the two surfaces match new
/// speakers the same way.
enum SpeakerNameSuggestionSource {
    /// Returns one identity option per *named* profile, excluding the voice
    /// currently being named (a voice should never suggest itself). Profiles
    /// with a blank/whitespace-only display name are skipped because they offer
    /// nothing to autocomplete to.
    static func options(
        from profiles: [SpeakerProfile],
        excluding excludedId: UUID?
    ) -> [SpeakerIdentityOption] {
        profiles.compactMap { profile in
            guard profile.id != excludedId else { return nil }
            let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return nil }
            return SpeakerIdentityOption(
                id: profile.id,
                displayName: name,
                callCount: profile.callCount
            )
        }
    }
}
