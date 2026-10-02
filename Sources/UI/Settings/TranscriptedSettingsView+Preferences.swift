import AppKit
import Observation
import SwiftUI
import TranscriptedCore
import UniformTypeIdentifiers

extension TranscriptedSettingsView {
    var customDictionaryStatusLine: String {
        let count = CustomDictionaryPreferences.entries(from: customDictionaryText).count
        if count == 0 {
            return "No corrections yet."
        }
        return "\(count) correction\(count == 1 ? "" : "s") active."
    }

    var clearCorrectionsConfirmTitle: String {
        // The button is enabled for any text, even lines that don't parse,
        // so a zero count must not read as "Clear all 0 corrections?".
        let count = CustomDictionaryPreferences.entries(from: customDictionaryText).count
        switch count {
        case 0: return "Clear all corrections?"
        case 1: return "Clear 1 correction?"
        default: return "Clear all \(count) corrections?"
        }
    }

    var hasCustomDictionaryContent: Bool {
        !customDictionaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var customDictionaryPreviewOutput: String {
        let sample = customDictionaryPreviewInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return "Type a sample phrase above to check corrections." }

        let entries = CustomDictionaryPreferences.entries(from: customDictionaryText)
        let corrected = entries.isEmpty
            ? sample
            : CustomDictionaryTextProcessor.apply(to: sample, entries: entries)

        guard dictationCleanupEnabled else { return corrected }
        return DictationFillerCleanupPolicy.clean(corrected).text
    }

    /// Rows as the past-meetings line sees them. A row only offers a fix once
    /// its correction is finished (the Fix field isn't just mirroring the
    /// Mistake while it's typed) and active (not a repeat of an earlier row).
    /// When two rows hold the same correction, only the first gets the line.
    var pastMeetingsRows: [DictionaryPastMeetingsRow] {
        let active = Set(CustomDictionaryPreferences.entries(from: customDictionaryText))
        var claimed = Set<CustomDictionaryEntry>()
        return customDictionaryRows.map { row in
            let replacement = row.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            let isFinished = !replacement.isEmpty && replacement != row.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = isFinished ? row.dictionaryEntry.flatMap { active.contains($0) ? $0 : nil } : nil
            guard let entry, claimed.insert(entry).inserted else {
                return DictionaryPastMeetingsRow(id: row.id, entry: nil)
            }
            return DictionaryPastMeetingsRow(id: row.id, entry: entry)
        }
    }

    var pastMeetingsFixConfirmationScan: DictionaryPastMeetingScan? {
        pastMeetingsFixConfirmation.flatMap { pastMeetingsModel.scan(for: $0) }
    }

    /// "Also in 6 past meetings. Fix them" under a correction that still
    /// matches saved meetings, then "Fixed 6 meetings. Undo".
    @ViewBuilder
    func pastMeetingsLine(for pastRow: DictionaryPastMeetingsRow) -> some View {
        if let state = pastMeetingsModel.lineState(for: pastRow) {
            DictionaryPastMeetingsLine(
                state: state,
                isPending: pastMeetingsModel.isPending(pastRow),
                onFix: {
                    if case .found(_, _, false) = state {
                        // First fix for this correction: confirm with the count.
                        pastMeetingsFixConfirmation = pastRow
                    } else {
                        trackSettingsAction("retry_fix_past_meetings", page: .general)
                        pastMeetingsModel.fix(row: pastRow)
                    }
                },
                onUndo: {
                    trackSettingsAction("undo_fix_past_meetings", page: .general)
                    pastMeetingsModel.undo(row: pastRow)
                }
            )
            // Line up with the Fix field, clear of the remove button.
            .padding(.trailing, 52)
        }
    }

    func updateCustomDictionaryText(_ text: String) {
        let clampedText = CustomDictionaryPreferences.clampedRawText(text)
        customDictionaryText = clampedText
        CustomDictionaryPreferences.setRawText(clampedText)
        customDictionaryRows = CorrectionDraftRow.rows(from: clampedText)
    }

    func addCorrectionRow() {
        customDictionaryRows.append(CorrectionDraftRow())
    }

    func clearCorrectionRows() {
        customDictionaryRows = CorrectionDraftRow.rows(from: "")
        updateCustomDictionaryText("")
    }

    func removeCorrectionRow(_ id: UUID) {
        let nextRows = customDictionaryRows.filter { $0.id != id }
        persistCorrectionRows(nextRows)
    }

