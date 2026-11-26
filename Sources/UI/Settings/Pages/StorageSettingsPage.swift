import Foundation
import SwiftUI

/// Settings › Library: four rows — the capture folder, how long meeting
/// audio and dictation audio are kept, and Free up space (what the voice
/// models take, with a Review… breakdown and the cleanup). Row explanations
/// live in ⓘ popovers. Local confirmation state lives here; persisted state
/// and filesystem work route through injected callbacks. Support files moved
/// to Advanced (`SupportFilesSettingsRow`).
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
    /// Where Writing keeps its model, so the breakdown can list its size.
    /// Read-only here; Writing's own page deletes it.
    let writingModelRoot: URL?
    /// Titles and summaries is off, so its downloaded model can go.
    let meetingTitlesModelIsReclaimable: Bool

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

    /// Pending meeting and dictation audio windows, one slot each.
    @State private var retentionPrompts = StorageRetentionPrompts()
    @State private var showReclaimableCacheCleanupConfirmation = false
    @State private var showsModelBreakdown = false
    @State private var writingModelBytes: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCardLabel(text: "Library")
            SettingsCard {
                libraryRow
                deleteAudioRow
                keepDictationAudioRow
                freeUpSpaceRow
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
                            .font(LibraryTokens.meta)
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
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    failureDetailsButton(modelCacheCleanupStatusDetails)
                }
                .padding(.leading, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.page.storage")
        .id("transcripted.settings.section.storage")
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
                title: "Folder",
                info: GeneralInfo(
                    title: "Folder",
                    message: "Where meetings and dictations save as Markdown. Any folder works, including a notes vault your agents read."
                ),
                automationIdentifier: "transcripted.settings.storage.capture-library",
                showsDivider: unavailableCaptureLibraryPath == nil
            ) {
                HStack(spacing: 8) {
                    Text((captureLibraryURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
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
                    Text("Transcripted can't reach \(unavailableCaptureLibraryPath), so it's saving to the default folder until that one is back or you pick another.")
                        .font(LibraryTokens.meta)
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
            title: "Keep meeting audio",
            info: GeneralInfo(
                title: "Keep meeting audio",
                message: "Transcripts are always kept; this is only the audio. A shorter window asks before it deletes anything."
            ),
            automationIdentifier: "transcripted.settings.storage.delete-audio"
        ) {
            Picker("Keep meeting audio", selection: audioRetentionWindowBinding) {
                ForEach(AudioRetentionWindow.allCases) { window in
                    Text(Self.keepTitle(for: window)).tag(window)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    /// The stored meeting window says when audio is deleted ("Never"); the
    /// row asks how long it's kept, so `.never` reads "Forever".
    static func keepTitle(for window: AudioRetentionWindow) -> String {
        window == .never ? "Forever" : window.title
    }

    private var keepDictationAudioRow: some View {
        SettingsControlRow(
            title: "Keep dictation audio",
            info: GeneralInfo(
                title: "Keep dictation audio",
                message: "Lets you play back and transcribe dictations again. Text is always kept."
            ),
            automationIdentifier: "transcripted.settings.storage.keep-dictation-audio"
        ) {
            Picker("Keep dictation audio", selection: dictationAudioKeepWindowBinding) {
                ForEach(DictationAudioKeepWindow.allCases) { window in
                    Text(window.title).tag(window)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    /// Model-cache inspection and cleanup (a protected surface): the row says
    /// what can go, Review… shows what each voice model store takes and holds
    /// the cleanup.
    private var freeUpSpaceRow: some View {
        SettingsControlRow(
            title: "Free up space",
            info: GeneralInfo(
                title: "Free up space",
                message: "Removes old voice model files Transcripted no longer needs. The ones you use stay."
            ),
            automationIdentifier: "transcripted.settings.storage.free-up-space",
            showsDivider: false
        ) {
            HStack(spacing: 8) {
                if modelCacheLoading, modelCacheSnapshot == nil {
                    ProgressView().controlSize(.small)
                } else if let snapshot = modelCacheSnapshot {
                    let reclaimableBytes = snapshot.reclaimableBytes(
                        includeWhisper: includeWhisperInCleanup,
                        includeMeetingTitles: meetingTitlesModelIsReclaimable
                    )
                    Text(reclaimableBytes > 0
                        ? "\(snapshot.formattedReclaimableSize(includeWhisper: includeWhisperInCleanup, includeMeetingTitles: meetingTitlesModelIsReclaimable)) can go"
                        : "Nothing to clean up")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)

                    SettingsInlineActionButton(
                        title: "Review…",
                        automationIdentifier: "transcripted.settings.storage.free-up-space.review"
                    ) {
                        showsModelBreakdown = true
                    }
                    .popover(isPresented: $showsModelBreakdown, arrowEdge: .bottom) {
                        modelBreakdown(snapshot)
                    }
                } else {
                    SettingsInlineActionButton(title: "Scan") {
                        onRefreshModelCacheSnapshot()
                    }
                }
            }
        }
    }

    private var includeWhisperInCleanup: Bool {
        !effectiveTranscriptionModelIsWhisper
    }

    /// What each store takes, then the cleanup. Sizes only; nothing here
    /// opens a file.
    private func modelBreakdown(_ snapshot: ModelCacheSnapshot) -> some View {
        let reclaimableBytes = snapshot.reclaimableBytes(
            includeWhisper: includeWhisperInCleanup,
            includeMeetingTitles: meetingTitlesModelIsReclaimable
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text("Voice models on this Mac")
                .textRole(.heading)

            VStack(alignment: .leading, spacing: 6) {
                let staleBytes = snapshot.staleFluidAudioModelBytes
                    + (includeWhisperInCleanup ? 0 : snapshot.staleWhisperModelBytes)
                breakdownLine("Speech models", snapshot.formattedFluidAudioModelsSize)
                breakdownLine("Old models", staleBytes > 0
                    ? "\(ModelCacheInventory.formattedByteCount(staleBytes)), can go"
                    : "None")
                breakdownLine("Whisper", snapshot.whisperModelsBytes > 0
                    ? (includeWhisperInCleanup
                        ? "\(snapshot.formattedWhisperModelsSize), can go"
                        : "\(snapshot.formattedWhisperModelsSize), in use")
                    : "None")
                breakdownLine("App cache", snapshot.formattedTranscriptedCacheSize)
                breakdownLine("Meeting titles", snapshot.meetingTitlesModelBytes > 0
                    ? (meetingTitlesModelIsReclaimable
                        ? "\(snapshot.formattedMeetingTitlesModelSize), can go"
                        : "\(snapshot.formattedMeetingTitlesModelSize), in use")
                    : "None")
                if writingModelRoot != nil {
                    breakdownLine("Writing model", writingModelBytes.map { bytes in
                        bytes > 0 ? "\(ModelCacheInventory.formattedByteCount(bytes)), on the Writing page" : "None"
                    } ?? "…")
                }
            }

            HStack(spacing: 8) {
                if reclaimableBytes > 0 {
                    SettingsInlineActionButton(
                        title: modelCacheCleanupInProgress ? "Removing…" : "Free up space",
                        tone: .destructive
                    ) {
                        // Raise the confirm once the popover is gone: a
                        // dialog presented while a popover is closing can be
                        // dropped, leaving the button looking dead.
                        showsModelBreakdown = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showReclaimableCacheCleanupConfirmation = true
                        }
                    }
                    .disabled(modelCacheCleanupInProgress || modelCacheLoading)
                }

                SettingsInlineActionButton(title: "Rescan", symbolName: "arrow.clockwise") {
                    onRefreshModelCacheSnapshot()
                    loadWritingModelBytes()
                }
                .disabled(modelCacheLoading)
                .help("Rescan model storage sizes.")
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .task { loadWritingModelBytes() }
    }

    private func breakdownLine(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(LibraryTokens.body)
                .foregroundStyle(LibraryTokens.ink)
            Spacer(minLength: 12)
            Text(value)
                .font(LibraryTokens.meta)
                .monospacedDigit()
                .foregroundStyle(LibraryTokens.ink2)
        }
    }

    /// Writing's model size, measured off the main thread. Only file sizes
    /// are read, the same walk Writing's own storage meter does.
    private func loadWritingModelBytes() {
        guard let root = writingModelRoot else { return }
        Task {
            let bytes = await Task.detached(priority: .utility) {
                WritingStorageUsage.fileBytes(under: root)
            }.value
            writingModelBytes = bytes
        }
    }

    private var audioRetentionWindowBinding: Binding<AudioRetentionWindow> {
        Binding(
            get: { audioRetentionWindow },
            set: { window in
                performRetention(retentionPrompts.pickMeeting(window, current: audioRetentionWindow))
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
                performRetention(retentionPrompts.pickDictation(window, current: dictationAudioKeepWindow))
            }
        )
    }

    /// Routes an audio-window change to its own setting's callback only.
    func performRetention(_ effect: StorageRetentionEffect) {
        effect.perform(
            applyMeeting: onApplyAudioRetentionWindow,
            applyDictation: onApplyDictationAudioKeepWindow
        )
    }
}

private extension StorageSettingsPage {
    var confirmationStates: StorageConfirmationStates {
        retentionPrompts.states(
            hasCaptureLibraryChoice: captureLibraryChoicePromptBinding.wrappedValue
                && pendingCaptureLibraryChoice != nil,
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
                case .meetingAudio, .dictationAudio:
                    retentionPrompts.dismiss(slot)
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
                Button("Copy instead") {
                    onCopyCapturesThenSwitchLibrary(choice)
                }
                Button("Just switch") {
                    onSwitchLibraryWithoutCopying(choice)
                }
            }
            Button("Cancel", role: .cancel) {}
        case .meetingAudio:
            // Built with the alert, so it holds this prompt's window whether
            // SwiftUI runs the action before or after dismissal clears it.
            let effect = retentionPrompts.confirmEffect(for: .meetingAudio)
            if effect != .none {
                Button("Delete old audio", role: .destructive) {
                    performRetention(effect)
                }
            }
            // Return lands on the safe choice, as before.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        case .dictationAudio:
            let effect = retentionPrompts.confirmEffect(for: .dictationAudio)
            if effect != .none {
                Button("Delete audio", role: .destructive) {
                    performRetention(effect)
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
            Text(retentionPrompts.pendingMeeting.map(StorageConfirmationPolicy.meetingAudioMessage(for:)) ?? "")
        case .dictationAudio:
            Text(retentionPrompts.pendingDictation.map(StorageConfirmationPolicy.dictationAudioMessage(for:)) ?? "")
        case .freeUpSpace:
            Text(StorageConfirmationPolicy.freeUpSpaceMessage(
                whisperIsSelected: effectiveTranscriptionModelIsWhisper,
                removesMeetingTitlesModel: meetingTitlesModelIsReclaimable
                    && (modelCacheSnapshot?.meetingTitlesModelBytes ?? 0) > 0
            ))
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
            return "Move to new folder"
        case .defaultLibrary:
            return "Move to default folder"
        }
    }

    var promptMessage: String {
        "Your current library has saved meetings or dictations. Move puts them in the \(destinationDescription) and sends the old copies to the Trash. Copy instead keeps them in both places, which uses twice the space. Just switch leaves everything in \(currentLibrary.path), and Transcripted and connected agents will only see the \(destinationDescription)."
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
