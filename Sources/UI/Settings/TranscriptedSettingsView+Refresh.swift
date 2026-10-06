import AppKit
import Observation
import SwiftUI
import TranscriptedCore
import UniformTypeIdentifiers

extension TranscriptedSettingsView {
    var settingsFooterShowsUpdateBadge: Bool {
        sparkleUpdater.updateNeedsUserAction
    }

    var settingsFooterUpdateIsDownloaded: Bool {
        sparkleUpdater.updateStatus.readyToInstallVersion != nil
    }

    var settingsFooterActionEnabled: Bool {
        updateActionEnabled(for: sparkleUpdater.updateStatus)
    }

    var appStateFolder: URL {
        FileManager.default.transcriptedStateDir
    }

    var effectiveTranscriptionModel: TranscriptionModelChoice {
        TranscriptionModelPreferences.preferredModel()
    }

    var visibleTranscriptionModelChoices: [TranscriptionModelChoice] {
        TranscriptionModelChoice.allCases.filter { model in
            TranscriptionModelVisibilityPolicy.isVisible(
                model,
                selectedModel: preferredTranscriptionModel,
                isLocallyInstalled: { variant in
                    ModelCacheInventory.activeParakeetModelDirectory(variant: variant) != nil
                }
            )
        }
    }

    /// Only script-installed models can be missing; downloaded ones count as present.
    func isLocalModelInstalled(_ model: TranscriptionModelChoice) -> Bool {
        guard let variant = model.parakeetVariant, variant.isLocalInstallOnly else { return true }
        return ModelCacheInventory.activeParakeetModelDirectory(variant: variant) != nil
    }

    var modelDownloadActionTitle: String? {
        // Script-installed models can't be downloaded; the button only re-checks
        // the install or retries the load.
        let model = sttRouter.selectedModel
        if model.parakeetVariant?.isLocalInstallOnly == true {
            switch sttRouter.modelDownloadState {
            case .notLoaded, .failed:
                guard isLocalModelInstalled(model) else { return "Check Again" }
                if case .failed = sttRouter.modelDownloadState { return "Try Again" }
                return "Load Now"
            case .cached:
                return "Load Now"
            case .downloading, .loading, .ready:
                return nil
            }
        }
        switch sttRouter.modelDownloadState {
        case .notLoaded:
            return "Download Now"
        case .cached:
            return "Load Now"
        case .failed:
            // Apple Speech failures are usually a language setting, not a
            // download to redo.
            return effectiveTranscriptionModel.isAppleSpeech ? "Try Again" : "Retry Download"
        case .downloading, .loading, .ready:
            return nil
        }
    }

    func modelDownloadAction(page: TranscriptedSettingsPage) -> (() -> Void)? {
        guard modelDownloadActionTitle != nil else { return nil }
        return {
            trackSettingsAction("download_model", page: page)
            Task { @MainActor in
                await sttRouter.initializeSelectedModelInBackground()
            }
        }
    }

    var missingRequiredPermissions: [TranscriptedPermissionKind] {
        TranscriptedPermissionKind.requiredForCurrentUse(
            dictationShortcutsEnabled: dictationShortcutsEnabled
        ).filter { kind in
            !(permissionStates[kind] ?? false)
        }
    }

    var permissionsDetailLine: String {
        if missingRequiredPermissions.isEmpty {
            return dictationShortcutsEnabled
                ? "Dictation permissions are on. Meeting audio can be enabled when you need it."
                : "Meeting recording permissions are on. Dictation shortcuts can stay off."
        }
        let permissions = missingRequiredPermissions.map(\.title).joined(separator: " and ")
        return dictationShortcutsEnabled
            ? "Turn on \(permissions) to record and paste back."
            : "Turn on \(permissions) to record meetings."
    }

    var isUsingDefaultCaptureLibrary: Bool {
        captureLibraryURL.standardizedFileURL == FileManager.default.transcriptedDefaultCaptureLibraryDir.standardizedFileURL
    }

    var crashReportingFootnote: String {
        if CrashReporter.isAvailable {
            return crashReportingEnabled
                ? "On. Sends scrubbed crash and error data to Sentry."
                : "Off. Crash and error details stay on this Mac."
        }
        return "Sentry is not configured in this build. Reports stay local."
    }

    var analyticsFootnote: String {
        if AnalyticsReporter.isAvailable {
            return anonymousAnalyticsEnabled
                ? "On. Sends only allowlisted anonymous product events."
                : "Off. No anonymous usage stats leave this Mac."
        }
        return "PostHog is not configured in this build. Usage stats stay off."
    }