    func updateCorrectionSpoken(_ spoken: String, for id: UUID) {
        let nextRows = customDictionaryRows.map { row in
            guard row.id == id else { return row }
            // This runs per keystroke. Mirroring only while `replacement` is empty
            // freezes it at the first character typed ("okay ours" -> "o"), and
            // editing an existing vocabulary hint (where spoken == replacement)
            // diverges them on the very first keystroke ("foo" -> "foos -> foo").
            // Either way persistCorrectionRows writes a real substitution rule.
            // Keep mirroring until the user actually makes the two differ.
            if row.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || row.replacement == row.spoken {
                return CorrectionDraftRow(id: row.id, spoken: spoken, replacement: spoken)
            }
            return CorrectionDraftRow(id: row.id, spoken: spoken, replacement: row.replacement)
        }
        persistCorrectionRows(nextRows)
    }

    func updateCorrectionReplacement(_ replacement: String, for id: UUID) {
        let nextRows = customDictionaryRows.map { row in
            guard row.id == id else { return row }
            return CorrectionDraftRow(id: row.id, spoken: row.spoken, replacement: replacement)
        }
        persistCorrectionRows(nextRows)
    }

    private func persistCorrectionRows(_ rows: [CorrectionDraftRow]) {
        let normalizedRows = rows.isEmpty ? [CorrectionDraftRow()] : rows
        let rawText = CorrectionDraftRow.rawText(from: normalizedRows)
        let clampedText = CustomDictionaryPreferences.clampedRawText(rawText)
        customDictionaryRows = clampedText == rawText ? normalizedRows : CorrectionDraftRow.rows(from: clampedText)
        customDictionaryText = clampedText
        CustomDictionaryPreferences.setRawText(clampedText)
    }

    func updatePreferredTranscriptionModel(
        _ model: TranscriptionModelChoice,
        page: TranscriptedSettingsPage = .general
    ) {
        preferredTranscriptionModel = model
        trackSettingsAction("switch_model", page: page)
        TranscriptionModelPreferences.setPreferredModel(model)
    }

    func sendDiagnosticEvent() {
        guard CrashReporter.isAvailable else {
            diagnosticsActionStatus = "Diagnostics aren't available in this build. Click Email Support and tell us what happened instead."
            return
        }

        guard crashReportingEnabled else {
            diagnosticsActionStatus = "Turn on \"Crash reports\" in the Privacy section above first, then try again."
            return
        }

        guard !diagnosticEventSendInFlight else { return }
        diagnosticEventSendInFlight = true
        Task { @MainActor in
            defer { diagnosticEventSendInFlight = false }
            guard let eventID = await actions.sendDiagnosticEvent() else {
                diagnosticsActionStatus = "Diagnostics didn't send. Click Email Support and tell us what happened instead."
                return
            }

            diagnosticsActionStatus = SupportDiagnosticsStatusCopy.sent(eventID: eventID)
        }
    }

    var captureLibraryChoicePromptBinding: Binding<Bool> {
        Binding(
            get: { pendingCaptureLibraryChoice != nil },
            set: { isPresented in
                if !isPresented {
                    pendingCaptureLibraryChoice = nil
                }
            }
        )
    }

    func chooseCaptureLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Transcripted saves meeting and dictation Markdown files."
        panel.directoryURL = captureLibraryURL

        guard panel.runModal() == .OK, let url = panel.url else { return }

