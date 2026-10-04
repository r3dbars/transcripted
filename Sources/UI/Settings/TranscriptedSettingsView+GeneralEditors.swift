import AppKit
import Observation
import SwiftUI
import TranscriptedCore
import UniformTypeIdentifiers

extension TranscriptedSettingsView {
    var generalPage: some View {
        GeneralSettingsPage(
            launchAtLoginEnabled: Binding(
                get: { launchAtLogin.isEnabled },
                set: { updateLaunchAtLogin($0) }
            ),
            launchAtLoginStatus: launchAtLogin.statusDescription,
            launchAtLoginNotice: LaunchAtLoginNoticePolicy.notice(
                needsApproval: launchAtLogin.needsApproval,
                failureMessage: launchAtLoginFailureMessage
            ),
            onOpenLoginItems: {
                trackSettingsAction("open_login_items", page: .general)
                LaunchAtLoginController.openLoginItemsSettings()
            },
            showTranscriptedInDock: persistedSettingsBinding(
                $showTranscriptedInDock,
                persist: { DockVisibilityPreferences.setVisible($0) },
                track: { trackSettingsToggle("show_in_dock", enabled: $0, page: .general) }
            ),
            uiSoundsEnabled: persistedSettingsBinding(
                $uiSoundsEnabled,
                persist: { UISoundPreferences.setEnabled($0) },
                track: { trackSettingsToggle("dictation_sounds", enabled: $0, page: .general) }
            ),
            dictationCleanupEnabled: persistedSettingsBinding(
                $dictationCleanupEnabled,
                persist: { DictationCleanupPreferences.setEnabled($0) },
                track: { trackSettingsToggle("dictation_cleanup", enabled: $0, page: .general) }
            ),
            dictationMuffleEnabled: persistedSettingsBinding(
                $dictationMuffleEnabled,
                persist: { DictationMufflePreferences.setEnabled($0) },
                track: { trackSettingsToggle("dictation_muffle", enabled: $0, page: .general) },
                sideEffect: { Self.dictationMuffleSettingChanged($0) }
            ),
            autoDetectCallsEnabled: persistedSettingsBinding(
                $autoDetectCallsEnabled,
                persist: { AutoCallDetectionPreferences.setEnabled($0) },
                track: { trackSettingsToggle("auto_call_detection", enabled: $0, page: .general) }
            ),
            correctionsStatusLine: customDictionaryStatusLine,
            onTrackAction: { actionID in
                trackSettingsAction(actionID, page: .general)
            },
            onImportAudioFile: {
                trackSettingsAction("import_recording", page: .general)
                actions.importAudioFile()
            },
            onEditCorrections: { showCorrectionsSheet = true },
            shortcutEditor: { generalShortcutSettingsEditor },
            bluetoothMicEditor: { generalBluetoothMicEditor },
            autoSendEditor: { generalAutoSendEditor },
            speakerEditor: { generalSpeakerMatchingEditor },
            modelEditor: { generalModelSettingsEditor },
            micProcessingEditor: {
                VStack(alignment: .leading, spacing: 0) {
                    // With the Mac mic recorder on, the one Microphone choice
                    // above covers meetings too, including the macOS input.
                    if microphoneSettingsRows.showsMeetingMacInputToggle {
                        MeetingMicrophoneSettingRow(usesSystemInput: persistedSettingsBinding(
                            $useSystemMeetingMicrophone,
                            persist: { MeetingMicrophonePreferences.setUsesSystemInput($0) }
                        ))
                    }
                    generalMicProcessingEditor
                }
            },
            permissionsEditor: { generalPermissionsEditor },
            reportingEditor: { generalReportingEditor }
        )
        .sheet(isPresented: $showCorrectionsSheet) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Corrections")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button("Done") { showCorrectionsSheet = false }
                        .keyboardShortcut(.defaultAction)
                }
                ScrollView {
                    generalCorrectionsEditor
                        .padding(.bottom, 8)
                }
            }
            .padding(20)
            .frame(width: 560, height: 480)
        }
    }

    private var generalModelSettingsEditor: some View {
        let modelCard = FirstRunExperience.modelCard(
            for: sttRouter.modelDownloadState,
            model: effectiveTranscriptionModel,
            isLocallyInstalled: isLocalModelInstalled(effectiveTranscriptionModel)
        )
        return VStack(alignment: .leading, spacing: 0) {
            SettingsControlRow(
                title: "Model",
                info: GeneralInfo(
                    title: "Model",
                    message: "All models run on this Mac. Parakeet V3 is the multilingual default; Parakeet V2 is English-only; Whisper adds broader language coverage; Apple Speech uses the engine built into macOS. Captures keep the model they started with. Overlapping captures on the same engine share that model until they finish."
                ),
                automationIdentifier: "transcripted.settings.general.model"
            ) {
                Picker("Model", selection: Binding(
                    get: { preferredTranscriptionModel },
                    set: { updatePreferredTranscriptionModel($0, page: .general) }
                )) {
                    ForEach(visibleTranscriptionModelChoices) { model in
                        Text(model.title).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            MeetingLanguageSettingRow(
                model: preferredTranscriptionModel,
                appleLanguageDownload: sttRouter.appleSpeechLanguageDownload,
                onLanguageChange: { sttRouter.prefetchAppleSpeechMeetingLanguage() }
            )

            // Only surface model-file state when something needs attention or
            // is in flight; a healthy ready state stays quiet.
            if modelCard.tone != .ready || modelCard.progress != nil {
                SettingsStatusCard(
                    title: "Model files",
                    status: modelCard.status,
                    detail: modelCard.detail,
                    tone: tone(for: modelCard.tone),
                    progress: modelCard.progress,
                    actionTitle: modelDownloadActionTitle,
                    action: modelDownloadAction(page: .general)
                )
                .padding(14)
            }
        }
    }

    // Speaker matching: who's-who behavior for meetings. Outcome-framed (no
    // model jargon). "Better matching on calls" is the ReDimNet2 voiceprint, on by
    // default since the voiceprint bake-off; off is the previous WeSpeaker model.
    // Gated on the model actually being available; switching is non-destructive
    // (each model keeps its own speaker memory) with a one-time confirmation.
    private var generalSpeakerMatchingEditor: some View {
        let modelAvailable = SpeakerEmbedderFactory.reDimNet2ModelURL() != nil
        let namedCount = speakerPeopleModel.profiles.filter { $0.displayName != nil }.count
        return VStack(alignment: .leading, spacing: 0) {
            GeneralToggleRow(
                title: "People in the room",
                isOn: persistedSettingsBinding(
                    $splitLocalSpeakersEnabled,
                    persist: { LocalSpeakerPreferences.setEnabled($0) },
                    track: { trackSettingsToggle("local_speaker_split", enabled: $0, page: .general) }
                ),
                help: splitLocalSpeakersEnabled ? "Name voices sharing this Mac's mic." : "Your mic stays labeled You.",
                info: GeneralInfo(
                    title: "People in the room",
                    message: "After shared-room meetings, asks you to name the voices your mic captured. Off keeps your mic labeled \"You\" — simpler when it's just you. Applies when the meeting is transcribed."
                ),
                automationIdentifier: "transcripted.settings.general.people-in-room"
            )

            GeneralToggleRow(
                title: "Better matching on calls",
                isOn: Binding(
                    get: { modelAvailable && preferredSpeakerEmbedder == .reDimNet2 },
                    set: { wantOn in
                        if !wantOn && namedCount > 0 {
                            showSpeakerEmbedderSwitchConfirm = true
                        } else {
                            applySpeakerEmbedder(wantOn ? .reDimNet2 : .weSpeaker)
                        }
                    }
                ),
                help: modelAvailable ? "Recognizes more people on Zoom, Meet, and phone audio. Changes take effect after you restart Transcripted." : "Not available in this build.",
                info: GeneralInfo(
                    title: "Better matching on calls",
                    message: "Uses a newer voice model that tells people apart more reliably on call audio. Your saved people carry over when it turns on. Turning it off goes back to the previous model with your people as they were. Changes take effect after you restart Transcripted."
                ),
                automationIdentifier: "transcripted.settings.general.call-matching",
                showsDivider: false
            )
            .disabled(!modelAvailable)
            .alert("Turn off better matching on calls?", isPresented: $showSpeakerEmbedderSwitchConfirm) {
                Button("Turn Off") { applySpeakerEmbedder(.weSpeaker) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Transcripted goes back to the previous voice model and your people as they were before the switch. Anyone you named since stays saved with the new model and comes back if you turn this on again. Takes effect after you restart Transcripted.")
            }
        }
    }

    private func applySpeakerEmbedder(_ choice: SpeakerEmbedderChoice) {
        preferredSpeakerEmbedder = choice
        SpeakerEmbedderPreferences.setPreferredChoice(choice)
    }

    private var generalShortcutSettingsEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeneralToggleRow(
                title: "Keyboard shortcuts",
                isOn: persistedSettingsBinding(
                    $dictationShortcutsEnabled,
                    persist: { HotkeyPreferences.setDictationShortcutsEnabled($0) },
                    track: { trackSettingsToggle("dictation_shortcuts", enabled: $0, page: .general) }
                ),
                help: dictationShortcutsEnabled ? "Shortcut keys can start dictation." : "Start dictation from the app only.",
                info: GeneralInfo(
                    title: "Keyboard shortcuts",
                    message: "Push-to-talk and hands-free keys can start dictation. Off still lets you start from the app, and meeting controls keep working."
                ),
                automationIdentifier: "transcripted.settings.general.keyboard-shortcuts"
            )

            HotkeyRecorderContainer(dictationShortcutsEnabled: dictationShortcutsEnabled)
                .frame(height: HotkeyRecorderContainer.preferredHeight)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            if dictationShortcutsEnabled, let dictationTriggerSystemWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(dictationTriggerSystemWarning)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Open Keyboard Settings") {
                            trackSettingsAction("open_keyboard_settings", page: .general)
                            PhysicalDictationTriggerPreferences.openKeyboardSettings()
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("transcripted.settings.general.keyboard-shortcuts.open-keyboard-settings")
                    }
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }

    /// Which mic rows show; the rules live in `MicrophoneSettingsPolicy`.
    private var microphoneSettingsRows: MicrophoneSettingsRows {
        MicrophoneSettingsPolicy.rows(
            recorderOn: pinnedMicrophoneRecorderOn,
            usesAppleVoiceProcessing: meetingMicProcessingMode.usesAppleVoiceProcessing
        )
    }

    @ViewBuilder
    private var generalBluetoothMicEditor: some View {
        let rows = microphoneSettingsRows
        if rows.showsMicrophoneChoicePicker {
            VStack(alignment: .leading, spacing: 0) {
                generalMicrophoneChoiceEditor
                // Apple voice processing keeps dictation off the recorder, so
                // this toggle's Mac-wide switch is still what keeps it off
                // AirPods (`DictationPersistentInputPreferences.recorderReplacesToggle`).
                if rows.showsFasterBluetoothDictationToggle {
                    Divider()
                    generalFasterBluetoothDictationToggle
                }
            }
        } else {
            generalFasterBluetoothDictationEditor
        }
    }

    /// The one mic setting for dictation and meetings, shown while the Mac
    /// mic recorder is on. It replaces Faster Bluetooth dictation, its mic
    /// picker, and meetings' "Use Mac-selected microphone".
    private var generalMicrophoneChoiceEditor: some View {
        SettingsControlRow(
            title: "Microphone",
            info: GeneralInfo(
                title: "Microphone",
                message: "Used for dictation and meetings. Automatic records the mic selected in macOS Sound settings, except AirPods and other Bluetooth headsets: it records your Mac's own mic instead, so your AirPods keep playing clean audio. Pick a mic to record that one whenever it's connected. \"Same as macOS Sound settings\" records AirPods too, in lower call quality. With Apple voice processing (Mic processing), dictation follows macOS Sound settings instead, unless Faster Bluetooth dictation is on. Applies to the next recording."
            ),
            automationIdentifier: "transcripted.settings.general.microphone",
            showsDivider: false
        ) {
            HStack(spacing: 8) {
                Picker("Microphone", selection: persistedSettingsBinding(
                    $microphoneChoice,
                    persist: { MicrophoneChoicePreferences.setChoice($0) },
                    track: { trackSettingsAction("change_microphone_choice_\($0.analyticsValue)", page: .general) },
                    sideEffect: { preferredDictationInputUID = $0.deviceUID ?? preferredDictationInputUID }
                )) {
                    let options = MicrophoneSettingsPolicy.pickerOptions(
                        candidates: preferredDictationInputCandidates.map { (uid: $0.uid, name: $0.name) },
                        selection: microphoneChoice
                    )
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        switch option {
                        case .automatic:
                            Text("Automatic").tag(MicrophoneChoice.automatic)
                        case let .device(uid, name):
                            Text(name).tag(MicrophoneChoice.device(uid: uid))
                        case let .savedDeviceNotConnected(uid):
                            Text("Saved mic (not connected)").tag(MicrophoneChoice.device(uid: uid))
                        case .divider:
                            Divider()
                        case .macOSInput:
                            Text("Same as macOS Sound settings").tag(MicrophoneChoice.macOSInput)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                SettingsInlineActionButton(title: "Refresh", symbolName: "arrow.clockwise") {
                    trackSettingsAction("refresh_dictation_microphones", page: .general)
                    refreshDictationInputCandidates()
                }
            }
        }
    }

    private var generalFasterBluetoothDictationToggle: some View {
        GeneralToggleRow(
            title: "Faster Bluetooth dictation",
            isOn: persistedSettingsBinding(
                $keepRecommendedMicrophoneActive,
                persist: { DictationPersistentInputPreferences.setEnabled($0) },
                track: { trackSettingsToggle("keep_recommended_microphone_active", enabled: $0, page: .general) }
            ),
            help: keepRecommendedMicrophoneActive ? "Preferred mic stays selected Mac-wide." : "macOS picks the mic per dictation.",
            info: GeneralInfo(
                title: "Faster Bluetooth dictation",
                message: "Keeps your preferred microphone selected Mac-wide while Transcripted is open, so Bluetooth dictation starts instantly. It never records while idle."
            ),
            automationIdentifier: "transcripted.settings.general.bluetooth-dictation"
        )
    }

    private var generalFasterBluetoothDictationEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            generalFasterBluetoothDictationToggle

            SettingsControlRow(
                title: "Microphone",
                info: GeneralInfo(
                    title: "Microphone",
                    message: "Used while Faster Bluetooth dictation is on. Automatic picks the best non-Bluetooth microphone."
                ),
                showsDivider: false
            ) {
                HStack(spacing: 8) {
                    Picker("Microphone", selection: persistedSettingsBinding(
                        $preferredDictationInputUID,
                        persist: { DictationPersistentInputPreferences.setPreferredDeviceUID($0) },
                        track: { _ in trackSettingsAction("change_preferred_dictation_microphone", page: .general) }
                    )) {
                        Text("Automatic").tag(String?.none)
                        ForEach(preferredDictationInputCandidates, id: \.id) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(!keepRecommendedMicrophoneActive)

                    SettingsInlineActionButton(title: "Refresh", symbolName: "arrow.clockwise") {
                        trackSettingsAction("refresh_dictation_microphones", page: .general)
                        refreshDictationInputCandidates()
                    }
                }
            }
        }
    }

    private var generalAutoSendEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeneralToggleRow(
                title: "Press send after pasting",
                isOn: persistedSettingsBinding(
                    $autoEnterEnabled,
                    persist: { DictationAutoSendPreferences.setEnabled($0) },
                    track: { trackSettingsToggle("auto_send", enabled: $0, page: .general) }
                ),
                help: autoEnterEnabled ? "Sends \(autoEnterKey.title) after pasting in chosen apps." : "Dictation only pastes text.",
                info: GeneralInfo(
                    title: "Press send after pasting",
                    message: "After pasting your dictation, Transcripted presses the send key for you — only in the apps you choose below."
                ),
                automationIdentifier: "transcripted.settings.general.auto-send"
            )

            SettingsControlRow(title: "Send key") {
                Picker("Send key", selection: persistedSettingsBinding(
                    $autoEnterKey,
                    persist: { DictationAutoSendPreferences.setSendKey($0) },
                    track: { _ in trackSettingsAction("change_auto_send_key", page: .general) }
                )) {
                    ForEach(DictationAutoSendKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(!autoEnterEnabled)
            }

            // One list backs one preference: every app Transcripted knows
            // about — allowed apps plus currently running candidates — with a
            // toggle each. "Add" stays as the only way to allow an app that
            // isn't running right now.
            SettingsControlRow(
                title: "Apps",
                info: GeneralInfo(
                    title: "Apps",
                    message: "Auto-send only happens in these apps. Toggle a running app below, or use Add to allow one that isn't open right now."
                ),
                showsDivider: !mergedAutoSendApps.isEmpty
            ) {
                HStack(spacing: 8) {
                    SettingsInlineActionButton(title: "Refresh") {
                        trackSettingsAction("refresh_auto_send_apps", page: .general)
                        refreshAutoEnterAppCandidates()
                    }
                    SettingsInlineActionButton(title: "Add…", symbolName: "plus") {
                        trackSettingsAction("add_auto_send_app", page: .general)
                        chooseAutoEnterApp(page: .general)
                    }
                }
            }
            .disabled(!autoEnterEnabled)

            let apps = mergedAutoSendApps
            ForEach(Array(apps.enumerated()), id: \.element.bundleID) { index, app in
                GeneralToggleRow(
                    title: app.name,
                    isOn: Binding(
                        get: { autoEnterAllowedBundleIDs.contains(app.bundleID) },
                        set: { isAllowed in
                            setAutoEnterApp(app.bundleID, isAllowed: isAllowed, page: .general)
                        }
                    ),
                    help: "Allow Transcripted to send \(autoEnterKey.title) after pasting into \(app.name).",
                    showsDivider: index < apps.count - 1
                )
                .disabled(!autoEnterEnabled)
            }
        }
    }

    /// Union of the persisted allow-list and the currently running app
    /// candidates, so allowed-but-not-running apps stay visible and running
    /// apps can be allowed with one toggle.
    private var mergedAutoSendApps: [(bundleID: String, name: String)] {
        var ids = Set(autoEnterAllowedBundleIDs)
        ids.formUnion(autoEnterAppCandidates.map(\.bundleID))
        return ids
            .map { (bundleID: $0, name: autoEnterDisplayName(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var generalPermissionsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(TranscriptedPermissionKind.allCases) { kind in
                PermissionStatusRow(
                    kind: kind,
                    granted: permissionStates[kind] ?? false,
                    systemAudioStatusIsLive: permissionStates.systemAudioStatusIsLive
                ) {
                    trackPermissionCTA(kind)
                    Task { @MainActor in
                        await TranscriptedPermissionAccess.requestAccessOrOpenSettings(for: kind)
                        refreshPermissions()
                    }
                }
            }
        }
        .padding(14)
    }

    private var generalMicProcessingEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            generalMicProcessingPicker
            if showsMicBoostMigrationNote {
                // "OK" as well as any pick: re-picking the mode the menu
                // already shows may not call the binding at all.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(MicrophoneProcessingPreferences.boostMigrationNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("transcripted.settings.meeting-mic-processing-boost-note")
                    Spacer(minLength: 0)
                    Button("OK") {
                        MicrophoneProcessingPreferences.dismissBoostMigrationNote()
                        showsMicBoostMigrationNote = false
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityIdentifier("transcripted.settings.meeting-mic-processing-boost-note-dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }

    private var generalMicProcessingPicker: some View {
        SettingsControlRow(
            title: "Mic processing",
            info: GeneralInfo(
                title: "Mic processing",
                message: "Auto-level (default) evens out quiet meeting mics. Raw records unprocessed meeting input. Apple voice processing applies to meetings and dictation (dictation skips it on split Bluetooth playback) and turns off while Zoom, Teams, Webex or FaceTime is open. Applies from the next recording. Boost Mic during a meeting lasts for that meeting only."
            ),
            showsDivider: false
        ) {
            Picker("Mic processing", selection: persistedSettingsBinding(
                $meetingMicProcessingMode,
                persist: { MicrophoneProcessingPreferences.setMode($0) },
                track: { trackSettingsToggle("meeting_mic_processing_\($0.rawValue)", enabled: true, page: .general) },
                sideEffect: { _ in
                    // With the recorder on, voice processing decides whether
                    // Faster Bluetooth dictation is still in effect.
                    keepRecommendedMicrophoneActive = DictationPersistentInputPreferences.isEnabled()
                    DictationPersistentInputPreferences.effectiveStateMayHaveChanged()
                }
            )) {
                ForEach(MicrophoneProcessingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("transcripted.settings.meeting-mic-processing")
        }
    }

    private var generalReportingEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeneralToggleRow(
                title: "Crash reports",
                isOn: persistedSettingsBinding(
                    $crashReportingEnabled,
                    persist: { CrashReportingPreferences.setEnabled($0) },
                    track: { trackSettingsToggle("crash_reporting", enabled: $0, page: .general) },
                    sideEffect: { _ in
                        CrashReporter.applySessionTrackingPreference()
                        diagnosticsActionStatus = nil
                    }
                ),
                help: crashReportingFootnote,
                info: GeneralInfo(
                    title: "Crash reports",
                    message: "Privacy-safe crash and error reports. Never includes transcripts, audio, names, emails, or file paths."
                ),
                automationIdentifier: "transcripted.settings.general.crash-reports"
            )
            .disabled(!CrashReporter.isAvailable)

            GeneralToggleRow(
                title: "Usage stats",
                // Hand-written, not persistedSettingsBinding: AnalyticsReporter.trackEvent
                // drops any event fired while AnalyticsPreferences reads disabled, so the
                // "anonymous_analytics" transition event itself needs asymmetric ordering —
                // opt-in must persist before tracking so the transition event isn't dropped;
                // opt-out must track first (while still enabled) for the same reason.
                isOn: Binding(
                    get: { anonymousAnalyticsEnabled },
                    set: { newValue in
                        anonymousAnalyticsEnabled = newValue
                        if newValue {
                            RetentionTelemetry.setAnalyticsEnabled(true)
                            trackSettingsToggle("anonymous_analytics", enabled: true, page: .general)
                        } else {
                            // Opt-out must track first, while still enabled — but
                            // track only enqueues onto the delivery queue, which
                            // re-reads the preference on the far side, so the flip
                            // below used to discard this capture before it was ever
                            // processed. Drain first so the one metric this ordering
                            // exists for actually leaves.
                            trackSettingsToggle("anonymous_analytics", enabled: false, page: .general)
                            AnalyticsReporter.drainPendingTrackCalls()
                            RetentionTelemetry.setAnalyticsEnabled(false)
                        }
                        diagnosticsActionStatus = nil
                    }
                ),
                help: analyticsFootnote,
                info: GeneralInfo(
                    title: "Usage stats",
                    message: "Shares feature use, duration and count ranges, error codes, permissions, and an anonymous install ID. Never shares recordings, words, titles, names, or email."
                ),
                automationIdentifier: "transcripted.settings.general.usage-stats",
                showsDivider: false
            )
            .disabled(!AnalyticsReporter.isAvailable)
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

                let pastRowsByID = Dictionary(
                    pastMeetingsRows.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
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
                    pastMeetingsLine(for: pastRowsByID[row.id] ?? DictionaryPastMeetingsRow(id: row.id, entry: nil))
                }

                ForEach(pastMeetingsModel.earlierFixes) { fix in
                    DictionaryPastMeetingsLine(
                        state: .earlierFix(fix),
                        onFix: {},
                        onUndo: {
                            trackSettingsAction("undo_fix_past_meetings", page: .general)
                            pastMeetingsModel.undoEarlierFix(fix.entry)
                        }
                    )
                    .padding(.trailing, 52)
                }
            }
            .task {
                pastMeetingsModel.sheetOpened(rows: pastMeetingsRows)
            }
            .onChange(of: customDictionaryRows) { _, _ in
                pastMeetingsModel.update(rows: pastMeetingsRows)
            }
            .confirmationDialog(
                pastMeetingsFixConfirmationScan.map(DictionaryPastMeetingFixCopy.confirmTitle) ?? "",
                isPresented: Binding(
                    get: { pastMeetingsFixConfirmation != nil },
                    set: { if !$0 { pastMeetingsFixConfirmation = nil } }
                ),
                titleVisibility: .visible,
                presenting: pastMeetingsFixConfirmation
            ) { row in
                if let scan = pastMeetingsModel.scan(for: row) {
                    Button(DictionaryPastMeetingFixCopy.confirmAction(scan)) {
                        trackSettingsAction("fix_past_meetings", page: .general)
                        pastMeetingsModel.fix(row: row)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button("Cancel", role: .cancel) {}
            } message: { row in
                if let entry = row.entry, let scan = pastMeetingsModel.scan(for: row) {
                    Text(DictionaryPastMeetingFixCopy.confirmMessage(entry, scan: scan))
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
                    // One click used to wipe every correction with no undo.
                    showClearCorrectionsConfirm = true
                }
                .disabled(!hasCustomDictionaryContent)
                .help(hasCustomDictionaryContent ? "" : "No saved corrections to clear yet.")
                .alert(clearCorrectionsConfirmTitle, isPresented: $showClearCorrectionsConfirm) {
                    Button("Clear All", role: .destructive) {
                        trackSettingsAction("clear_corrections", page: .general)
                        clearCorrectionRows()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This can't be undone.")
                }
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
}
