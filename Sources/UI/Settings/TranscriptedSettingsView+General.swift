import SwiftUI
import TranscriptedCore

extension TranscriptedSettingsView {
    var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            GeneralSettingsHeader()

            GeneralSettingsGroup {
                GeneralToggleRow(
                    title: "Launch at login",
                    isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: { newValue in
                            updateLaunchAtLogin(newValue)
                        }
                    ),
                    help: launchAtLoginStatus,
                    info: GeneralInfo(
                        title: "Launch at login",
                        message: "When this is on, macOS opens Transcripted after you sign in, so the menu bar app and shortcuts are ready without opening it yourself."
                    ),
                    automationIdentifier: "transcripted.settings.general.launch-at-login"
                )

                GeneralToggleRow(
                    title: "Show in Dock",
                    isOn: Binding(
                        get: { showTranscriptedInDock },
                        set: { newValue in
                            showTranscriptedInDock = newValue
                            trackSettingsToggle("show_in_dock", enabled: newValue, page: .general)
                            DockVisibilityPreferences.setVisible(newValue)
                        }
                    ),
                    help: showTranscriptedInDock
                        ? "Transcripted is visible in the Dock."
                        : "Transcripted only appears in the menu bar.",
                    info: GeneralInfo(
                        title: "Show in Dock",
                        message: "Turn this off if you want Transcripted to stay out of the Dock while idle. Settings and active recordings can still bring the app forward when needed."
                    ),
                    automationIdentifier: "transcripted.settings.general.show-in-dock"
                )

                GeneralToggleRow(
                    title: "Dictation sounds",
                    isOn: Binding(
                        get: { uiSoundsEnabled },
                        set: { newValue in
                            uiSoundsEnabled = newValue
                            trackSettingsToggle("dictation_sounds", enabled: newValue, page: .general)
                            UISoundPreferences.setEnabled(newValue)
                        }
                    ),
                    help: uiSoundsEnabled
                        ? "Play sounds when dictation starts and finishes."
                        : "No dictation sounds.",
                    info: GeneralInfo(
                        title: "Dictation sounds",
                        message: "These short sounds tell you when dictation starts, finishes, or hears no speech. Turn them off if you want Transcripted to stay quiet."
                    ),
                    automationIdentifier: "transcripted.settings.general.dictation-sounds"
                )

                GeneralToggleRow(
                    title: "Clean up pasted text",
                    isOn: Binding(
                        get: { dictationCleanupEnabled },
                        set: { newValue in
                            dictationCleanupEnabled = newValue
                            DictationCleanupPreferences.setEnabled(newValue)
                            trackSettingsToggle("dictation_cleanup", enabled: newValue, page: .general)
                        }
                    ),
                    help: dictationCleanupEnabled
                        ? "Remove filler words, repeats, and spacing mistakes before pasting."
                        : "Paste the raw local transcript.",
                    info: GeneralInfo(
                        title: "Clean up pasted text",
                        message: "Transcripted lightly fixes filler words, repeated words, and spacing before it pastes your dictation. Turn this off when you want the raw transcript."
                    ),
                    automationIdentifier: "transcripted.settings.general.cleanup-pasted-text"
                )

                DictationOverlayModeRow(
                    selection: Binding(
                        get: { dictationOverlayMode },
                        set: { newValue in
                            dictationOverlayMode = newValue
                            DictationOverlayPresentationPreferences.setMode(newValue)
                            trackSettingsAction("change_dictation_overlay_mode", page: .general)
                        }
                    )
                )

                GeneralToggleRow(
                    title: "Confirm meeting quits",
                    isOn: Binding(
                        get: { confirmQuitDuringMeetingEnabled },
                        set: { newValue in
                            confirmQuitDuringMeetingEnabled = newValue
                            trackSettingsToggle("meeting_quit_confirmation", enabled: newValue, page: .general)
                            QuitConfirmationPreferences.setConfirmQuitDuringActiveMeetingRecording(newValue)
                        }
                    ),
                    help: confirmQuitDuringMeetingEnabled
                        ? "Ask before stopping a live meeting."
                        : "Quit immediately and save recoverable audio.",
                    info: GeneralInfo(
                        title: "Confirm meeting quits",
                        message: "When this is on, Transcripted asks before quitting during a live meeting so you do not stop a recording by accident."
                    ),
                    automationIdentifier: "transcripted.settings.general.confirm-meeting-quits"
                )

