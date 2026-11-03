import Foundation
import SwiftUI

/// The Storage portion of the combined settings page (2026-08 card restyle):
/// five always-visible card rows — capture library, delete-audio window,
/// keep-dictation-audio window, free-up-space, and a support-files reveal. Row explanations live in ⓘ
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
    let dictationAudioKeepWindow: DictationAudioKeepWindow

    let modelCacheSnapshot: ModelCacheSnapshot?
    let modelCacheLoading: Bool
    let modelCacheCleanupInProgress: Bool
    let modelCacheCleanupStatus: String?
    let modelCacheCleanupStatusDetails: String?
    let effectiveTranscriptionModelIsWhisper: Bool

    let supportFilesFolder: URL

    let onChooseCaptureLibrary: () -> Void
    let onResetCaptureLibrary: () -> Void
    let onMoveCapturesThenSwitchLibrary: (PendingCaptureLibraryChoice) -> Void
    let onCopyCapturesThenSwitchLibrary: (PendingCaptureLibraryChoice) -> Void
    let onSwitchLibraryWithoutCopying: (PendingCaptureLibraryChoice) -> Void
    let onRemoveReclaimableModelCaches: () -> Void
    let onLoadModelCacheSnapshot: () -> Void
    let onRefreshModelCacheSnapshot: () -> Void
    let onApplyAudioRetentionWindow: (AudioRetentionWindow) -> Void
    let onApplyDictationAudioKeepWindow: (DictationAudioKeepWindow) -> Void
    let failureDetailsButton: (String?) -> FailureDetailsButton

    @State private var pendingAudioRetentionWindow: AudioRetentionWindow?
    @State private var pendingDictationAudioKeepWindow: DictationAudioKeepWindow?
    @State private var showReclaimableCacheCleanupConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCardLabel(text: "Storage")
            SettingsCard {
                libraryRow
                deleteAudioRow
                keepDictationAudioRow
                freeUpSpaceRow
                supportFilesRow
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transcripted.settings.section.storage")

            // Two independent status lines: a lingering migration status must
            // not mask a later cleanup result (or the other way around).
            if let status = captureLibraryMigrationStatus {
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
                        failureDetailsButton(captureLibraryMigrationStatusDetails)
                    }
                }
                .padding(.leading, 4)
            }

            if let status = modelCacheCleanupStatus {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(LibraryTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    failureDetailsButton(modelCacheCleanupStatusDetails)
                }
                .padding(.leading, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.page.storage")
        .onAppear {
            if modelCacheSnapshot == nil, !modelCacheLoading {
                onLoadModelCacheSnapshot()
            }
        }
        // One presenter for every Storage prompt. Four stacked alert modifiers
        // shadowed each other, so picking a shorter "Delete meeting audio
        // after" or "Keep dictation audio" window set its pending value, no
        // alert appeared, and the segment snapped back. Routing and copy live
        // in StorageConfirmationPolicy.
        .alert(
            Text(activeConfirmationTitle),
            isPresented: storageConfirmationIsPresented,
            presenting: activeConfirmationSlot
        ) { slot in
            storageConfirmationActions(for: slot)
        } message: { slot in
            storageConfirmationMessage(for: slot)
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
            title: "Delete meeting audio after",
            info: GeneralInfo(
                title: "Delete meeting audio after",
                message: "Transcripts are kept forever. This only deletes meeting audio. Choosing 7 or 30 days asks before the first cleanup. Audio is shrunk to a smaller file automatically after each transcript saves."
            ),
            automationIdentifier: "transcripted.settings.storage.delete-audio"
        ) {
            Picker("Delete meeting audio after", selection: audioRetentionWindowBinding) {
                ForEach(AudioRetentionWindow.allCases) { window in
                    Text(window.title).tag(window)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private var keepDictationAudioRow: some View {
        SettingsControlRow(
            title: "Keep dictation audio",
            info: GeneralInfo(
                title: "Keep dictation audio",
                message: "Lets you play back and re-transcribe dictations. Text is always kept."
            ),
            automationIdentifier: "transcripted.settings.storage.keep-dictation-audio"
        ) {
            Picker("Keep dictation audio", selection: dictationAudioKeepWindowBinding) {
                ForEach(DictationAudioKeepWindow.allCases) { window in
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

                    SettingsInlineActionButton(title: "Rescan", symbolName: "arrow.clockwise") {
                        onRefreshModelCacheSnapshot()
                    }
                    .disabled(modelCacheLoading)
                    .help("Rescan model storage sizes.")
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
                if StorageConfirmationPolicy.meetingChoiceNeedsConfirmation(
                    from: audioRetentionWindow,
                    to: window
                ) {
                    pendingAudioRetentionWindow = window
                } else {
                    onApplyAudioRetentionWindow(window)
                }
            }
        )
    }
}

private extension StorageSettingsPage {
    /// A shorter window (or Don't keep) can delete audio already kept, so it
    /// asks first, like the meeting row.
    var dictationAudioKeepWindowBinding: Binding<DictationAudioKeepWindow> {
        Binding(
            get: { dictationAudioKeepWindow },
            set: { window in
                guard window != dictationAudioKeepWindow else { return }
                if dictationAudioKeepWindow.deletesKeptAudio(switchingTo: window) {
                    pendingDictationAudioKeepWindow = window
                } else {
                    onApplyDictationAudioKeepWindow(window)
                }
            }
        )
    }
}

private extension StorageSettingsPage {
    var confirmationStates: StorageConfirmationStates {
        StorageConfirmationStates(
            hasCaptureLibraryChoice: captureLibraryChoicePromptBinding.wrappedValue
                && pendingCaptureLibraryChoice != nil,
            pendingMeetingAudioWindow: pendingAudioRetentionWindow,
            pendingDictationAudioWindow: pendingDictationAudioKeepWindow,
            wantsFreeUpSpace: showReclaimableCacheCleanupConfirmation
        )
    }

    var activeConfirmationSlot: StorageConfirmationSlot? {
        StorageConfirmationPolicy.activeSlot(confirmationStates)
    }

    var activeConfirmationTitle: String {
        activeConfirmationSlot.map {
            StorageConfirmationPolicy.title(for: $0, states: confirmationStates)
        } ?? ""
    }

    /// Dismissal clears only the prompt that was showing, so a second pending
    /// prompt (rare) presents next instead of being wiped.
    var storageConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { activeConfirmationSlot != nil },
            set: { isPresented in
                guard !isPresented, let slot = activeConfirmationSlot else { return }
                switch slot {
                case .captureLibrary:
                    captureLibraryChoicePromptBinding.wrappedValue = false
                case .meetingAudio:
                    pendingAudioRetentionWindow = nil
                case .dictationAudio:
                    pendingDictationAudioKeepWindow = nil
                case .freeUpSpace:
                    showReclaimableCacheCleanupConfirmation = false
                }
            }
        )
    }

    @ViewBuilder
    func storageConfirmationActions(for slot: StorageConfirmationSlot) -> some View {
        switch slot {
        case .captureLibrary:
            if let choice = pendingCaptureLibraryChoice {
                Button(choice.moveButtonTitle) {
                    onMoveCapturesThenSwitchLibrary(choice)
                }
                .keyboardShortcut(.defaultAction)
                Button("Copy Instead") {
                    onCopyCapturesThenSwitchLibrary(choice)
                }
                Button("Just Switch") {
                    onSwitchLibraryWithoutCopying(choice)
                }
            }
            Button("Cancel", role: .cancel) {}
        case .meetingAudio:
            if let window = pendingAudioRetentionWindow {
                Button("Delete Old Audio", role: .destructive) {
                    onApplyAudioRetentionWindow(window)
                }
            }
            // Return lands on the safe choice, as before.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        case .dictationAudio:
            if let window = pendingDictationAudioKeepWindow {
                Button("Delete Audio", role: .destructive) {
                    onApplyDictationAudioKeepWindow(window)
                }
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        case .freeUpSpace:
            Button("Remove", role: .destructive) {
                onRemoveReclaimableModelCaches()
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    func storageConfirmationMessage(for slot: StorageConfirmationSlot) -> some View {
        switch slot {
        case .captureLibrary:
            Text(pendingCaptureLibraryChoice?.promptMessage ?? "")
        case .meetingAudio:
            Text(pendingAudioRetentionWindow.map(StorageConfirmationPolicy.meetingAudioMessage(for:)) ?? "")
        case .dictationAudio:
            Text(pendingDictationAudioKeepWindow.map(StorageConfirmationPolicy.dictationAudioMessage(for:)) ?? "")
        case .freeUpSpace:
            Text(effectiveTranscriptionModelIsWhisper
                ? "Transcripted will remove known old Parakeet folders. Whisper stays because it is selected."
                : "Transcripted will remove known old Parakeet folders and downloaded Whisper model files. The Parakeet model you use stays.")
        }
    }
}

struct PendingCaptureLibraryChoice: Equatable {
    let currentLibrary: URL
    let newLibrary: URL
    let preferenceURL: URL?
    let destinationKind: CaptureLibraryDestinationKind

    var moveButtonTitle: String {
        switch destinationKind {
        case .custom:
            return "Move to New Folder"
        case .defaultLibrary:
            return "Move to Default Folder"
        }
    }

    var promptMessage: String {
        "Your current library has saved meetings or dictations. Move puts them in the \(destinationDescription) and sends the old copies to the Trash. Copy Instead keeps them in both places, which uses twice the space. Just Switch leaves everything in \(currentLibrary.path), and Transcripted and connected agents will only see the \(destinationDescription)."
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
