import Foundation
import TranscriptedCore

extension TranscriptedSettingsView {
    func assignMeetingSpeakers(
        _ assignments: [HomeMeetingSpeakerAssignment],
        in preview: HomeMeetingPreview,
        completion: @escaping (Bool) -> Void
    ) {
        guard !assignments.isEmpty else {
            completion(true)
            return
        }
        trackSettingsAction(
            assignments.count == 1 ? "rename_meeting_speaker" : "name_meeting_speakers",
            page: .home
        )

        Task { @MainActor in
            await self.commitMeetingSpeakerAssignments(assignments, in: preview, completion: completion)
        }
    }

    @MainActor
    private func commitMeetingSpeakerAssignments(
        _ assignments: [HomeMeetingSpeakerAssignment],
        in preview: HomeMeetingPreview,
        completion: @escaping (Bool) -> Void
    ) async {
        let prepared = await enrollUnlinkedHomeSpeakers(assignments, in: preview)
        let working = prepared.assignments
        let namedTranscriptOnly = prepared.namedTranscriptOnly

        let referencedProfileIDs = Set(working.flatMap { assignment in
            [assignment.identity.persistentSpeakerID, assignment.targetProfileID].compactMap { $0 }
        })
        let availableProfileIDs = Set(referencedProfileIDs.filter {
            speakerPeopleModel.currentProfile(id: $0) != nil
        })
        guard let assignmentPlan = HomeMeetingSpeakerNamingPolicy.assignmentPlan(
            for: working,
            transcriptLines: preview.content.transcriptLines,
            availableProfileIDs: availableProfileIDs
        ) else {
            speakerPeopleModel.refresh()
            completion(false)
            return
        }
        let localAssignments = assignmentPlan.localAssignments
        let savedAssignments = assignmentPlan.savedAssignments
        guard let savedAssignmentsInCommitOrder =
            HomeMeetingSpeakerNamingPolicy.savedAssignmentsInCommitOrder(savedAssignments),
              let localAssignmentsAfterSavedMerges =
            HomeMeetingSpeakerNamingPolicy.remappingLocalTargets(
                localAssignments,
                after: savedAssignmentsInCommitOrder
            ) else {
            completion(false)
            return
        }
        let profileIDs = availableProfileIDs

        // Validate the whole saved-person plan before the first mutation. This
        // catches stale picker rows without leaving an avoidable partial batch.
        let savedProfilesAreCurrent = savedAssignmentsInCommitOrder.allSatisfy { assignment in
            guard let sourceID = assignment.identity.persistentSpeakerID,
                  profileIDs.contains(sourceID) else { return false }
            guard let targetID = assignment.targetProfileID,
                  targetID != sourceID else { return true }
            return profileIDs.contains(targetID)
        }
        let localTargetsAreCurrent = localAssignmentsAfterSavedMerges.allSatisfy {
            $0.targetProfileID.map(profileIDs.contains) ?? true
        }
        guard savedProfilesAreCurrent, localTargetsAreCurrent else {
            speakerPeopleModel.refresh()
            completion(false)
            return
        }

        var savedAssignmentCount = 0

        func finish(_ didSave: Bool) {
            // A late completion must not replace whichever meeting the user
            // opened while the persistence work was running.
            reloadExpandedMeetingPreview(preview)
            refreshRecentCaptures(force: true)
            completion(didSave)
            if didSave, namedTranscriptOnly {
                presentHomeActionFailure(
                    title: "Name saved",
                    message: HomeMeetingSpeakerNamingCopy.transcriptOnlyNoVoiceprint,
                    retryTitle: "OK",
                    retry: {},
                    playSound: false
                )
            }
        }

        func finishPartialFailure() {
            // At least one canonical mutation committed, so the old drafts are
            // no longer a safe retry surface. Close the sheet, reload persisted
            // truth, and tell the user to review the remaining voices.
            reloadExpandedMeetingPreview(preview)
            refreshRecentCaptures(force: true)
            completion(true)
            presentHomeActionFailure(
                title: "Some speaker names were saved",
                message: "Transcripted saved part of this batch but couldn't finish it. Reopen Name speakers to review what's left.",
                retryTitle: "Refresh meeting",
                retry: { reloadExpandedMeetingPreview(preview) }
            )
        }

        func applyLocalAssignments() {
            guard !localAssignmentsAfterSavedMerges.isEmpty else {
                finish(true)
                return
            }

            // Saved mutations above may have renamed or merged a selected
            // person. Read the canonical surviving name back from the refreshed
            // model before linking a formerly-unlinked transcript row.
            let resolvedLocalAssignments = localAssignmentsAfterSavedMerges.compactMap { assignment
                -> HomeMeetingSpeakerAssignment? in
                guard let targetID = assignment.targetProfileID else { return assignment }
                guard let profile = speakerPeopleModel.profiles.first(where: { $0.id == targetID }),
                      let canonicalName = profile.displayName?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !canonicalName.isEmpty else { return nil }
                return HomeMeetingSpeakerAssignment(
                    identity: assignment.identity,
                    newName: canonicalName,
                    targetProfileID: targetID
                )
            }
            guard resolvedLocalAssignments.count == localAssignmentsAfterSavedMerges.count else {
                if savedAssignmentCount > 0 {
                    finishPartialFailure()
                } else {
                    finish(false)
                }
                return
            }

            let candidateURL = preview.transcriptURL
            Task { @MainActor in
                do {
                    _ = try await Task.detached(priority: .userInitiated) {
                        // A stale path makes this list the transcripts folder,
                        // so resolve it here rather than on the main thread.
                        let transcriptURL = OwnFileResolver.resolveExistingFile(candidateURLs: [candidateURL])
                            ?? candidateURL
                        return try HomeMeetingSpeakerRename.renameMany(
                            transcriptAt: transcriptURL,
                            assignments: resolvedLocalAssignments
                        )
                    }.value
                    finish(true)
                } catch {
                    if savedAssignmentCount > 0 {
                        finishPartialFailure()
                    } else {
                        finish(false)
                    }
                }
            }
        }

        func applySavedAssignment(at index: Int) {
            guard savedAssignmentsInCommitOrder.indices.contains(index) else {
                applyLocalAssignments()
                return
            }
            let assignment = savedAssignmentsInCommitOrder[index]
            prepareSilentNameCorrections([assignment], in: preview) { properties in
                applySavedMeetingSpeakerAssignment(assignment) { didSave in
                    SpeakerSilentNameCorrectionTelemetry.track(
                        SpeakerSilentNameCorrectionTelemetry.committedProperties(properties, didSave: didSave))
                    guard didSave else {
                        if savedAssignmentCount > 0 {
                            finishPartialFailure()
                        } else {
                            finish(false)
                        }
                        return
                    }
                    savedAssignmentCount += 1
                    applySavedAssignment(at: index + 1)
                }
            }
        }

        applySavedAssignment(at: 0)
    }

