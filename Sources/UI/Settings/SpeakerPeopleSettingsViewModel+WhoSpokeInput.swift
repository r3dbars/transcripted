import SwiftUI
import TranscriptedCore

/// What a Speakers "Who spoke?" card asks: the island's review input built
/// from a saved meeting. Kept apart from the saves in `+MeetingReview.swift`,
/// which the model smoke compiles without the island's views.
extension SpeakerPeopleSettingsViewModel {
    /// The island's review input for one meeting: each unnamed voice, asked
    /// as "Marcus Reed?" when a saved person's voice matches it, else "Who's
    /// this?"; saved people for the name field; who the meeting named on its
    /// own (the footer's dots); and how each voice plays.
    func meetingReviewInput(for call: SpeakerPendingMeetingGroup) -> NotchIslandSpeakerReviewView.Input {
        var clips: [UUID: NotchIslandVoiceClip] = [:]
        let entries: [SpeakerNamingEntry] = call.voices.map { voice in
            let item = voice.representative
            let guess = SpeakerMeetingReviewPolicy.guess(for: voice.id, among: duplicateCandidates)
            let clipFile = item.clipURL ?? item.retainedAudioSample?.url
            if let clipURL = item.clipURL {
                clips[voice.id] = .file(clipURL)
            } else if let sample = item.retainedAudioSample {
                clips[voice.id] = .window(sample)
            } else {
                clips[voice.id] = NotchIslandVoiceClip.none
            }
            var entry = SpeakerNamingEntry(
                id: voice.id,
                suggestedProfileId: guess?.person.id,
                diarizerSpeakerId: item.diarizerSpeakerId,
                channel: item.channel.utteranceChannel,
                clipURL: clipFile ?? item.transcriptURL,
                sampleText: voice.sampleText ?? "",
                currentName: guess?.person.displayName,
                matchSimilarity: guess?.similarity,
                callCount: item.callCount,
                needsNaming: guess == nil,
                needsConfirmation: guess != nil
            )
            if let person = guess?.person, let standing = namingStanding(for: person) {
                entry.confirmationProgress = SpeakerNamingConfirmationProgress(
                    confirmedMeetings: standing.confirmedMeetings,
                    requiredMeetings: standing.requiredMeetings,
                    isTrusted: standing.isTrusted
                )
            }
            entry.callAppSuggestedName = item.callAppSuggestedName
            return entry
        }
        return NotchIslandSpeakerReviewView.Input(
            id: UUID(),
            speakers: entries,
            knownPeople: meetingReviewKnownPeople(),
            recognizedSpeakerNames: call.recognizedNames,
            clips: clips
        )
    }

    /// Everyone with a name, for the card's name field and its suggestions.
    private func meetingReviewKnownPeople() -> [SpeakerNameChoice] {
        profiles.compactMap { profile in
            guard let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            let standing = namingStanding(for: profile)
            return SpeakerNameChoice(
                id: profile.id,
                displayName: name,
                callCount: profile.callCount,
                confirmedMeetings: standing?.confirmedMeetings ?? max(0, profile.confirmedMeetingCount),
                isTrusted: standing?.isTrusted ?? true
            )
        }
    }

}
