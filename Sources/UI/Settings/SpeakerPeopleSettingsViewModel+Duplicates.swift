import SwiftUI
import AppKit
import Combine
import TranscriptedCore

extension SpeakerPeopleSettingsViewModel {
    var isMovingPeopleToNewVoiceModel: Bool {
        if case .moving = voiceprintMigrationPhase { return true }
        return false
    }

    /// The quiet line at the top of Speakers while saved people move to a new
    /// voice model, and afterwards while some of them need one confirmation.
    var voiceprintMigrationStatusLine: String? {
        switch voiceprintMigrationPhase {
        case .moving(let completed, let total?) where total > 0:
            return "Moving your saved people to the new voice model… \(completed) of \(total)"
        case .moving:
            return "Moving your saved people to the new voice model…"
        case .finished(let summary) where summary.peopleNeedingConfirmation > 0:
            let count = summary.peopleNeedingConfirmation
            let who = count == 1 ? "1 saved person needs" : "\(count) saved people need"
            return "\(who) one confirmation with the new voice model. Confirm them when a meeting asks who they are."
        case .failed:
            return "Your saved people haven't moved to the new voice model yet. Transcripted tries again the next time it opens."
        case .idle, .finished:
            return nil
        }
    }

    func playSample(for item: SpeakerPendingReviewItem) {
        if let url = item.clipURL {
            SpeakerClipPlayback.play(url)
        } else if let sample = item.retainedAudioSample {
            SpeakerClipPlayback.shared.play(sample)
        }
    }

    func openTranscript(for item: SpeakerPendingReviewItem) {
        NSWorkspace.shared.open(item.transcriptURL)
    }

    static func transcriptPaths(of items: [SpeakerPendingReviewItem]) -> Set<String> {
        Set(items.map { $0.transcriptURL.standardizedFileURL.path })
    }

    func hasPendingReview(forTranscript transcriptURL: URL) -> Bool {
        reviewQueueTranscriptPaths.contains(transcriptURL.standardizedFileURL.path)
    }

    nonisolated static func duplicateCandidates(from profiles: [SpeakerProfile]) -> [SpeakerDuplicateCandidate] {
        SpeakerDuplicateDetection.duplicateCandidates(from: profiles, similarity: SpeakerClipLibrary.cosineSimilarity)
    }
}