    func tone(for tone: FirstRunModelCardState.Tone) -> SettingsStatusCard.Tone {
        switch tone {
        case .ready:
            return .ready
        case .working:
            return .working
        case .failed:
            return .caution
        }
    }

    /// Whether the live transcription activity card represents in-flight work
    /// that the user can explicitly cancel (an imported-audio copy or a running
    /// transcription), as opposed to a finished/failed state.
    var homeTranscriptionActivityIsCancellable: Bool {
        switch meetingSession.displayStatus {
        case .gettingReady, .transcribing, .finishing:
            return true
        case .idle, .transcriptSaved, .discardedAccidentalStart, .failed:
            return false
        }
    }

    var homeTranscriptionActivity: HomeTranscriptionActivityPresentation? {
        return HomeTranscriptionActivityPresentation.make(
            sessionState: meetingSession.state,
            displayStatus: meetingSession.displayStatus,
            warmupStatus: meetingSession.warmupStatus,
            lastSavedTitle: meetingSession.lastSavedTitle,
            lastSavedTranscriptURL: meetingSession.lastSavedTranscriptURL
        )
    }

    func refreshState() {
        refreshPermissions()
        refreshStoragePaths()
        refreshRecentCaptures(force: true)
        refreshShortcutState()
        refreshDockVisibility()
        refreshLaunchAtLoginState()
        // No speakers refresh here: this only runs for a new presentation, and
        // `present()` has just started one. Asking again while it runs queued
        // a second full transcript scan.
        let storedDictionaryText = CustomDictionaryPreferences.rawText()
        if storedDictionaryText != customDictionaryText {
            // Only rebuild when the saved list changed, so row ids (and the
            // past-meetings Undo keyed to them) survive a refresh.
            customDictionaryText = storedDictionaryText
            customDictionaryRows = CorrectionDraftRow.rows(from: storedDictionaryText)
        }
        preferredTranscriptionModel = TranscriptionModelPreferences.preferredModel()
        uiSoundsEnabled = UISoundPreferences.isEnabled()
        meetingMicProcessingMode = MicrophoneProcessingPreferences.mode()
        showsMicBoostMigrationNote = MicrophoneProcessingPreferences.showsBoostMigrationNote()
        micBoostHintsHiddenThrough = MicrophoneProcessingPreferences.micBoostHintsHiddenThrough()
        useSystemMeetingMicrophone = MeetingMicrophonePreferences.usesSystemInput()
        pinnedMicrophoneRecorderOn = PinnedMicrophoneCapturePreferences.isEnabled()
        microphoneChoice = MicrophoneChoicePreferences.choice()
        keepRecommendedMicrophoneActive = DictationPersistentInputPreferences.isEnabled()
        splitLocalSpeakersEnabled = LocalSpeakerPreferences.isEnabled()
        dictationShortcutsEnabled = HotkeyPreferences.dictationShortcutsEnabled()
        dictationKeyBehavior = HotkeyPreferences.dictationKeyBehavior()
        refreshAutoEnterPreferences(includeCandidates: pageShowsAutoEnterSettings(navigation.selectedPage))
        crashReportingEnabled = CrashReportingPreferences.isEnabled()
        anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
        if case .unknown = sparkleUpdater.updateStatus.state {
            sparkleUpdater.refreshUpdateStatus()
        }
    }

    func trackSettingsPageViewed(
        _ page: TranscriptedSettingsPage,
        source: String,
        discoveredPage: TranscriptedSettingsPage? = nil,
        trackFeatureDiscovery: Bool = true
    ) {
        AnalyticsReporter.track(
            "settings_page_viewed",
            properties: [
                "page_id": page.analyticsValue,
                "source": source,
            ]
        )
        guard trackFeatureDiscovery else { return }
        trackSettingsFeatureDiscovery(for: discoveredPage ?? page, source: source)
    }

    func trackSettingsAction(_ actionID: String, page: TranscriptedSettingsPage? = nil) {
        AnalyticsReporter.track(
            "settings_action_clicked",
            properties: [
                "action_id": actionID,
                "page_id": (page ?? navigation.selectedPage).analyticsValue,
            ]
        )
    }

    func trackSettingsToggle(_ settingID: String, enabled: Bool, page: TranscriptedSettingsPage? = nil) {
        AnalyticsReporter.track(
            "settings_toggle_changed",
            properties: [
                "enabled": enabled ? "true" : "false",
                "page_id": (page ?? navigation.selectedPage).analyticsValue,
                "setting_id": settingID,
            ]
        )
    }

