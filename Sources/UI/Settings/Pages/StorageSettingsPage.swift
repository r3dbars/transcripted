import Foundation
import SwiftUI

/// The Settings > Storage page. Local disclosure and confirmation state lives
/// here; persisted state and filesystem work route through injected callbacks.
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

    let audioRetentionWindow: AudioRetentionWindow

    let modelCacheSnapshot: ModelCacheSnapshot?
    let modelCacheLoading: Bool
    let modelCacheCleanupInProgress: Bool
    let modelCacheCleanupStatus: String?
    let modelCacheCleanupStatusDetails: String?
    let effectiveTranscriptionModelIsWhisper: Bool

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
    let onLoadModelCacheSnapshot: () -> Void
    let onRefreshModelCacheSnapshot: () -> Void
    let onApplyAudioRetentionWindow: (AudioRetentionWindow) -> Void
    let failureDetailsButton: (String?) -> FailureDetailsButton

    @State private var pendingAudioRetentionWindow: AudioRetentionWindow?
    @State private var showReclaimableCacheCleanupConfirmation = false
    @State private var showModelCacheCleanupConfirmation = false
    @State private var showWhisperCacheCleanupConfirmation = false
    @State private var showSupportFolders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Storage",
                summary: "Choose where saved Markdown files live."
            )

            libraryGroup
            audioAndModelsGroup
            supportFoldersGroup
        }
        .accessibilityIdentifier("transcripted.settings.page.storage")
    }

    // MARK: Library

    private var libraryGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibrarySectionLabel(text: "Capture Library")

            VStack(alignment: .leading, spacing: 12) {
                StorageRow(title: "Capture library", url: captureLibraryURL)
                Hairline()
                StorageRow(title: "Meeting captures", url: meetingCapturesURL)
                Hairline()
                StorageRow(title: "Dictation captures", url: dictationCapturesURL)

                if let unavailableCaptureLibraryPath {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LibraryTokens.attention)
                            .frame(width: 20)
                        Text("Transcripted can't reach \(unavailableCaptureLibraryPath). It is using the default capture library until that folder is available again or you choose a new one.")
                            .font(.caption)
                            .foregroundStyle(LibraryTokens.ink2)
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
                            .foregroundStyle(LibraryTokens.ink2)
                    }
                } else if let captureLibraryMigrationStatus {
                    Text(captureLibraryMigrationStatus)
                        .font(.caption)
                        .foregroundStyle(LibraryTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    failureDetailsButton(captureLibraryMigrationStatusDetails)
                }

                Text("Pick an Obsidian vault or any folder you want agents to read.")
                    .font(.caption)
                    .foregroundStyle(LibraryTokens.ink3)
            }
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
    }

    // MARK: Audio & Models

    private var audioAndModelsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibrarySectionLabel(text: "Audio & Models")

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LibraryTokens.ink2)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compress WAV to M4A automatically")
                            .font(LibraryTokens.rowTitle)
                        Text("After a transcript is saved, Transcripted keeps replay audio in a smaller format and removes the original WAV only after conversion succeeds.")
                            .font(.caption)
                            .foregroundStyle(LibraryTokens.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Picker("Delete audio after", selection: audioRetentionWindowBinding) {
                    ForEach(AudioRetentionWindow.allCases) { window in
                        Text(window.title).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                Text(audioRetentionWindow.detail)
                    .font(.caption)
                    .foregroundStyle(LibraryTokens.ink2)

                Text("Choosing 7 or 30 days asks before deleting old replay audio.")
                    .font(.caption)
                    .foregroundStyle(LibraryTokens.ink3)

                Hairline()

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
                                .foregroundStyle(LibraryTokens.ink2)
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
                            .foregroundStyle(LibraryTokens.ink2)
                    }

                    if let modelCacheCleanupStatus {
                        Text(modelCacheCleanupStatus)
                            .font(.caption)
                            .foregroundStyle(LibraryTokens.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        failureDetailsButton(modelCacheCleanupStatusDetails)
                    }
                } else if !modelCacheLoading {
                    Text("Model storage has not been scanned yet.")
                        .font(.caption)
                        .foregroundStyle(LibraryTokens.ink2)
                }

                SettingsInlineActionButton(title: modelCacheLoading ? "Scanning..." : "Refresh Storage Sizes") {
                    onRefreshModelCacheSnapshot()
                }
                .disabled(modelCacheLoading)
                .help(modelCacheLoading ? "Storage sizes are being scanned." : "")
            }
        }
        .onAppear {
            if modelCacheSnapshot == nil, !modelCacheLoading {
                onLoadModelCacheSnapshot()
            }
        }
        .alert(item: $pendingAudioRetentionWindow) { window in
            Alert(
                title: Text("Delete old replay audio?"),
                message: Text("Transcripted will keep your Markdown transcripts, but retained replay audio older than \(window.title) will be permanently removed now and cleaned up automatically later."),
                primaryButton: .cancel(),
                secondaryButton: .destructive(Text("Delete Old Audio")) {
                    onApplyAudioRetentionWindow(window)
                }
            )
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
    }

    // MARK: Support Folders

    private var supportFoldersGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibrarySectionLabel(text: "Support Folders")

            DisclosureGroup("Show support folders", isExpanded: $showSupportFolders) {
                VStack(alignment: .leading, spacing: 12) {
                    StorageRow(title: "App state", url: appStateFolder)
                    Hairline()
                    StorageRow(title: "App cache", url: cacheFolder)
                    Hairline()
                    StorageRow(title: "App logs", url: logsFolder)
                    Hairline()
                    StorageRow(title: "Temporary recordings", url: recordingsFolder)
                }
                .padding(.top, 12)
            }
        }
    }

    private var captureLibraryMigrationBusyHelp: String {
        "Captures are still being copied to the new folder."
    }

    private var audioRetentionWindowBinding: Binding<AudioRetentionWindow> {
        Binding(
            get: { audioRetentionWindow },
            set: { window in
                guard window != audioRetentionWindow else { return }
                if window.days == nil {
                    onApplyAudioRetentionWindow(window)
                } else {
                    pendingAudioRetentionWindow = window
                }
            }
        )
    }

    private var modelCacheBusyHelp: String {
        modelCacheCleanupInProgress
            ? "A cache cleanup is already running."
            : "Wait for the storage scan to finish."
    }
}

/// The one divider in this page: a plain 1px hairline, no card stroke.
private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(LibraryTokens.hairline)
            .frame(height: 1)
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
