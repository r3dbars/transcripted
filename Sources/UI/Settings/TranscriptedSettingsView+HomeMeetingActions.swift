import AppKit
import Observation
import SwiftUI
import TranscriptedCore
import UniformTypeIdentifiers

extension TranscriptedSettingsView {
    // MARK: - Home root alert

    /// The Home surface drives two independent confirmation/failure alerts
    /// (`homeDeleteConfirmation`, `homeDeleteFailure`).
    /// They are presented through a *single* `.alert(item:)` because SwiftUI
    /// shadows all but the last when several legacy `.alert(item:)` are stacked
    /// on one view — that is what silently broke the meeting-delete confirmation.
    enum RootAlert: Identifiable {
        case deleteConfirmation(HomeDeleteConfirmation)
        case deleteFailure(HomeDeleteFailure)

        var id: String {
            switch self {
            case .deleteConfirmation(let confirmation): return "delete-confirmation-\(confirmation.id)"
            case .deleteFailure(let failure): return "delete-failure-\(failure.id)"
            }
        }
    }

    /// Snapshot of which Home alert states are currently set, fed to
    /// `HomeRootAlertPolicy` so presentation priority and dismissal stay in sync.
    private var rootAlertStates: HomeRootAlertStates {
        HomeRootAlertStates(
            hasDeleteConfirmation: homeDeleteConfirmation != nil,
            hasDeleteFailure: homeDeleteFailure != nil
        )
    }

    /// Whichever Home alert should present, in `HomeRootAlertPolicy` priority order.
    private var activeRootAlert: RootAlert? {
        switch HomeRootAlertPolicy.activeSlot(rootAlertStates) {
        case .deleteConfirmation: return homeDeleteConfirmation.map(RootAlert.deleteConfirmation)
        case .deleteFailure: return homeDeleteFailure.map(RootAlert.deleteFailure)
        case .none: return nil
        }
    }

    /// Binds the single alert presenter to the two underlying states. On
    /// dismissal it clears only the alert being dismissed, not both: a
    /// confirm action can set a follow-up alert (e.g. a delete failure) before
    /// SwiftUI writes nil, and clearing everything would wipe it before it can
    /// present. Call sites keep setting their own `@State` directly.
    var rootAlertBinding: Binding<RootAlert?> {
        Binding(
            get: { activeRootAlert },
            set: { newValue in
                guard newValue == nil else { return }
                switch activeRootAlert {
                case .deleteConfirmation: homeDeleteConfirmation = nil
                case .deleteFailure: homeDeleteFailure = nil
                case .none: break
                }
            }
        )
    }

    /// Rename lives in the row's ⋯ menu (`HomeMeetingRenameAffordance`) instead
    /// of an inline editable title: click-to-edit fired too easily while
    /// reading a transcript. Tracking stays in `renameMeetingPreview`.
    func promptRenameMeeting(_ item: RecentMeetingItem) {
        let alert = NSAlert()
        alert.messageText = HomeMeetingRenameAffordance.help
        alert.informativeText = "Renames the saved transcript and its audio."
        alert.addButton(withTitle: HomeMeetingRenameAffordance.title)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = item.title
        field.placeholderString = "Meeting title"
        field.setAccessibilityLabel("Meeting title")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn,
              let newTitle = HomeMeetingTitleEditPolicy.titleToCommit(
                  draft: field.stringValue,
                  currentTitle: item.title
              )
        else { return }

        // The expanded preview may be absent or belong to another row; the item
        // carries everything the rename needs.
        let preview = (homeExpandedMeetingPreview?.id == item.id
            ? homeExpandedMeetingPreview
            : nil) ?? HomeMeetingPreview(item: item, markdown: "")
        renameMeetingPreview(preview, to: newTitle)
    }