    func trackPermissionCTA(_ kind: TranscriptedPermissionKind) {
        AnalyticsReporter.track(
            "settings_permission_cta_clicked",
            properties: [
                "page_id": navigation.selectedPage.analyticsValue,
                "permission_kind": kind.analyticsValue,
                "prior_status": permissionStates[kind] == true ? "ready" : "pending",
            ]
        )
    }

    private func trackSettingsFeatureDiscovery(for page: TranscriptedSettingsPage, source: String) {
        guard let featureArea = settingsDiscoveryFeatureArea(for: page) else { return }

        FeatureDiscoveryTelemetry.trackIfNeeded(
            featureArea: featureArea,
            pageID: page.analyticsValue,
            source: source
        )
    }

    private func settingsDiscoveryFeatureArea(for page: TranscriptedSettingsPage) -> FeatureDiscoveryTelemetry.FeatureArea? {
        switch page {
        case .today, .home, .dictations:
            return .localArtifactActions
        case .people:
            return .speakerReview
        case .connectAgent:
            return .agentSetup
        case .writing:
            // No discovery area for Writing yet; its page views still
            // arrive as `settings_page_viewed` with page_id `writing`.
            return nil
        case .general:
            // The combined settings page spans capture-library, update, and
            // permission surfaces; no single discovery area fits it.
            return nil
        }
    }

    func refreshPermissions() {
        permissionStates = PermissionSnapshot.current()
        revalidateSystemAudioPermissionForStatusSurfaces()
    }

    private func revalidateSystemAudioPermissionForStatusSurfaces() {
        SystemAudioPermissionRevalidator.revalidateForStatusSurfaces(
            task: $permissionRevalidationTask
        ) {
            permissionStates = PermissionSnapshot.current()
        }
    }

    func refreshStoragePaths() {
        captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir
        unavailableCaptureLibraryPath = TranscriptedStoragePreferences.unavailableCustomCaptureLibraryPath()
    }

    func refreshModelCacheSnapshot() {
        guard !modelCacheLoading else { return }
        modelCacheLoading = true

        Task.detached(priority: .utility) {
            let snapshot = ModelCacheInventory.snapshot()
            await MainActor.run {
                modelCacheSnapshot = snapshot
                modelCacheLoading = false
            }
        }
    }

    func removeReclaimableModelCaches() {
        guard !modelCacheCleanupInProgress else { return }
        let includeWhisper = !effectiveTranscriptionModel.isWhisper
        modelCacheCleanupInProgress = true
        modelCacheCleanupStatus = nil
        modelCacheCleanupStatusDetails = nil

        Task.detached(priority: .utility) {
            do {
                let result = try ModelCacheInventory.removeReclaimableCaches(includeWhisper: includeWhisper)
                let snapshot = ModelCacheInventory.snapshot()
                await MainActor.run {
                    modelCacheSnapshot = snapshot
                    modelCacheCleanupInProgress = false
                    if result.removedNames.isEmpty {
                        modelCacheCleanupStatus = "No reclaimable model cache needed removal."
                    } else {
                        let size = ModelCacheInventory.formattedByteCount(result.removedBytes)
                        modelCacheCleanupStatus = "Removed \(size) from \(result.removedNames.joined(separator: ", "))."
                    }
                }
            } catch {
                await MainActor.run {
                    modelCacheCleanupInProgress = false
                    modelCacheCleanupStatus = SettingsActionFailureCopy.modelCacheRemoval
                    modelCacheCleanupStatusDetails = error.localizedDescription
                }
            }
        }
    }

    func applyAudioRetentionWindow(_ window: AudioRetentionWindow) {
        audioRetentionWindow = window
        trackSettingsAction("audio_retention_changed", page: .general)
        AudioStoragePreferences.setDeleteAudioAfter(window)
        Task.detached(priority: .utility) {
            let result = await MeetingAudioStorageManager.processExistingRetainedAudio(
                in: MeetingStoragePaths.transcriptsFolder,
                retentionWindow: window
            )
            // A retention change can create/recompress/prune retained audio across the
            // library; signal Home so cached audio URLs re-resolve from disk.
            if result.changedArtifacts {
                await MainActor.run {
                    CaptureLibraryChangeBroadcaster.shared.noteLibraryWideChange()
                }
            }
        }
    }

    func applyDictationAudioKeepWindow(_ window: DictationAudioKeepWindow) {
        dictationAudioKeepWindow = window
        trackSettingsAction("dictation_audio_keep_changed", page: .general)
        AudioStoragePreferences.setDictationAudioKeepWindow(window)
        Task.detached(priority: .utility) {
            DictationAudioArchive.prune(window: window)
        }
    }