    /// Re-embed unlinked Home names from retained audio before the transcript
    /// rewrite. Linked saved-person edits already have a voiceprint.
    @MainActor
    private func enrollUnlinkedHomeSpeakers(
        _ assignments: [HomeMeetingSpeakerAssignment],
        in preview: HomeMeetingPreview
    ) async -> (assignments: [HomeMeetingSpeakerAssignment], namedTranscriptOnly: Bool) {
        let audioURLs = preview.audio?.retranscriptionURLs ?? preview.audio?.urls ?? []
        let transcriptID = TranscriptFrontmatter.values(in: preview.markdown)
            .flatMap(TranscriptFrontmatter.captureID(in:))
        var working = assignments
        var namedTranscriptOnly = false

        for index in working.indices {
            let assignment = working[index]
            guard assignment.identity.persistentSpeakerID == nil else { continue }
            let outcome = await meetingSession.enrollNamedSpeakerFromTranscript(
                markdown: preview.markdown,
                audioURLs: audioURLs,
                displayName: assignment.newName,
                currentLabel: assignment.identity.displayName,
                channelRawValue: assignment.identity.channel?.rawValue,
                targetProfileID: assignment.targetProfileID,
                transcriptID: transcriptID
            )
            switch outcome {
            case .saved(let profileID):
                working[index] = HomeMeetingSpeakerVoiceprintSave.linking(assignment, to: profileID)
            case .transcriptOnly:
                if assignment.targetProfileID == nil {
                    namedTranscriptOnly = true
                }
            }
        }

        if working.contains(where: { $0.targetProfileID != nil }) {
            speakerPeopleModel.refresh()
        }
        return (working, namedTranscriptOnly)
    }

    /// Snapshot before the merge moves the match outcomes. Emission waits for
    /// that assignment's successful commit, so failed or partial batches do not
    /// count unsaved corrections (or double-count them on retry).
    private func prepareSilentNameCorrections(
        _ assignments: [HomeMeetingSpeakerAssignment],
        in preview: HomeMeetingPreview,
        completion: @escaping ([[String: String]]) -> Void
    ) {
        let corrections = HomeMeetingSpeakerNamingPolicy.silentNameCorrections(
            assignments,
            autoRecognized: HomeMeetingPreviewContent.autoRecognizedVoices(in: preview.markdown)
        )
        guard !corrections.isEmpty else {
            completion([])
            return
        }
        speakerPeopleModel.prepareSilentNameCorrections(
            transcriptId: TranscriptFrontmatter.values(in: preview.markdown).flatMap(TranscriptFrontmatter.captureID(in:)),
            voices: corrections.compactMap { correction in
                correction.identity.persistentSpeakerID.map {
                    SpeakerSilentNameCorrectionTelemetry.Voice(
                        profileID: $0,
                        channel: correction.identity.channel?.rawValue
                    )
                }
            },
            completion: completion
        )
    }

    private func applySavedMeetingSpeakerAssignment(
        _ assignment: HomeMeetingSpeakerAssignment,
        completion: @escaping (Bool) -> Void
    ) {
        guard let sourceID = assignment.identity.persistentSpeakerID,
              let source = speakerPeopleModel.currentProfile(id: sourceID) else {
            speakerPeopleModel.refresh()
            completion(false)
            return
        }

        if let targetID = assignment.targetProfileID, targetID != sourceID {
            guard let target = speakerPeopleModel.currentProfile(id: targetID) else {
                speakerPeopleModel.refresh()
                completion(false)
                return
            }
            speakerPeopleModel.merge(source: source, into: target, completion: completion)
        } else {
            speakerPeopleModel.rename(profile: source, to: assignment.newName, completion: completion)
        }
    }
}