    private func renameMeetingPreview(_ preview: HomeMeetingPreview, to rawTitle: String) {
        trackSettingsAction("rename_recent_meeting", page: .home)

        let sourceURL = preview.transcriptURL
        let attachmentID = preview.audio?.id

        let renameTask = Task.detached(priority: .userInitiated) { () throws -> HomeMeetingRenameResult in
            if let attachmentID {
                await MainActor.run {
                    MeetingAudioPlayback.shared.stopIfActive(attachmentIDs: [attachmentID])
                }
            }
            return try HomeMeetingRename.rename(transcriptAt: sourceURL, to: rawTitle)
        }

        Task { @MainActor in
            do {
                let result = try await renameTask.value
                let audio = MeetingAudioArchiveResolver.attachment(forTranscript: result.transcriptURL)
                if homeExpandedMeetingID == preview.id || homeExpandedMeetingPreview?.id == preview.id {
                    // Base the update on the loaded preview when it arrived
                    // meanwhile (keeps the transcript body); fall back to the
                    // rename's own preview otherwise.
                    let base = (homeExpandedMeetingPreview?.id == preview.id
                        ? homeExpandedMeetingPreview
                        : nil) ?? preview
                    homeExpandedMeetingPreview = base.updatingAfterRename(
                        transcriptURL: result.transcriptURL,
                        title: result.title,
                        audio: audio
                    )
                    // The expansion is keyed by the row id (transcript path),
                    // which the rename just changed — follow it so the card
                    // stays open on the renamed capture after refresh.
                    homeExpandedMeetingID = result.transcriptURL.path
                }
                refreshRecentCaptures(force: true)
            } catch HomeMeetingRenameError.emptyTitle {
                // Empty title is treated as a cancelled edit — leave everything untouched.
            } catch HomeMeetingRenameError.artifactRecoveryRequired(let notice) {
                refreshRecentCaptures(force: true)
                presentMeetingArtifactRecovery([notice])
            } catch {
                refreshRecentCaptures(force: true)
                presentHomeDeleteFailure(
                    title: "Could not rename meeting",
                    error: error,
                    retry: {
                        renameMeetingPreview(preview, to: rawTitle)
                    }
                )
            }
        }
    }

    /// Applies the staged inline/batch picker result. Transcript-local rows are
    /// rewritten together in one file write; saved identities continue through
    /// the canonical transactional global rename/merge service.
    var homeKnownPeopleOptions: [SpeakerIdentityOption] {
        SpeakerNameSuggestionSource.options(from: speakerPeopleModel.profiles, excluding: nil)
    }

    var homeSavedSpeakerIDs: Set<UUID> {
        Set(speakerPeopleModel.profiles.map(\.id))
    }

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