    /// App activation. A closed window skips the sweep (about 9 TCC reads on
    /// main per popover open); opening it runs the full `refreshState()`.
    func refreshAfterAppActivation() {
        let work = SettingsClosedWindowRefreshPolicy.appActivationWork(isWindowOpen: navigation.isWindowOpen)
        if work.permissions { refreshPermissions() }
        if work.recentCaptures { refreshRecentCaptures(reloadDashboard: work.dashboard) }
        if work.shortcuts { refreshShortcutState() }
        // Coming back from Login Items should clear a stale approval or
        // failure line.
        if work.launchAtLogin { refreshLaunchAtLoginState() }
    }

    func updateLibraryVisibility() {
        homeViewModel.setShown(
            navigation.isWindowOpen
                && SettingsRecentCaptureRefreshPolicy.mode(for: navigation.selectedPage) == .homeDashboard
        )
    }

    /// Retained hidden pages invalidate lazily; presenting the window refreshes
    /// them once, while their last snapshot remains available for the first frame.
    func refreshRecentCaptures(
        force: Bool = false, reloadDashboard: Bool = true, isLibraryChange: Bool = false
    ) {
        updateLibraryVisibility()
        guard navigation.isWindowOpen else { return }
        if navigation.selectedPage == .today {
            todayViewModel.refresh(force: force)
        }
        guard reloadDashboard else { return }
        switch SettingsRecentCaptureRefreshPolicy.mode(for: navigation.selectedPage) {
        case .homeDashboard:
            // Saves cannot be dropped by the activation throttle. The model
            // coalesces them and retains one trailing read of the latest files.
            refreshHomeDashboard(force: force || isLibraryChange)
        case .none:
            break
        }
    }

    private func refreshHomeDashboard(force: Bool) {
        let now = Date()
        guard SettingsRecentCaptureRefreshPolicy.shouldStartDashboardRefresh(
            for: navigation.selectedPage,
            force: force,
            isInFlight: homeDashboardRefreshInFlight,
            lastStartedAt: lastHomeDashboardRefreshStartedAt,
            now: now
        ) else {
            return
        }

        homeDashboardRefreshTask?.cancel()
        let generation = homeDashboardRefreshGeneration.begin()
        lastHomeDashboardRefreshStartedAt = now
        homeDashboardRefreshInFlight = true
        homeViewModel.refresh()

        homeDashboardRefreshTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, homeDashboardRefreshGeneration.finishIfCurrent(generation) else { return }
            homeDashboardRefreshInFlight = false
            homeDashboardRefreshTask = nil
        }
    }

    func refreshShortcutState() {
        dictationShortcutsEnabled = HotkeyPreferences.dictationShortcutsEnabled()
        dictationKeyBehavior = HotkeyPreferences.dictationKeyBehavior()
        dictationTriggerSystemWarning = PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
            for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
        )
    }

    func refreshDockVisibility() {
        showTranscriptedInDock = DockVisibilityPreferences.isVisible()
    }

    /// Runs on every app activation, so the status read stays off main. A
    /// newer read or a toggle bumps the generation, so a stale reply is dropped.
    func refreshLaunchAtLoginState() {
        launchAtLoginReadGeneration += 1
        let generation = launchAtLoginReadGeneration
        Task { @MainActor in
            let state = await LaunchAtLoginController.readState()
            guard generation == launchAtLoginReadGeneration else { return }
            launchAtLogin = state
            launchAtLoginFailureMessage = nil
        }
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginReadGeneration += 1
        let previousValue = launchAtLogin.isEnabled
        launchAtLogin.isEnabled = enabled
        trackSettingsToggle("launch_at_login", enabled: enabled, page: .general)

        do {
            try LaunchAtLoginController.setEnabled(enabled)
            refreshLaunchAtLoginState()
        } catch {
            launchAtLogin.isEnabled = previousValue
            // Shown inline under the switch (it used to live only in the
            // tooltip); the raw error is captured to telemetry below.
            launchAtLogin.statusDescription = SettingsActionFailureCopy.launchAtLogin
            launchAtLoginFailureMessage = LaunchAtLoginController.isUnavailable
                ? SettingsActionFailureCopy.launchAtLoginUnavailable
                : SettingsActionFailureCopy.launchAtLogin
            EventReporter.shared.capture(
                level: .warning,
                engine: "app",
                event: "launch_at_login_update_failed",
                message: error.localizedDescription
            )
        }
    }
}
