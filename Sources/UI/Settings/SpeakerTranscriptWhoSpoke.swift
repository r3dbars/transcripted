// SpeakerTranscriptWhoSpoke.swift
// The "Who spoke?" card for a saved meeting the review queue has nothing left
// for (rules: SpeakerTranscriptWhoSpokePolicy). The Meetings card's "Who
// spoke?" opens it on Speakers, on top, in the same chrome as the queue's
// cards; Done saves through the same transcript path as the per-line quick
// fix, and Later closes it. Voices play from the meeting's kept audio when
// there is any. Nothing here is logged or leaves the Mac.

import Foundation
import SwiftUI
import TranscriptedCore

/// One meeting's transcript, ready for its "Who spoke?" card.
struct SpeakerTranscriptCard: Identifiable {
    let id = UUID()
    let meetingTitle: String
    let date: Date
    let transcriptURL: URL
    let lines: [HomeMeetingTranscriptLine]
    let audio: MeetingAudioAttachment?
    /// Saves the answers the way the transcript's quick fix does.
    let save: (_ assignments: [HomeMeetingSpeakerAssignment], _ completion: @escaping (Bool) -> Void) -> Void
}

/// The transcript card asked for from Meetings, if any. One at a time; it
/// lives while the Speakers page shows it.
@MainActor
final class SpeakerTranscriptWhoSpokeRequests: ObservableObject {
    static let shared = SpeakerTranscriptWhoSpokeRequests()

    @Published private(set) var card: SpeakerTranscriptCard?
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?

    static let saveFailedLine = "Couldn\u{2019}t save these names. Nothing else was changed."

    func open(_ card: SpeakerTranscriptCard) {
        self.card = card
        isSaving = false
        saveError = nil
    }

    func close() {
        card = nil
        isSaving = false
        saveError = nil
    }

    /// Done: save what changed, then close. A failed save keeps the card
    /// with its answers so it can be tried again.
    func finish(
        updates: [SpeakerReviewUpdate],
        identities: [UUID: HomeMeetingSpeakerIdentity],
        model: SpeakerPeopleSettingsViewModel
    ) {
        guard let card, !isSaving else { return }
        let assignments = SpeakerTranscriptWhoSpokePolicy.assignments(
            for: updates,
            identities: identities,
            savedNames: model.savedNamesByID,
            ownerID: model.ownerProfileID
        )
        guard !assignments.isEmpty else {
            close()
            return
        }
        isSaving = true
        saveError = nil
        let cardID = card.id
        card.save(assignments) { [weak self] didSave in
            guard let self, self.card?.id == cardID else { return }
            self.isSaving = false
            if didSave {
                self.close()
            } else {
                self.saveError = Self.saveFailedLine
            }
        }
    }
}

extension SpeakerPeopleSettingsViewModel {
    /// Saved people with a real name, by id.
    var savedNamesByID: [UUID: String] {
        Dictionary(profiles.compactMap { profile in
            SpeakerMeetingReviewPolicy.usableName(profile.displayName).map { (profile.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The saved "You", when there is one.
    var ownerProfileID: UUID? {
        profiles.first { SpeakerNameSelectionPolicy.isOwnerLabel($0.displayName ?? "") }?.id
    }

    /// The island's review input for a transcript: generic voices are asked,
    /// named ones are listed with their correction, and each row plays its
    /// own turn from the kept audio. `identities` maps row ids back to the
    /// transcript's voices for the save.
    func transcriptReviewInput(
        for card: SpeakerTranscriptCard
    ) -> (input: NotchIslandSpeakerReviewView.Input, identities: [UUID: HomeMeetingSpeakerIdentity]) {
        var identities: [UUID: HomeMeetingSpeakerIdentity] = [:]
        var clips: [UUID: NotchIslandVoiceClip] = [:]
        var asked: [SpeakerNamingEntry] = []
        var named: [SpeakerNamingEntry] = []
        for voice in SpeakerTranscriptWhoSpokePolicy.voices(in: card.lines) {
            let id = voice.identity.persistentSpeakerID ?? UUID()
            identities[id] = voice.identity
            let sample = SpeakerReviewSamplePolicy.sample(matching: voice.identity, in: card.lines, meetingDuration: nil)
            clips[id] = Self.transcriptClip(sample, channel: voice.identity.channel, audio: card.audio)
            let profile = voice.identity.persistentSpeakerID.flatMap { id in profiles.first { $0.id == id } }
            let entry = SpeakerNamingEntry(
                id: id,
                diarizerSpeakerId: voice.identity.diarizerSpeakerID ?? "0",
                channel: voice.identity.channel == .mic ? .mic : .system,
                clipURL: card.transcriptURL,
                sampleText: sample?.line.text ?? voice.quote ?? "",
                currentName: voice.asks ? nil : voice.identity.displayName,
                matchSimilarity: nil,
                callCount: profile?.callCount ?? 0,
                needsNaming: voice.asks,
                needsConfirmation: false
            )
            if voice.asks { asked.append(entry) } else { named.append(entry) }
        }
        let input = NotchIslandSpeakerReviewView.Input(
            id: card.id,
            speakers: asked,
            knownPeople: meetingReviewKnownPeople(),
            recognizedSpeakers: named,
            clips: clips
        )
        return (input, identities)
    }

    /// A voice's own turn from the meeting's kept audio: the mixed recording
    /// when its window isolates the voice, else that voice's channel.
    private static func transcriptClip(
        _ sample: SpeakerReviewSamplePolicy.Sample?,
        channel: HomeMeetingSpeakerChannel?,
        audio: MeetingAudioAttachment?
    ) -> NotchIslandVoiceClip {
        guard let sample, let audio else { return .none }
        let urls = audio.retranscriptionURLs + audio.urls
        func file(_ stem: String) -> URL? {
            urls.first { $0.deletingPathExtension().lastPathComponent == stem }
        }
        if let window = sample.mixedWindow,
           let url = file(MeetingAudioArchiveResolver.playbackStem) ?? file(MeetingAudioArchiveResolver.importedStem) {
            return .window(SpeakerRetainedAudioSample(url: url, startTime: window.startTime, duration: window.duration))
        }
        if let window = sample.channelWindow, let channel,
           let url = file(channel == .mic ? MeetingAudioArchiveResolver.microphoneStem : MeetingAudioArchiveResolver.systemStem) {
            return .window(SpeakerRetainedAudioSample(url: url, startTime: window.startTime, duration: window.duration))
        }
        return .none
    }
}