                GeneralToggleRow(
                    title: "Auto-detect calls",
                    isOn: Binding(
                        get: { autoDetectCallsEnabled },
                        set: { newValue in
                            autoDetectCallsEnabled = newValue
                            trackSettingsToggle("auto_call_detection", enabled: newValue, page: .general)
                            AutoCallDetectionPreferences.setEnabled(newValue)
                        }
                    ),
                    help: autoDetectCallsEnabled
                        ? "Offer to record when a call starts, even without a calendar invite."
                        : "Only detect meetings from your calendar and conferencing apps.",
                    info: GeneralInfo(
                        title: "Auto-detect calls",
                        message: "When this is on, Transcripted notices when an app or browser starts using your microphone, or when your camera turns on while a call app is active, and offers to record it. It only checks local device activity on your Mac; nothing about the audio or video ever leaves your device."
                    ),
                    automationIdentifier: "transcripted.settings.general.auto-detect-calls"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                GeneralSectionHeading(
                    title: "System",
                    info: GeneralInfo(
                        title: "System",
                        message: "Model, shortcut, and privacy settings now live here so the sidebar stays simpler."
                    )
                )

                GeneralSettingsGroup {
                    GeneralDisclosureRow(
                        title: "Transcription model",
                        value: effectiveTranscriptionModel.title,
                        isExpanded: $showGeneralModelSettings,
                        help: showGeneralModelSettings ? "Hide transcription model settings." : "Show transcription model settings.",
                        automationIdentifier: "transcripted.settings.general.disclosure.transcription-model"
                    ) {
                        trackSettingsAction("toggle_model_settings", page: .general)
                    }

                    if showGeneralModelSettings {
                        GeneralExpandedContent {
                            generalModelSettingsEditor
                        }
                    }

                    GeneralDisclosureRow(
                        title: "Keyboard shortcuts",
                        value: dictationShortcutsEnabled ? "On" : "Off",
                        isExpanded: $showGeneralShortcutSettings,
                        help: showGeneralShortcutSettings ? "Hide keyboard shortcut settings." : "Show keyboard shortcut settings.",
                        automationIdentifier: "transcripted.settings.general.disclosure.keyboard-shortcuts"
                    ) {
                        trackSettingsAction("toggle_shortcut_settings", page: .general)
                    }

                    if showGeneralShortcutSettings {
                        GeneralExpandedContent {
                            generalShortcutSettingsEditor
                        }
                    }

                    GeneralDisclosureRow(
                        title: "Privacy",
                        value: generalPrivacyStatusLine,
                        isExpanded: $showGeneralPrivacySettings,
                        help: showGeneralPrivacySettings ? "Hide privacy settings." : "Show privacy settings.",
                        automationIdentifier: "transcripted.settings.general.disclosure.privacy"
                    ) {
                        trackSettingsAction("toggle_privacy_settings", page: .general)
                    }

                    if showGeneralPrivacySettings {
                        GeneralExpandedContent {
                            generalPrivacySettingsEditor
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                GeneralSectionHeading(
                    title: "Tools",
                    info: GeneralInfo(
                        title: "Tools",
                        message: "These are occasional actions: transcribe an existing audio file, or teach Transcripted corrections for words it hears wrong."
                    )
                )

                GeneralSettingsGroup {
                    GeneralActionRow(
                        title: "Transcribe audio file",
                        value: "Choose",
                        systemImage: "waveform",
                        help: "Choose an audio file to transcribe.",
                        automationIdentifier: "transcripted.settings.general.transcribe-audio-file"
                    ) {
                        trackSettingsAction("import_recording", page: .general)
                        actions.importAudioFile()
                    }

                    GeneralDisclosureRow(
                        title: "Corrections",
                        value: customDictionaryStatusLine,
                        isExpanded: $showGeneralCorrections,
                        help: showGeneralCorrections ? "Hide correction settings." : "Show correction settings.",
                        automationIdentifier: "transcripted.settings.general.disclosure.corrections"
                    ) {
                        trackSettingsAction("toggle_corrections", page: .general)
                    }

                    if showGeneralCorrections {
                        GeneralExpandedContent {
                            generalCorrectionsEditor
                        }
                    }
                }
            }
        }
    }

    private var generalPrivacyStatusLine: String {
        if !missingRequiredPermissions.isEmpty {
            return "\(missingRequiredPermissions.count) to review"
        }
        if !CrashReporter.isAvailable && !AnalyticsReporter.isAvailable {
            return "Local only"
        }
        return "Ready"
    }

    private var generalModelSettingsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsStatusCard(
                title: "Active transcription engine",
                status: effectiveTranscriptionModel.title,
                detail: activeModelDetail,
                tone: .ready
            )

            let modelCard = FirstRunExperience.modelCard(
                for: FirstRunLocalModelState(sttRouter.modelDownloadState),
                model: effectiveTranscriptionModel
            )
            SettingsStatusCard(
                title: "Model files",
                status: modelCard.status,
                detail: modelCard.detail,
                tone: tone(for: modelCard.tone),
                progress: modelCard.progress,
                actionTitle: modelDownloadActionTitle,
                action: modelDownloadAction(page: .general)
            )

            DisclosureGroup("Change model", isExpanded: $showAdvancedModelControls) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Preferred model", selection: Binding(
                        get: { preferredTranscriptionModel },
                        set: { newValue in
                            updatePreferredTranscriptionModel(newValue, page: .general)
                        }
                    )) {
                        ForEach(TranscriptionModelChoice.allCases) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    .pickerStyle(.menu)

                    ForEach(TranscriptionModelChoice.allCases) { model in
                        ModelChoiceRow(
                            model: model,
                            isPreferred: preferredTranscriptionModel == model,
                            isEffective: effectiveTranscriptionModel == model
                        )
                    }

                    HStack {
                        SettingsInlineActionButton(title: "Use Parakeet", tone: .accent) {
                            updatePreferredTranscriptionModel(.parakeetTDTv3, page: .general)
                        }
                        .disabled(preferredTranscriptionModel == .parakeetTDTv3)
                        .help(preferredTranscriptionModel == .parakeetTDTv3
                            ? "Parakeet is already the selected transcription model."
                            : "")

                        Text("Changes apply to the next capture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var generalShortcutSettingsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggleRow(
                title: "Enable dictation shortcuts",
                detail: dictationShortcutsEnabled
                    ? "Push-to-talk and hands-free keys can start dictation."
                    : "Off. You can still start dictation from the app, and meeting controls still work.",
                isOn: Binding(
                    get: { dictationShortcutsEnabled },
                    set: { newValue in
                        dictationShortcutsEnabled = newValue
                        trackSettingsToggle("dictation_shortcuts", enabled: newValue, page: .general)
                        HotkeyPreferences.setDictationShortcutsEnabled(newValue)
                    }
                )
            )

            HotkeyRecorderContainer(dictationShortcutsEnabled: dictationShortcutsEnabled)
                .frame(height: HotkeyRecorderContainer.preferredHeight)

            if dictationShortcutsEnabled, let dictationTriggerSystemWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(dictationTriggerSystemWarning)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }

            Divider()

            SettingsToggleRow(
                title: "Send after dictation",
                detail: autoEnterEnabled
                    ? "Transcripted sends \(autoEnterKey.title) after it pastes, only in selected apps."
                    : "Off. Dictation only pastes text.",
                isOn: Binding(
                    get: { autoEnterEnabled },
                    set: { newValue in
                        autoEnterEnabled = newValue
                        trackSettingsToggle("auto_send", enabled: newValue, page: .general)
                        DictationAutoSendPreferences.setEnabled(newValue)
                    }
                )
            )

            Picker("Send key", selection: Binding(
                get: { autoEnterKey },
                set: { newValue in
                    autoEnterKey = newValue
                    trackSettingsAction("change_auto_send_key", page: .general)
                    DictationAutoSendPreferences.setSendKey(newValue)
                }
            )) {
                ForEach(DictationAutoSendKey.allCases) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!autoEnterEnabled)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Allowed apps")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    SettingsInlineActionButton(title: "Refresh") {
                        trackSettingsAction("refresh_auto_send_apps", page: .general)
                        refreshAutoEnterAppCandidates()
                    }

                    SettingsInlineActionButton(title: "Add App...", symbolName: "plus") {
                        trackSettingsAction("add_auto_send_app", page: .general)
                        chooseAutoEnterApp(page: .general)
                    }
                }

                if autoEnterAllowedBundleIDs.isEmpty {
                    Text("Add an app before Transcripted can send.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedAutoEnterAllowedBundleIDs, id: \.self) { bundleID in
                        AutoEnterAllowedAppRow(
                            title: autoEnterDisplayName(for: bundleID),
                            bundleID: bundleID
                        ) {
                            setAutoEnterApp(bundleID, isAllowed: false, page: .general)
                        }
                    }
                }
            }
            .disabled(!autoEnterEnabled)

            if !autoEnterAppCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Running apps")
                        .font(.subheadline.weight(.semibold))

                    ForEach(autoEnterAppCandidates) { app in
                        SettingsToggleRow(
                            title: app.name,
                            detail: app.bundleID,
                            isOn: Binding(
                                get: { autoEnterAllowedBundleIDs.contains(app.bundleID) },
                                set: { isAllowed in
                                    setAutoEnterApp(app.bundleID, isAllowed: isAllowed, page: .general)
                                }
                            ),
                            help: "Allow Transcripted to send \(autoEnterKey.title) after pasting into \(app.name)."
                        )
                    }
                }
                .disabled(!autoEnterEnabled)
            }
        }
    }

    private var generalPrivacySettingsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions")
                    .font(.subheadline.weight(.semibold))

                ForEach(TranscriptedPermissionKind.allCases) { kind in
                    PermissionStatusRow(kind: kind, granted: permissionStates[kind] ?? false) {
                        trackPermissionCTA(kind)
                        Task { @MainActor in
                            await TranscriptedPermissionAccess.requestAccessOrOpenSettings(for: kind)
                            refreshPermissions()
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Meeting audio")
                    .font(.subheadline.weight(.semibold))

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Meeting mic processing", selection: Binding(
                        get: { meetingMicProcessingMode },
                        set: { newValue in
                            meetingMicProcessingMode = newValue
                            trackSettingsToggle("meeting_mic_processing_\(newValue.rawValue)", enabled: true, page: .general)
                            MicrophoneProcessingPreferences.setMode(newValue)
                        }
                    )) {
                        ForEach(MicrophoneProcessingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("transcripted.settings.meeting-mic-processing")

                    Text(meetingMicProcessingMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsToggleRow(
                    title: "Identify multiple people on this Mac",
                    detail: splitLocalSpeakersEnabled
                        ? "On. After shared-room meetings, Transcripted asks you to name people captured by your mic."
                        : "Off. The local mic stays as You, which is simpler when only you are near this Mac.",
                    isOn: Binding(
                        get: { splitLocalSpeakersEnabled },
                        set: { newValue in
                            splitLocalSpeakersEnabled = newValue
                            trackSettingsToggle("local_speaker_split", enabled: newValue, page: .general)
                            LocalSpeakerPreferences.setEnabled(newValue)
                        }
                    )
                )

                Text("Changes here apply from the next recording.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Reporting")
                    .font(.subheadline.weight(.semibold))

                SettingsToggleRow(
                    title: "Send crash and error reports",
                    detail: crashReportingFootnote,
                    isOn: Binding(
                        get: { crashReportingEnabled },
                        set: { newValue in
                            crashReportingEnabled = newValue
                            trackSettingsToggle("crash_reporting", enabled: newValue, page: .general)
                            CrashReportingPreferences.setEnabled(newValue)
                            sentryTestStatus = nil
                            diagnosticsActionStatus = nil
                        }
                    )
                )
                .disabled(!CrashReporter.isAvailable)

                SettingsToggleRow(
                    title: "Send anonymous usage stats",
                    detail: analyticsFootnote,
                    isOn: Binding(
                        get: { anonymousAnalyticsEnabled },
                        set: { newValue in
                            anonymousAnalyticsEnabled = newValue
                            if newValue {
                                AnalyticsPreferences.setEnabled(true)
                                trackSettingsToggle("anonymous_analytics", enabled: true, page: .general)
                            } else {
                                trackSettingsToggle("anonymous_analytics", enabled: false, page: .general)
                                AnalyticsPreferences.setEnabled(false)
                            }
                            diagnosticsActionStatus = nil
                        }
                    )
                )
                .disabled(!AnalyticsReporter.isAvailable)

                HStack {
                SettingsInlineActionButton(
                    title: "Send Test Sentry Event",
                    tone: .warning,
                    automationIdentifier: "transcripted.settings.general.send-test-sentry-event"
                ) {
                    trackSettingsAction("send_test_sentry_event", page: .general)
                    sendTestSentryEvent()
                }
                    .disabled(!CrashReporter.isAvailable || !crashReportingEnabled)

                    if let sentryTestStatus {
                        Text(sentryTestStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Never sent: transcript text, audio, names, emails, file paths, raw URLs, or meeting titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var generalCorrectionsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add the mistake on the left and the fix on the right.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("Mistake")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Fix")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear
                        .frame(width: 28, height: 1)
                }

                ForEach(customDictionaryRows) { row in
                    CorrectionEditorRow(
                        spoken: Binding(
                            get: { row.spoken },
                            set: { updateCorrectionSpoken($0, for: row.id) }
                        ),
                        replacement: Binding(
                            get: { row.replacement },
                            set: { updateCorrectionReplacement($0, for: row.id) }
                        ),
                        onRemove: {
                            trackSettingsAction("remove_correction", page: .general)
                            removeCorrectionRow(row.id)
                        }
                    )
                }
            }

            HStack {
                Button {
                    trackSettingsAction("add_correction", page: .general)
                    addCorrectionRow()
                } label: {
                    Label("Add correction", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(SettingsHoverButtonStyle(
                    tone: .accent,
                    cornerRadius: 8,
                    normalFill: Color.accentColor.opacity(0.08),
                    normalStroke: Color.accentColor.opacity(0.16)
                ))
                .frame(minHeight: 40)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Spacer()

                SettingsInlineActionButton(
                    title: "Clear all",
                    tone: .destructive,
                    automationIdentifier: "transcripted.settings.general.corrections.clear-all"
                ) {
                    trackSettingsAction("clear_corrections", page: .general)
                    clearCorrectionRows()
                }
                .disabled(!hasCustomDictionaryContent)
                .help(hasCustomDictionaryContent ? "" : "No saved corrections to clear yet.")
            }

            DisclosureGroup("Try a phrase", isExpanded: $showCorrectionPreview) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Type a sample phrase", text: $customDictionaryPreviewInput)
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Result")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(customDictionaryPreviewOutput)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                            )
                    }
                }
                .padding(.top, 8)
            }

            DisclosureGroup("Edit as text", isExpanded: $showAdvancedCorrectionsText) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: Binding(
                        get: { customDictionaryText },
                        set: { updateCustomDictionaryText($0) }
                    ))
                    .font(.body.monospaced())
                    .frame(minHeight: 100)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                    Text("Use one per line: wrong -> right.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        let previousValue = launchAtLoginEnabled
        launchAtLoginEnabled = enabled
        trackSettingsToggle("launch_at_login", enabled: enabled, page: .general)

        do {
            try LaunchAtLoginController.setEnabled(enabled)
            refreshLaunchAtLoginState()
        } catch {
            launchAtLoginEnabled = previousValue
            launchAtLoginStatus = "Could not update launch at login: \(error.localizedDescription)"
            EventReporter.shared.capture(
                level: .warning,
                engine: "app",
                event: "launch_at_login_update_failed",
                message: error.localizedDescription
            )
        }
    }

    private var customDictionaryStatusLine: String {
        let count = CustomDictionaryPreferences.entries(from: customDictionaryText).count
        if count == 0 {
            return "No corrections yet."
        }
        return "\(count) correction\(count == 1 ? "" : "s") active."
    }

    private var hasCustomDictionaryContent: Bool {
        !customDictionaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var customDictionaryPreviewOutput: String {
        let sample = customDictionaryPreviewInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return "Type a sample phrase above to check corrections." }

        let entries = CustomDictionaryPreferences.entries(from: customDictionaryText)
        let corrected = entries.isEmpty
            ? sample
            : CustomDictionaryTextProcessor.apply(to: sample, entries: entries)

        guard dictationCleanupEnabled else { return corrected }
        return DictationFillerCleanupPolicy.clean(corrected).text
    }

    private func updateCustomDictionaryText(_ text: String) {
        let clampedText = CustomDictionaryPreferences.clampedRawText(text)
        customDictionaryText = clampedText
        CustomDictionaryPreferences.setRawText(clampedText)
        customDictionaryRows = CorrectionDraftRow.rows(from: clampedText)
    }

    private func addCorrectionRow() {
        customDictionaryRows.append(CorrectionDraftRow())
    }

    private func clearCorrectionRows() {
        customDictionaryRows = CorrectionDraftRow.rows(from: "")
        updateCustomDictionaryText("")
    }

    private func removeCorrectionRow(_ id: UUID) {
        let nextRows = customDictionaryRows.filter { $0.id != id }
        persistCorrectionRows(nextRows)
    }

    private func updateCorrectionSpoken(_ spoken: String, for id: UUID) {
        let nextRows = customDictionaryRows.map { row in
            guard row.id == id else { return row }
            if row.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return CorrectionDraftRow(id: row.id, spoken: spoken, replacement: spoken)
            }
            return CorrectionDraftRow(id: row.id, spoken: spoken, replacement: row.replacement)
        }
        persistCorrectionRows(nextRows)
    }

    private func updateCorrectionReplacement(_ replacement: String, for id: UUID) {
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
}
