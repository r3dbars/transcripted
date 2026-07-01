import AppKit
import SwiftUI
import TranscriptedCore

extension TranscriptedSettingsView {
    var storagePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Storage",
                summary: "Choose where saved Markdown files live."
            )

            SettingsSection(
                title: "Capture Library",
                detail: "Your meeting and dictation Markdown files."
            ) {
                StorageRow(title: "Capture library", url: captureLibraryURL)
                StorageRow(title: "Meeting captures", url: MeetingStoragePaths.transcriptsFolder)
                StorageRow(title: "Dictation captures", url: DictationStoragePaths.transcriptsFolder)

                HStack {
                    SettingsInlineActionButton(title: "Choose Folder", symbolName: "folder") {
                        trackSettingsAction("choose_capture_library", page: .storage)
                        chooseCaptureLibrary()
                    }

                    SettingsInlineActionButton(title: "Reset to Default") {
                        trackSettingsAction("reset_capture_library", page: .storage)
                        TranscriptedStoragePreferences.setCaptureLibraryURL(nil)
                        refreshStoragePaths()
                        AnalyticsReporter.track(
                            "settings_capture_library_changed",
                            properties: [
                                "location_type": "default",
                                "page_id": TranscriptedSettingsPage.storage.analyticsValue,
                            ]
                        )
                    }
                }

                Text("Pick an Obsidian vault or any folder you want agents to read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: "Audio Storage",
                detail: "Transcripted keeps transcripts and shrinks retained meeting audio."
            ) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compress WAV to M4A automatically")
                            .font(.subheadline.weight(.medium))
                        Text("After a transcript is saved, Transcripted keeps replay audio in a smaller format and removes the original WAV only after conversion succeeds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Picker("Delete audio after", selection: Binding(
                    get: { audioRetentionWindow },
                    set: { updateAudioRetentionWindow($0) }
                )) {
                    ForEach(AudioRetentionWindow.allCases) { window in
                        Text(window.title).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                Text(audioRetentionWindow.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Choosing 7 or 30 days asks before deleting old replay audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(
                title: "Local Model Storage",
                detail: "On-device models and optional transcription caches."
            ) {
                if modelCacheLoading, modelCacheSnapshot == nil {
                    ProgressView("Scanning model storage...")
                        .controlSize(.small)
                }

                if let snapshot = modelCacheSnapshot {
                    let includeWhisperInReclaimableCleanup = !effectiveTranscriptionModel.isWhisper
                    let reclaimableBytes = snapshot.reclaimableBytes(includeWhisper: includeWhisperInReclaimableCleanup)
                    ModelCacheMetricRow(
                        title: "Known model and cache footprint",
                        value: snapshot.formattedTotalKnownSize,
                        detail: "FluidAudio models plus Transcripted's app cache."
                    )
                    ModelCacheMetricRow(
                        title: "Reclaimable cache",
                        value: snapshot.formattedReclaimableSize(includeWhisper: includeWhisperInReclaimableCleanup),
                        detail: includeWhisperInReclaimableCleanup
                            ? "Known stale models plus optional Whisper files."
                            : "Known stale models. Whisper is preserved while selected."
                    )
                    if reclaimableBytes > 0 {
                        SettingsInlineActionButton(
                            title: modelCacheCleanupInProgress ? "Removing..." : "Remove Reclaimable Cache",
                            tone: .destructive
                        ) {
                            showReclaimableCacheCleanupConfirmation = true
                        }
                        .disabled(modelCacheCleanupInProgress || modelCacheLoading)
                        .help(modelCacheCleanupInProgress || modelCacheLoading ? modelCacheBusyHelp : "")
                    }
                    ModelCacheMetricRow(
                        title: "FluidAudio models",
                        value: snapshot.formattedFluidAudioModelsSize,
                        detail: "Parakeet, diarization, and related local model files."
                    )
                    ModelCacheMetricRow(
                        title: "Whisper cache",
                        value: snapshot.formattedWhisperModelsSize,
                        detail: "Optional Whisper models stored by Transcripted."
                    )
                    if snapshot.whisperModelsBytes > 0 {
                        SettingsInlineActionButton(
                            title: modelCacheCleanupInProgress ? "Removing..." : "Remove Whisper Cache",
                            tone: .destructive
                        ) {
                            showWhisperCacheCleanupConfirmation = true
                        }
                        .disabled(effectiveTranscriptionModel.isWhisper || modelCacheCleanupInProgress || modelCacheLoading)
                        .help(effectiveTranscriptionModel.isWhisper
                            ? "Switch back to Parakeet before removing the Whisper cache."
                            : (modelCacheCleanupInProgress || modelCacheLoading ? modelCacheBusyHelp : ""))

                        if effectiveTranscriptionModel.isWhisper {
                            Text("Switch back to Parakeet before removing the Whisper cache.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if snapshot.staleFluidAudioModelBytes > 0 {
                        ModelCacheMetricRow(
                            title: "Known stale candidates",
                            value: snapshot.formattedStaleFluidAudioModelSize,
                            detail: snapshot.staleModelSummary
                        )

                        SettingsInlineActionButton(
                            title: modelCacheCleanupInProgress ? "Removing..." : "Remove Known Stale Models",
                            tone: .destructive
                        ) {
                            showModelCacheCleanupConfirmation = true
                        }
                        .disabled(modelCacheCleanupInProgress || modelCacheLoading)
                        .help(modelCacheCleanupInProgress || modelCacheLoading ? modelCacheBusyHelp : "")
                    } else {
                        Text("No known stale Parakeet model folders found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let modelCacheCleanupStatus {
                        Text(modelCacheCleanupStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !modelCacheLoading {
                    Text("Model storage has not been scanned yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsInlineActionButton(title: modelCacheLoading ? "Scanning..." : "Refresh Storage Sizes") {
                    trackSettingsAction("refresh_model_cache_storage", page: .storage)
                    refreshModelCacheSnapshot()
                }
                .disabled(modelCacheLoading)
                .help(modelCacheLoading ? "Storage sizes are being scanned." : "")
            }
            .onAppear {
                if modelCacheSnapshot == nil, !modelCacheLoading {
                    refreshModelCacheSnapshot()
                }
            }
            .alert("Remove reclaimable cache?", isPresented: $showReclaimableCacheCleanupConfirmation) {
                Button("Remove", role: .destructive) {
                    removeReclaimableModelCaches()
                }
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: {
                let includeWhisper = !effectiveTranscriptionModel.isWhisper
                Text(includeWhisper
                    ? "Transcripted will remove known old Parakeet folders and downloaded Whisper model files. Active Parakeet CoreML stays."
                    : "Transcripted will remove known old Parakeet folders. Whisper stays because it is selected.")
            }
            .alert("Remove stale local models?", isPresented: $showModelCacheCleanupConfirmation) {
                Button("Remove", role: .destructive) {
                    removeStaleModelCaches()
                }
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text("Transcripted will remove only known old Parakeet folders: \(modelCacheSnapshot?.staleModelSummary ?? "none"). Active Parakeet CoreML and Whisper caches stay.")
            }
            .alert("Remove Whisper cache?", isPresented: $showWhisperCacheCleanupConfirmation) {
                Button("Remove", role: .destructive) {
                    removeWhisperModelCache()
                }
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text("Transcripted will remove downloaded Whisper model files. Parakeet stays available, and Whisper can download again later if you choose it.")
            }

            SettingsSection(
                title: "Support Folders",
                detail: "Logs, cache, app state, and temporary audio."
            ) {
                DisclosureGroup("Show support folders", isExpanded: $showSupportFolders) {
                    VStack(alignment: .leading, spacing: 12) {
                        StorageRow(title: "App state", url: appStateFolder)
                        StorageRow(title: "App cache", url: cacheFolder)
                        StorageRow(title: "App logs", url: logsFolder)
                        StorageRow(title: "Temporary recordings", url: recordingsFolder)
                    }
                    .padding(.top, 12)
                }
            }
        }
        .accessibilityIdentifier("transcripted.settings.page.storage")
    }

    private var modelCacheBusyHelp: String {
        modelCacheCleanupInProgress
            ? "A cache cleanup is already running."
            : "Wait for the storage scan to finish."
    }

    private var appStateFolder: URL {
        FileManager.default.transcriptedStateDir
    }

    private var cacheFolder: URL {
        FileManager.default.transcriptedCacheDir
    }

    private var logsFolder: URL {
        FileManager.default.transcriptedLogsDir
    }

    private var recordingsFolder: URL {
        FileManager.default.transcriptedRecordingsDir
    }

    private var isUsingDefaultCaptureLibrary: Bool {
        captureLibraryURL.standardizedFileURL == FileManager.default.transcriptedDefaultCaptureLibraryDir.standardizedFileURL
    }

    private func refreshModelCacheSnapshot() {
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

    private func removeStaleModelCaches() {
        guard !modelCacheCleanupInProgress else { return }
        modelCacheCleanupInProgress = true
        modelCacheCleanupStatus = nil

        Task.detached(priority: .utility) {
            do {
                let result = try ModelCacheInventory.removeKnownStaleFluidAudioModels()
                let snapshot = ModelCacheInventory.snapshot()
                await MainActor.run {
                    modelCacheSnapshot = snapshot
                    modelCacheCleanupInProgress = false
                    if result.removedNames.isEmpty {
                        modelCacheCleanupStatus = "No stale model folders needed removal."
                    } else {
                        let size = ModelCacheInventory.formattedByteCount(result.removedBytes)
                        modelCacheCleanupStatus = "Removed \(size) from \(result.removedNames.joined(separator: ", "))."
                    }
                }
            } catch {
                await MainActor.run {
                    modelCacheCleanupInProgress = false
                    modelCacheCleanupStatus = "Could not remove stale models: \(error.localizedDescription)"
                }
            }
        }
    }

    private func removeReclaimableModelCaches() {
        guard !modelCacheCleanupInProgress else { return }
        let includeWhisper = !effectiveTranscriptionModel.isWhisper
        modelCacheCleanupInProgress = true
        modelCacheCleanupStatus = nil

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
                    modelCacheCleanupStatus = "Could not remove reclaimable cache: \(error.localizedDescription)"
                }
            }
        }
    }

    private func removeWhisperModelCache() {
        guard !modelCacheCleanupInProgress, !effectiveTranscriptionModel.isWhisper else { return }
        modelCacheCleanupInProgress = true
        modelCacheCleanupStatus = nil

        Task.detached(priority: .utility) {
            do {
                let result = try ModelCacheInventory.removeWhisperModels()
                let snapshot = ModelCacheInventory.snapshot()
                await MainActor.run {
                    modelCacheSnapshot = snapshot
                    modelCacheCleanupInProgress = false
                    if result.removedBytes > 0 {
                        let size = ModelCacheInventory.formattedByteCount(result.removedBytes)
                        modelCacheCleanupStatus = "Removed \(size) from the Whisper cache."
                    } else {
                        modelCacheCleanupStatus = "No Whisper model files needed removal."
                    }
                }
            } catch {
                await MainActor.run {
                    modelCacheCleanupInProgress = false
                    modelCacheCleanupStatus = "Could not remove Whisper cache: \(error.localizedDescription)"
                }
            }
        }
    }

    private func updateAudioRetentionWindow(_ window: AudioRetentionWindow) {
        guard window != audioRetentionWindow else { return }
        guard window.days == nil else {
            pendingAudioRetentionWindow = window
            return
        }

        applyAudioRetentionWindow(window)
    }

    private func chooseCaptureLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Transcripted saves meeting and dictation Markdown files."
        panel.directoryURL = captureLibraryURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard TranscriptedStoragePreferences.setCaptureLibraryURL(url) else {
            refreshStoragePaths()
            showCaptureLibrarySelectionError()
            return
        }
        refreshStoragePaths()
        AnalyticsReporter.track(
            "settings_capture_library_changed",
            properties: [
                "location_type": isUsingDefaultCaptureLibrary ? "default" : "custom",
                "page_id": TranscriptedSettingsPage.storage.analyticsValue,
            ]
        )
    }

    private func showCaptureLibrarySelectionError() {
        let alert = NSAlert()
        alert.messageText = "Transcripted can't use that folder."
        alert.informativeText = "Choose a folder where Transcripted can create meeting and dictation files, or reset to the default capture library."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