        let referencedProfileIDs = Set(assignments.flatMap { assignment in
            [assignment.identity.persistentSpeakerID, assignment.targetProfileID].compactMap { $0 }
        })
        let availableProfileIDs = Set(referencedProfileIDs.filter {
            speakerPeopleModel.currentProfile(id: $0) != nil
        })
        guard let assignmentPlan = HomeMeetingSpeakerNamingPolicy.assignmentPlan(
            for: assignments,
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

            let transcriptURL = OwnFileResolver.resolveExistingFile(candidateURLs: [preview.transcriptURL])
                ?? preview.transcriptURL
            Task { @MainActor in
                do {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try HomeMeetingSpeakerRename.renameMany(
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
            applySavedMeetingSpeakerAssignment(savedAssignmentsInCommitOrder[index]) { didSave in
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

        applySavedAssignment(at: 0)
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

    private func reloadExpandedMeetingPreview(_ preview: HomeMeetingPreview) {
        // A rename can finish after the user has collapsed this meeting or
        // opened another one. Do not cancel that newer preview's load task.
        guard homeExpandedMeetingPreview?.id == preview.id else { return }
        homeMeetingPreviewLoadTask?.cancel()
        homeMeetingPreviewLoadTask = Task { @MainActor in
            let readResult = await Self.readMeetingMarkdown(at: preview.transcriptURL)
            guard !Task.isCancelled,
                  homeExpandedMeetingPreview?.id == preview.id else { return }
            switch readResult {
            case .success(let markdown, let content):
                homeExpandedMeetingPreview = preview.updatingMarkdown(markdown, content: content)
            case .failure(let message):
                homeExpandedMeetingPreview = preview.updatingMarkdown("", readError: message)
            }
        }
    }

    func failedMeetingAudioAttachment(
        for item: MeetingSessionController.FailedMeetingItem
    ) -> MeetingAudioAttachment? {
        MeetingAudioAttachment.retainedAudio(urls: item.audioURLs)
    }

    func revealFailedMeetingAudio(_ item: MeetingSessionController.FailedMeetingItem) {
        revealOwnFile(
            candidateURLs: HomeMeetingRowActionTargets.audioRevealURLs(audioURLs: item.audioURLs),
            failureTitle: "Could not show audio",
            failureMessage: "Transcripted couldn't find this meeting's audio on disk. It may have been moved or already deleted."
        )
    }

    func requestClearFailedMeeting(_ item: MeetingSessionController.FailedMeetingItem) {
        trackSettingsAction("home_delete_failed_meeting_request", page: .home)
        let presentation = HomeDeleteConfirmationPolicy.failedMeeting
        homeDeleteConfirmation = HomeDeleteConfirmation(
            title: presentation.title,
            message: presentation.message,
            confirmTitle: presentation.confirmTitle
        ) {
            trackSettingsAction("home_delete_failed_meeting_confirm", page: .home)
            clearFailedMeeting(item)
        }
    }

    private func clearFailedMeeting(_ item: MeetingSessionController.FailedMeetingItem) {
        if let audio = failedMeetingAudioAttachment(for: item),
           MeetingAudioPlayback.shared.isActive(audio) {
            MeetingAudioPlayback.shared.stop()
        }

        let didClear = meetingSession.deleteFailedMeeting(id: item.id)

        if !didClear {
            presentHomeActionFailure(
                title: "Could not delete failed meeting",
                message: "Transcripted couldn't remove this meeting. Check that your capture folder is available, then try again.",
                retry: {
                    clearFailedMeeting(item)
                }
            )
        } else {
            ActivationTelemetry.trackWorkflowAbandoned(
                workflowKind: .failedMeetingRetry,
                stage: "retry_available",
                reasonKind: .deleted,
                surface: .home,
                priorReadyState: canRetryFailedMeetings ? "retry_ready" : "retry_blocked"
            )
        }
    }

    /// Reveals an app-owned capture artifact in Finder, tolerant to the file
    /// having moved since the row was scanned (transcript restyle/rename,
    /// WAV→M4A audio recompression). Never silently no-ops: if nothing on disk
    /// can be revealed it surfaces a failure alert instead of a dead click.
    @discardableResult
    func revealOwnFile(
        candidateURLs: [URL],
        failureTitle: String,
        failureMessage: String
    ) -> Bool {
        switch OwnFileResolver.resolveForReveal(candidateURLs: candidateURLs) {
        case .reveal(let urls):
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return true
        case .unavailable:
            presentHomeActionFailure(
                title: failureTitle,
                message: failureMessage,
                retry: {
                    revealOwnFile(
                        candidateURLs: candidateURLs,
                        failureTitle: failureTitle,
                        failureMessage: failureMessage
                    )
                }
            )
            return false
        }
    }

    /// Opens an app-owned capture artifact, tolerant to a stem-only rename
    /// (e.g. WAV→M4A) since the row was scanned. Requires a real file — it will
    /// not open an enclosing folder — and surfaces a failure alert instead of a
    /// silent no-op when nothing on disk backs the URL.
    @discardableResult
    func openOwnFile(
        candidateURLs: [URL],
        failureTitle: String,
        failureMessage: String,
        onComplete: @escaping (Bool) -> Void = { _ in }
    ) -> Bool {
        guard let url = OwnFileResolver.resolveExistingFile(candidateURLs: candidateURLs) else {
            presentHomeActionFailure(
                title: failureTitle,
                message: failureMessage,
                retry: {
                    _ = openOwnFile(
                        candidateURLs: candidateURLs,
                        failureTitle: failureTitle,
                        failureMessage: failureMessage,
                        onComplete: onComplete
                    )
                }
            )
            onComplete(false)
            return false
        }
        let didOpen = NSWorkspace.shared.open(url)
        onComplete(didOpen)
        return didOpen
    }

    func presentHomeDeleteFailure(
        title: String,
        error: Error,
        retry: @escaping () -> Void
    ) {
        presentHomeActionFailure(
            title: title,
            message: HomeActionFailureCopy.message(forFailureTitle: title),
            details: error.localizedDescription,
            retry: retry
        )
    }

    func handleMeetingArtifactRecoveryAlert(_ alert: MeetingArtifactRecoveryAlert) {
        // Consume before opening the modal so the explicit startup path and the
        // publisher path cannot present the same recovery state twice.
        meetingSession.clearArtifactRecoveryAlert(alert)
        switch alert {
        case .artifacts(let notices):
            presentMeetingArtifactRecovery(notices)
        case .journalUnavailable(let directory):
            presentMeetingArtifactJournalRecovery(directory)
        }
    }

    private func presentMeetingArtifactRecovery(_ notices: [MeetingArtifactRecoveryNotice]) {
        let candidateURLs = notices.flatMap { notice in
            [
                notice.sourceTranscriptURL,
                notice.targetTranscriptURL,
                MeetingArtifactRenamer.audioDirectoryURL(for: notice.sourceTranscriptURL),
                MeetingArtifactRenamer.audioDirectoryURL(for: notice.targetTranscriptURL),
            ]
        }
        let uniqueCandidateURLs = candidateURLs.reduce(into: [URL]()) { result, url in
            guard !result.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else {
                return
            }
            result.append(url)
        }
        let count = notices.count
        presentHomeActionFailure(
            title: count == 1 ? "Meeting files need attention" : "\(count) meetings need attention",
            message: count == 1
                ? "Transcripted could not safely keep this meeting's transcript and audio together. Keep the highlighted items and avoid renaming this meeting again."
                : "Transcripted could not safely keep these meetings' transcripts and audio together. Keep the highlighted items and avoid renaming these meetings again.",
            retryTitle: "Show files",
            retry: {
                let existingURLs = uniqueCandidateURLs.filter {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                let fallbackURL = notices.first?.sourceTranscriptURL.deletingLastPathComponent()
                    ?? MeetingStoragePaths.transcriptsFolder
                NSWorkspace.shared.activateFileViewerSelecting(
                    existingURLs.isEmpty ? [fallbackURL] : existingURLs
                )
            }
        )
    }

    private func presentMeetingArtifactJournalRecovery(_ directory: URL) {
        presentHomeActionFailure(
            title: "Meeting recovery needs attention",
            message: "Transcripted could not read a meeting recovery record, so it left your transcript and audio files unchanged. Avoid renaming saved meetings until this is resolved.",
            retryTitle: "Show files",
            retry: {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
        )
    }

    func presentHomeActionFailure(
        title: String,
        message: String,
        details: String? = nil,
        retryTitle: String = HomeActionFailureCopy.retryTitle,
        retry: @escaping () -> Void
    ) {
        NSSound.beep()
        // Defer to the next runloop turn so a failure raised synchronously inside
        // an alert's confirm action lands after that alert finishes dismissing.
        // SwiftUI won't present a second alert during the first one's dismissal,
        // and the shared binding clears the dismissed alert on the same turn.
        DispatchQueue.main.async {
            homeDeleteFailure = HomeDeleteFailure(
                title: title,
                message: message,
                retryTitle: retryTitle,
                details: details,
                retry: retry
            )
        }
    }

    func copyHomeFailureDetails(_ details: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(details, forType: .string)
    }

    /// Subtle "Copy Details" reveal shown under a failed settings-action status
    /// line. The raw error lives here, never inline in the status message; the
    /// action's own button (Set up / Remove / toggle) is the retry.
    @ViewBuilder
    func settingsFailureDetailsButton(_ details: String?) -> some View {
        if let details {
            Button(SettingsActionFailureCopy.detailsTitle) {
                copyHomeFailureDetails(details)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    func retryFailedMeeting(_ item: MeetingSessionController.FailedMeetingItem) {
        let didStart = meetingSession.retryFailedMeeting(id: item.id)
        if !didStart {
            presentHomeActionFailure(
                title: "Could not retry meeting",
                message: failedMeetingRetryUnavailableReason
                    ?? "Transcripted could not start that retry. The saved audio may already be cleared.",
                retry: {
                    retryFailedMeeting(item)
                }
            )
        }
    }

    var homeAttentionIssues: [HomeAttentionIssue] {
        var issues: [HomeAttentionIssue] = []

        if !missingRequiredPermissions.isEmpty {
            issues.append(
                HomeAttentionIssue(
                    id: "permissions",
                    title: "Permissions need attention",
                    detail: permissionsDetailLine,
                    tone: .warning,
                    destination: .privacy
                )
            )
        }

        if !meetingSession.failedMeetings.isEmpty {
            let summary = HomeFailedMeetingInlinePresentation.attentionSummary(
                failureKinds: meetingSession.failedMeetings.map(\.failureKind)
            )
            issues.append(
                HomeAttentionIssue(
                    id: "failed-meetings",
                    title: summary.title,
                    detail: summary.detail,
                    tone: summary.onlySpeakerNamesMissing ? .warning : .failure,
                    destination: .failedMeetings
                )
            )
        }

        let reviewCount = speakerPeopleModel.reviewStack.voiceCount
        if reviewCount > 0 {
            issues.append(
                HomeAttentionIssue(
                    id: "speakers",
                    title: reviewCount == 1 ? "1 speaker needs a name" : "\(reviewCount) speakers need names",
                    detail: "Name saved speaker labels so transcripts read like a conversation.",
                    tone: .warning,
                    destination: .speakers
                )
            )
        }

        let modelCard = FirstRunExperience.modelCard(
            for: sttRouter.modelDownloadState,
            model: effectiveTranscriptionModel,
            isLocallyInstalled: isLocalModelInstalled(effectiveTranscriptionModel)
        )
        if modelCard.tone == .failed {
            issues.append(
                HomeAttentionIssue(
                    id: "voice-model-failed",
                    title: "Voice model needs attention",
                    detail: modelCard.detail,
                    tone: .warning,
                    destination: .models
                )
            )
        }

        return issues
    }

    var homeMeetingDaySections: [HomeDaySection<HomeMeetingListItem>] {
        let query = homeMeetingSearchQuery
        // While searching, rows come from the full-library search. Until its
        // first pass lands, filter the loaded slice so typing feels instant.
        // Either way the current query is re-applied, so a pass that finished
        // for an older query never shows rows that don't match.
        let searchResults = HomeMeetingSearchPaging.isActive(query: query)
            ? homeViewModel.meetingSearchResults
            : nil
        let savedSource = searchResults
            ?? homeViewModel.meetingDaySections.flatMap { $0.items }
        let savedMeetings = savedSource
            .filter { HomeMeetingListFilter.matches(query: query, in: HomeMeetingListFilter.searchFields(for: $0)) }
            .map(HomeMeetingListItem.saved)
        let failedMeetings = meetingSession.failedMeetings
            .filter { HomeMeetingListFilter.matches(query: query, in: Self.searchFields(for: $0)) }
            .map(HomeMeetingListItem.failed)
        let items = (savedMeetings + failedMeetings)
            .sorted { $0.date > $1.date }

        return HomeViewModel.groupByDay(items, dateForItem: \.date)
    }

    private static func searchFields(for meeting: MeetingSessionController.FailedMeetingItem) -> [String] {
        [
            meeting.title,
            meeting.detail,
            meeting.meta,
            HomeMeetingListFilter.dateSearchText(for: meeting.timestamp)
        ]
    }

    var canRetryFailedMeetings: Bool {
        failedMeetingRetryUnavailableReason == nil
    }

    func hasSpeakerReviewWork(for meeting: RecentMeetingItem) -> Bool {
        guard speakerPeopleModel.hasLoadedProfiles else {
            return meeting.speakerStatus.needsReview
        }
        return speakerPeopleModel.hasPendingReview(forTranscript: meeting.transcriptURL)
    }

    var failedMeetingRetryUnavailableReason: String? {
        if sttRouter.isRecording || sttRouter.isTranscribing {
            return "Wait for the current dictation to finish before retrying a failed meeting."
        }
        if meetingSession.isRecording {
            return "Stop the current recording before retrying a failed meeting."
        }
        if meetingSession.hasRuntimeDiagnosticsWork {
            return "Wait for the current meeting to finish saving or transcribing before retrying."
        }
        if meetingSession.isSpeakerReviewPending {
            return "Finish the speaker review window before retrying a failed meeting."
        }
        return nil
    }

    var savedMeetingRetranscriptionUnavailableReason: String? {
        SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
            isDictationActive: sttRouter.isRecording || sttRouter.isTranscribing,
            isMeetingRecording: meetingSession.isRecording,
            isPreparingModels: meetingSession.state == .loadingModels,
            hasMeetingWork: meetingSession.hasRuntimeDiagnosticsWork
        )
    }
}