        selectCaptureLibrary(destination: url, preferenceURL: url, destinationKind: .custom)
    }

    func resetCaptureLibraryToDefault() {
        selectCaptureLibrary(
            destination: FileManager.default.transcriptedDefaultCaptureLibraryDir,
            preferenceURL: nil,
            destinationKind: .defaultLibrary
        )
    }

    /// Shared tail of both capture-library pickers. They differed only in the
    /// destination, whether a preference URL is written (the default library
    /// clears it), and which destination kind the migration prompt reports —
    /// and `applyCaptureLibraryChoice` takes exactly that preference URL.
    private func selectCaptureLibrary(
        destination: URL,
        preferenceURL: URL?,
        destinationKind: CaptureLibraryDestinationKind
    ) {
        guard TranscriptedStoragePreferences.prepareCaptureLibraryURL(destination) else {
            refreshStoragePaths()
            showCaptureLibrarySelectionError()
            return
        }

        let currentLibrary = FileManager.default.transcriptedCaptureLibraryDir
        let isSameFolder = destination.standardizedFileURL.path == currentLibrary.standardizedFileURL.path
        if !isSameFolder, CaptureLibraryMigrationPlanner().libraryHasCaptures(at: currentLibrary) {
            pendingCaptureLibraryChoice = PendingCaptureLibraryChoice(
                currentLibrary: currentLibrary,
                newLibrary: destination,
                preferenceURL: preferenceURL,
                destinationKind: destinationKind
            )
            return
        }

        captureLibraryMigrationStatus = nil
        applyCaptureLibraryChoice(preferenceURL)
    }

    func switchLibraryWithoutCopying(_ choice: PendingCaptureLibraryChoice) {
        captureLibraryMigrationStatus = "Existing captures stayed in \(choice.currentLibrary.path)."
        applyCaptureLibraryChoice(choice.preferenceURL)
    }

    func copyCapturesThenSwitchLibrary(_ choice: PendingCaptureLibraryChoice) {
        guard !captureLibraryMigrationInProgress else { return }
        captureLibraryMigrationInProgress = true
        captureLibraryMigrationStatus = "Copying captures..."
        captureLibraryMigrationStatusDetails = nil

        Task.detached(priority: .utility) {
            let planner = CaptureLibraryMigrationPlanner()
            let plan = planner.makePlan(from: choice.currentLibrary, to: choice.newLibrary)
            do {
                let result = try planner.copy(plan) { copied, total in
                    Task { @MainActor in
                        captureLibraryMigrationStatus = "Copying captures... \(copied) of \(total)"
                    }
                }
                await MainActor.run {
                    captureLibraryMigrationInProgress = false
                    captureLibraryMigrationStatus = captureLibraryCopySummary(result)
                    applyCaptureLibraryChoice(choice.preferenceURL)
                }
            } catch {
                await MainActor.run {
                    captureLibraryMigrationInProgress = false
                    captureLibraryMigrationStatus = SettingsActionFailureCopy.captureLibraryMigration(
                        currentLibraryPath: choice.currentLibrary.path
                    )
                    captureLibraryMigrationStatusDetails = error.localizedDescription
                }
            }
        }
    }

    /// Copy, switch, then send the copied originals to the Trash. The
    /// originals are only touched after every copy finished and the library
    /// switched, and an original that changed after its copy (a dictation
    /// landing mid-move) stays where it is.
    func moveCapturesThenSwitchLibrary(_ choice: PendingCaptureLibraryChoice) {
        guard !captureLibraryMigrationInProgress else { return }
        captureLibraryMigrationInProgress = true
        captureLibraryMigrationStatus = "Moving captures..."
        captureLibraryMigrationStatusDetails = nil
        trackSettingsAction("move_capture_library", page: .general)

        Task.detached(priority: .utility) {
            let planner = CaptureLibraryMigrationPlanner()
            let plan = planner.makePlan(from: choice.currentLibrary, to: choice.newLibrary)
            let copyResult: CaptureLibraryMigrationResult
            do {
                copyResult = try planner.copy(plan) { copied, total in
                    Task { @MainActor in
                        captureLibraryMigrationStatus = "Moving captures... \(copied) of \(total)"
                    }
                }
            } catch {
                await MainActor.run {
                    captureLibraryMigrationInProgress = false
                    captureLibraryMigrationStatus = SettingsActionFailureCopy.captureLibraryMigration(
                        currentLibraryPath: choice.currentLibrary.path
                    )
                    captureLibraryMigrationStatusDetails = error.localizedDescription
                }
                return
            }

            let switched = await MainActor.run {
                applyCaptureLibraryChoice(choice.preferenceURL)
            }
            guard switched else {
                await MainActor.run {
                    captureLibraryMigrationInProgress = false
                    captureLibraryMigrationStatus = "Copied \(copyResult.copiedCount) item\(copyResult.copiedCount == 1 ? "" : "s"), but the library didn't switch, so nothing was removed from \(choice.currentLibrary.path)."
                }
                return
            }

            let removal = planner.removeOriginals(of: copyResult.copiedItems)
            await MainActor.run {
                captureLibraryMigrationInProgress = false
                captureLibraryMigrationStatus = CaptureLibraryMoveSummary.text(
                    copy: copyResult,
                    removal: removal,
                    oldLibraryPath: choice.currentLibrary.path
                )
            }
        }
    }

    private func captureLibraryCopySummary(_ result: CaptureLibraryMigrationResult) -> String {
        var summary = "Copied \(result.copiedCount) item\(result.copiedCount == 1 ? "" : "s") to the new folder. Originals stay in the old folder."
        if result.skippedExistingCount > 0 {
            summary += " Skipped \(result.skippedExistingCount) that already existed at the destination."
        }
        return summary
    }

    @discardableResult
    private func applyCaptureLibraryChoice(_ url: URL?) -> Bool {
        guard TranscriptedStoragePreferences.setCaptureLibraryURL(url) else {
            refreshStoragePaths()
            showCaptureLibrarySelectionError()
            return false
        }
        refreshStoragePaths()
        CaptureLibraryChangeBroadcaster.shared.noteLibraryWideChange()
        AnalyticsReporter.track(
            "settings_capture_library_changed",
            properties: [
                "location_type": isUsingDefaultCaptureLibrary ? "default" : "custom",
                "page_id": TranscriptedSettingsPage.general.analyticsValue,
            ]
        )
        return true
    }

    private func showCaptureLibrarySelectionError() {
        let alert = NSAlert()
        alert.messageText = "Transcripted can't use that folder."
        alert.informativeText = "Choose a folder where Transcripted can create meeting and dictation files, or reset to the default capture library."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    var preferredDictationInputCandidates: [DictationAudioDevice] {
        availableDictationInputs
            .filter { $0.uid != nil }
            .filter { DictationInputDeviceSelectionPolicy.deviceClass(for: $0) != "bluetooth" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func refreshDictationInputCandidates() {
        availableDictationInputs = (try? CoreAudioInputDeviceLookup.availableInputDevices()) ?? []
    }

    func setAutoEnterApp(
        _ bundleID: String,
        isAllowed: Bool,
        page: TranscriptedSettingsPage = .general
    ) {
        if isAllowed {
            autoEnterAllowedBundleIDs.insert(bundleID)
        } else {
            autoEnterAllowedBundleIDs.remove(bundleID)
        }
        trackSettingsToggle("auto_send_app_allowed", enabled: isAllowed, page: page)
        DictationAutoSendPreferences.setAllowedBundleIDs(autoEnterAllowedBundleIDs)
    }

    func pageShowsAutoEnterSettings(_ page: TranscriptedSettingsPage) -> Bool {
        page == .general
    }

    func refreshAutoEnterAppCandidates() {
        autoEnterAppCandidates = AutoEnterAppCandidate.runningApps()
    }

    func refreshAutoEnterPreferences(includeCandidates: Bool) {
        autoEnterEnabled = DictationAutoSendPreferences.isEnabled()
        autoEnterKey = DictationAutoSendPreferences.sendKey()
        autoEnterAllowedBundleIDs = DictationAutoSendPreferences.allowedBundleIDs()
        if includeCandidates {
            refreshAutoEnterAppCandidates()
        }
    }

    func chooseAutoEnterApp(page: TranscriptedSettingsPage = .general) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Add"
        panel.message = "Choose an app where Transcripted may send after dictation."
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            return
        }

        setAutoEnterApp(bundleID, isAllowed: true, page: page)
        refreshAutoEnterAppCandidates()
    }

    func autoEnterDisplayName(for bundleID: String) -> String {
        AutoEnterDisplayNameResolver.resolve(
            bundleID: bundleID,
            candidateNames: autoEnterAppCandidates.map { ($0.bundleID, $0.name) },
            workspaceLookup: { id in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                    return nil
                }
                return url.deletingPathExtension().lastPathComponent
            }
        )
    }

    var settingsUpdateActionID: String {
        switch sparkleUpdater.updateStatus.state {
        case .updateAvailable:
            return "install_update"
        case .readyToInstall:
            return "restart_to_update"
        case .checking, .downloading:
            return "view_update_progress"
        case .unknown, .readyToCheck, .noUpdateAvailable:
            return "check_updates"
        }
    }

    var updateBlockedReason: UpdateBlockedReason? {
        UpdateBlockedReason.current(
            isRecording: sttRouter.isRecording
                || meetingSession.isRecording
                || meetingSession.isCaptureSessionActive,
            isTranscribing: sttRouter.isTranscribing || meetingSession.hasRuntimeDiagnosticsWork,
            isSpeakerReviewPending: meetingSession.isSpeakerReviewPending
        )
    }

    private var isCaptureActiveForUpdateSafety: Bool {
        updateBlockedReason != nil
    }

    func updateActionEnabled(for status: SparkleUpdaterController.UpdateStatus) -> Bool {
        UpdateActionSafetyPolicy.canRunUserAction(
            state: updateActionSafetyState(for: status.state),
            sparkleCanRunUserAction: status.canRunUserUpdateAction,
            availableUpdateDownloadsAutomatically: sparkleUpdater.availableUpdateDownloadsAutomatically,
            isCaptureActive: isCaptureActiveForUpdateSafety
        )
    }

    func updateActionSafetyState(
        for state: SparkleUpdaterController.UpdateStatus.State
    ) -> UpdateActionSafetyState {
        switch state {
        case .unknown:
            return .unknown
        case .readyToCheck:
            return .readyToCheck
        case .checking:
            return .checking
        case .noUpdateAvailable:
            return .noUpdateAvailable
        case .updateAvailable:
            return .updateAvailable
        case .downloading:
            return .downloading
        case .readyToInstall:
            return .readyToInstall
        }
    }
}
