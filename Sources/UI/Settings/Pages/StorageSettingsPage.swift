import Foundation
import SwiftUI

/// The Storage portion of the combined settings page (2026-08 card restyle):
/// four always-visible card rows — capture library, delete-audio window,
/// free-up-space, and a support-files reveal. Row explanations live in ⓘ
/// popovers. Local confirmation state lives here; persisted state and
/// filesystem work route through injected callbacks.
struct StorageSettingsPage<FailureDetailsButton: View>: View {
    let captureLibraryURL: URL
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

    let supportFilesFolder: URL

    let onChooseCaptureLibrary: () -> Void
    let onResetCaptureLibrary: () -> Void
    let onCopyCapturesThenSwitchLibrary: (PendingCaptureLibraryChoice) -> Void
    let onSwitchLibraryWithoutCopying: (PendingCaptureLibraryChoice) -> Void
    let onRemoveReclaimableModelCaches: () -> Void
    let onLoadModelCacheSnapshot: () -> Void
    let onRefreshModelCacheSnapshot: () -> Void
    let onApplyAudioRetentionWindow: (AudioRetentionWindow) -> Void
    let failureDetailsButton: (String?) -> FailureDetailsButton

    @State private var pendingAudioRetentionWindow: AudioRetentionWindow?
    @State private var showReclaimableCacheCleanupConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCardLabel(text: "Storage")
            SettingsCard {
                libraryRow
                deleteAudioRow
                freeUpSpaceRow
                supportFilesRow
            }
            .accessibilityIdentifier("transcripted.settings.section.storage")

            if let status = captureLibraryMigrationStatus ?? modelCacheCleanupStatus {
                VStack(alignment: .leading, spacing: 4) {
                    if captureLibraryMigrationInProgress {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(LibraryTokens.ink2)
                        }
                    } else {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(LibraryTokens.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        failureDetailsButton(captureLibraryMigrationStatusDetails ?? modelCacheCleanupStatusDetails)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .accessibilityIdentifier("transcripted.settings.page.storage")
        .onAppear {
            if modelCacheSnapshot == nil, !modelCacheLoading {
                onLoadModelCacheSnapshot()
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
        .alert("Free up space?", isPresented: $showReclaimableCacheCleanupConfirmation) {
            Button("Remove", role: .destructive) {
                onRemoveReclaimableModelCaches()
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(effectiveTranscriptionModelIsWhisper
                ? "Transcripted will remove known old Parakeet folders. Whisper stays because it is selected."
                : "Transcripted will remove known old Parakeet folders and downloaded Whisper model files. Active Parakeet CoreML stays.")
        }
    }

    private var libraryRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsControlRow(
                title: "Capture library",
                info: GeneralInfo(
                    title: "Capture library",
                    message: "Where meetings and dictations save as Markdown. Pick any folder you want agents to read — an Obsidian vault works great."
                ),
                automationIdentifier: "transcripted.settings.storage.capture-library",
                showsDivider: unavailableCaptureLibraryPath == nil
            ) {
                HStack(spacing: 8) {
                    Text((captureLibraryURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 190, alignment: .trailing)
                        .help(captureLibraryURL.path)

                    SettingsInlineActionButton(title: "Change…", symbolName: "folder") {
                        onChooseCaptureLibrary()
                    }
                    .disabled(captureLibraryMigrationInProgress)

                    SettingsInlineActionButton(title: "Reset") {
                        onResetCaptureLibrary()
                    }
                    .disabled(captureLibraryMigrationInProgress)
                }
            }

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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    private var deleteAudioRow: some View {
        SettingsControlRow(
            title: "Delete audio",
            info: GeneralInfo(
                title: "Delete audio",
                message: "Transcripts are kept forever — this only deletes replay audio. Choosing 7 or 30 days asks before the first cleanup. Audio is compressed from WAV to a smaller M4A automatically after each transcript saves."
            ),
            automationIdentifier: "transcripted.settings.storage.delete-audio"
        ) {
            Picker("Delete audio", selection: audioRetentionWindowBinding) {
                ForEach(AudioRetentionWindow.allCases) { window in
                    Text(window.title).tag(window)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var freeUpSpaceRow: some View {
        SettingsControlRow(
            title: "Free up space",
            info: GeneralInfo(
                title: "Free up space",
                message: "Removes old model files Transcripted no longer needs. The models you're using stay."
            ),
            automationIdentifier: "transcripted.settings.storage.free-up-space"
        ) {
            HStack(spacing: 8) {
                if modelCacheLoading, modelCacheSnapshot == nil {
                    ProgressView().controlSize(.small)
                } else if let snapshot = modelCacheSnapshot {
                    let includeWhisper = !effectiveTranscriptionModelIsWhisper
                    let reclaimableBytes = snapshot.reclaimableBytes(includeWhisper: includeWhisper)
                    Text(reclaimableBytes > 0
                        ? "\(snapshot.formattedReclaimableSize(includeWhisper: includeWhisper)) reclaimable"
                        : "Nothing to clean up")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if reclaimableBytes > 0 {
                        SettingsInlineActionButton(
                            title: modelCacheCleanupInProgress ? "Removing…" : "Free Up Space",
                            tone: .destructive
                        ) {
                            showReclaimableCacheCleanupConfirmation = true
                        }
                        .disabled(modelCacheCleanupInProgress || modelCacheLoading)
                    }
                } else {
                    SettingsInlineActionButton(title: "Scan") {
                        onRefreshModelCacheSnapshot()
                    }
                }
            }
        }
    }

    private var supportFilesRow: some View {
        SettingsControlRow(
            title: "Support files",
            info: GeneralInfo(
                title: "Support files",
                message: "App state, cache, and logs — useful when debugging something with support. Not your transcripts."
            ),
            automationIdentifier: "transcripted.settings.storage.support-files",
            showsDivider: false
        ) {
            SettingsInlineActionButton(title: "Show in Finder", symbolName: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([supportFilesFolder])
            }
        }
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
