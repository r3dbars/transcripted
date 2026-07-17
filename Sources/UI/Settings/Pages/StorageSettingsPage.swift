import Foundation
import SwiftUI

/// The Settings > Storage page. Storage state and filesystem work stay in
/// `TranscriptedSettingsView`; this view only renders current state and routes
/// user actions back through injected closures.
struct StorageSettingsPage<FailureDetailsButton: View>: View {
    let captureLibraryURL: URL
    let meetingCapturesURL: URL
    let dictationCapturesURL: URL
    let unavailableCaptureLibraryPath: String?
    let captureLibraryMigrationInProgress: Bool
    let captureLibraryMigrationStatus: String?
    let captureLibraryMigrationStatusDetails: String?
    let captureLibraryChoicePromptBinding: Binding<Bool>
    let pendingCaptureLibraryChoice: PendingCaptureLibraryChoice?

    @Binding var audioRetentionWindow: AudioRetentionWindow

    let modelCacheSnapshot: ModelCacheSnapshot?
    let modelCacheLoading: Bool
    let modelCacheCleanupInProgress: Bool
    let modelCacheCleanupStatus: String?
    let modelCacheCleanupStatusDetails: String?
    let effectiveTranscriptionModelIsWhisper: Bool
    @Binding var showReclaimableCacheCleanupConfirmation: Bool
    @Binding var showModelCacheCleanupConfirmation: Bool
    @Binding var showWhisperCacheCleanupConfirmation: Bool

    @Binding var showSupportFolders: Bool
    let appStateFolder: URL
    let cacheFolder: URL
    let logsFolder: URL
    let recordingsFolder: URL

    let onChooseCaptureLibrary: () -> Void
    let onResetCaptureLibrary: () -> Void
    let onCopyCapturesThenSwitchLibrary: (PendingCaptureLibraryChoice) -> Void
    let onSwitchLibraryWithoutCopying: (PendingCaptureLibraryChoice) -> Void
    let onRemoveReclaimableModelCaches: () -> Void
    let onRemoveStaleModelCaches: () -> Void
    let onRemoveWhisperModelCache: () -> Void
    let onRefreshModelCacheSnapshot: () -> Void
    let failureDetailsButton: (String?) -> FailureDetailsButton

    var body: some View {
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
                StorageRow(title: "Meeting captures", url: meetingCapturesURL)
                StorageRow(title: "Dictation captures", url: dictationCapturesURL)

                if let unavailableCaptureLibraryPath {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 20)
                        Text("Transcripted can't reach \(unavailableCaptureLibraryPath). It is using the default capture library until that folder is available again or you choose a new one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    SettingsInlineActionButton(title: "Choose Folder", symbolName: "folder") {
                        onChooseCaptureLibrary()
                    }
                    .disabled(captureLibraryMigrationInProgress)
                    .help(captureLibraryMigrationInProgress ? captureLibraryMigrationBusyHelp : "")

                    SettingsInlineActionButton(title: "Reset to Default") {
                        onResetCaptureLibrary()
                    }
                    .disabled(captureLibraryMigrationInProgress)
                    .help(captureLibraryMigrationInProgress ? captureLibraryMigrationBusyHelp : "")
                }

                if captureLibraryMigrationInProgress {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(captureLibraryMigrationStatus ?? "Copying captures...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let captureLibraryMigrationStatus {
                    Text(captureLibraryMigrationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    failureDetailsButton(captureLibraryMigrationStatusDetails)
                }

                Text("Pick an Obsidian vault or any folder you want agents to read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .alert(
                "Copy existing captures?",
                isPresented: captureLibraryChoicePromptBinding,
                presenting: pendingCaptureLibraryChoice
            ) { choice in
                Button(choice.copyButtonTitle) {
                    onCopyCapturesThenSwitchLibrary(choice)
                }
                .keyboardShortcut(.defaultAction)
                Button("Just Switch") {
                    onSwitchLibraryWithoutCopying(choice)
                }
                Button("Cancel", role: .cancel) {}
            } message: { choice in
                Text("Your current library still has saved meetings or dictations. Copy puts a copy of them in the \(choice.destinationDescription) and never deletes the originals. Just Switch leaves everything in \(choice.currentLibrary.path) - Transcripted and connected agents will only see the \(choice.destinationDescription).")
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

                Picker("Delete audio after", selection: $audioRetentionWindow) {
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
                    let includeWhisperInReclaimableCleanup = !effectiveTranscriptionModelIsWhisper
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
                        .disabled(effectiveTranscriptionModelIsWhisper || modelCacheCleanupInProgress || modelCacheLoading)
                        .help(effectiveTranscriptionModelIsWhisper
                            ? "Switch back to Parakeet before removing the Whisper cache."
                            : (modelCacheCleanupInProgress || modelCacheLoading ? modelCacheBusyHelp : ""))

                        if effectiveTranscriptionModelIsWhisper {
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
                        failureDetailsButton(modelCacheCleanupStatusDetails)
                    }
                } else if !modelCacheLoading {
                    Text("Model storage has not been scanned yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsInlineActionButton(title: modelCacheLoading ? "Scanning..." : "Refresh Storage Sizes") {
                    onRefreshModelCacheSnapshot()
                }
                .disabled(modelCacheLoading)
                .help(modelCacheLoading ? "Storage sizes are being scanned." : "")
            }
            .onAppear {
                if modelCacheSnapshot == nil, !modelCacheLoading {
                    onRefreshModelCacheSnapshot()
                }
            }
            .alert("Remove reclaimable cache?", isPresented: $showReclaimableCacheCleanupConfirmation) {
                Button("Remove", role: .destructive) {
                    onRemoveReclaimableModelCaches()
                }
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: {
                let includeWhisper = !effectiveTranscriptionModelIsWhisper
                Text(includeWhisper
                    ? "Transcripted will remove known old Parakeet folders and downloaded Whisper model files. Active Parakeet CoreML stays."
                    : "Transcripted will remove known old Parakeet folders. Whisper stays because it is selected.")
            }
            .alert("Remove stale local models?", isPresented: $showModelCacheCleanupConfirmation) {
                Button("Remove", role: .destructive) {
                    onRemoveStaleModelCaches()
                }
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text("Transcripted will remove only known old Parakeet folders: \(modelCacheSnapshot?.staleModelSummary ?? "none"). Active Parakeet CoreML and Whisper caches stay.")
            }
            .alert("Remove Whisper cache?", isPresented: $showWhisperCacheCleanupConfirmation) {
                Button("Remove", role: .destructive) {
                    onRemoveWhisperModelCache()
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

    private var captureLibraryMigrationBusyHelp: String {
        "Captures are still being copied to the new folder."
    }

    private var modelCacheBusyHelp: String {
        modelCacheCleanupInProgress
            ? "A cache cleanup is already running."
            : "Wait for the storage scan to finish."
    }
}

struct PendingCaptureLibraryChoice: Equatable {
    let currentLibrary: URL
    let newLibrary: URL
    let preferenceURL: URL?
    let destinationKind: CaptureLibraryDestinationKind

    var copyButtonTitle: String {
        switch destinationKind {
        case .custom:
            return "Copy to New Folder"
        case .defaultLibrary:
            return "Copy to Default Folder"
        }
    }

    var destinationDescription: String {
        switch destinationKind {
        case .custom:
            return "new folder"
        case .defaultLibrary:
            return "default folder"
        }
    }
}

enum CaptureLibraryDestinationKind: Equatable {
    case custom
    case defaultLibrary
}
