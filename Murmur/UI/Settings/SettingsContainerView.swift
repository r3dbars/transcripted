import SwiftUI
import AVFoundation
import AppKit

/// Single-page settings view — no sidebar, no tabs
/// Top bar → Stats → Voice Fingerprints (collapsible) → Preferences
@available(macOS 26.0, *)
struct SettingsContainerView: View {

    @ObservedObject var statsService: StatsService
    @ObservedObject var navigationState: SettingsNavigationState
    var failedTranscriptionManager: FailedTranscriptionManager?
    var taskManager: TranscriptionTaskManager?

    // MARK: - Preferences State

    @AppStorage("transcriptSaveLocation") private var saveLocation: String = ""
    @AppStorage("userName") private var userName: String = ""
    @AppStorage("useAuroraRecording") private var useAuroraRecording: Bool = false
    @AppStorage("enableQwenSpeakerInference") private var enableQwenInference: Bool = true

    @State private var enableSounds: Bool = true
    @State private var qwenModelCached: Bool = false
    @StateObject private var qwenService = QwenService()

    // Speakers
    @State private var speakersExpanded = false
    @State private var speakers: [SpeakerProfile] = []
    @State private var editingId: UUID?
    @State private var editingName: String = ""
    @State private var deleteConfirmId: UUID?
    @StateObject private var clipPlayer = ClipAudioPlayer()

    // Failed transcriptions
    @State private var retryingIds: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            SettingsTopBar()

            Rectangle()
                .fill(Color.panelCharcoalSurface)
                .frame(height: 1)

            // Single scrolling page
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    // Stats + Open Folder
                    statsSection

                    // Failed transcriptions (only if any)
                    if let manager = failedTranscriptionManager, manager.count > 0 {
                        failedTranscriptionsSection
                    }

                    // Voice Fingerprints (collapsible)
                    speakersSection

                    // Preferences
                    profileSection

                    appearanceSection

                    speakerIntelligenceSection

                    aiServicesSection
                }
                .padding(Spacing.lg)
                .padding(.bottom, Spacing.xl)
            }
        }
        .frame(minWidth: 500, maxWidth: 800, minHeight: 400, maxHeight: 900)
        .background(Color.panelCharcoal)
        .onAppear {
            enableSounds = UserDefaults.standard.bool(forKey: "enableUISounds") != false
            speakers = SpeakerDatabase.shared.allSpeakers()
            qwenModelCached = QwenService.isModelCached
        }
        // Migration overlay
        .overlay {
            if navigationState.isMigrating {
                MigrationOverlayView(
                    progress: navigationState.migrationProgress,
                    status: navigationState.migrationStatus
                )
            }
        }
        .alert("Migration Complete", isPresented: $navigationState.showMigrationComplete) {
            Button("OK") {
                navigationState.showMigrationComplete = false
            }
        } message: {
            Text("Successfully imported \(navigationState.migratedCount) existing transcripts to your dashboard.")
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("ALL TIME")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.panelTextMuted)
                .tracking(0.8)

            HStack(spacing: Spacing.md) {
                HStack(spacing: Spacing.lg) {
                    statItem(
                        value: "\(statsService.totalRecordings)",
                        label: "meetings"
                    )

                    Text("|")
                        .foregroundColor(.panelTextMuted)

                    statItem(
                        value: statsService.formattedTotalHours,
                        label: "recorded"
                    )
                }

                Spacer()

                // Open folder + Refresh
                HStack(spacing: Spacing.sm) {
                    Button {
                        openTranscriptsFolder()
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "folder")
                                .font(.system(size: 12))
                            Text("Open Folder")
                                .font(.bodySmall)
                        }
                        .foregroundColor(.panelTextSecondary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background {
                            RoundedRectangle(cornerRadius: Radius.lawsButton)
                                .fill(Color.panelCharcoalSurface)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await statsService.refreshStats() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundColor(.panelTextMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .fill(Color.panelCharcoalElevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .stroke(Color.panelCharcoalSurface, lineWidth: 1)
            }
        }
    }

    private func statItem(value: String, label: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(value)
                .font(.headingMedium)
                .foregroundColor(.panelTextPrimary)

            Text(label)
                .font(.bodySmall)
                .foregroundColor(.panelTextSecondary)
        }
    }

    // MARK: - Failed Transcriptions

    @ViewBuilder
    private var failedTranscriptionsSection: some View {
        if let manager = failedTranscriptionManager {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.warningAmber)
                        Text("Failed Transcriptions")
                            .font(.bodyMedium)
                            .foregroundColor(.panelTextPrimary)
                        Text("(\(manager.count))")
                            .font(.bodySmall)
                            .foregroundColor(.panelTextMuted)
                    }

                    Spacer()

                    if taskManager != nil, !manager.failedTranscriptions.isEmpty {
                        Button {
                            for failed in manager.failedTranscriptions {
                                retryFailed(failed.id)
                            }
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                                Text("Retry All")
                                    .font(.caption)
                            }
                            .foregroundColor(.accentBlueLight)
                        }
                        .buttonStyle(.plain)
                        .disabled(!retryingIds.isEmpty)
                    }
                }

                VStack(spacing: Spacing.xs) {
                    ForEach(manager.failedTranscriptions.prefix(3)) { failed in
                        HStack(spacing: Spacing.sm) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failed.formattedTimestamp)
                                    .font(.bodySmall)
                                    .foregroundColor(.panelTextPrimary)
                                Text(failed.shortErrorMessage)
                                    .font(.caption)
                                    .foregroundColor(.panelTextMuted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if retryingIds.contains(failed.id) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 20, height: 20)
                            } else if taskManager != nil {
                                Button {
                                    retryFailed(failed.id)
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12))
                                        .foregroundColor(.accentBlueLight)
                                }
                                .buttonStyle(.plain)
                            }
                            Button {
                                failedTranscriptionManager?.deleteFailedTranscription(id: failed.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10))
                                    .foregroundColor(.panelTextMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, Spacing.xs)
                    }

                    if manager.count > 3 {
                        Text("and \(manager.count - 3) more...")
                            .font(.caption)
                            .foregroundColor(.panelTextMuted)
                    }
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Radius.lawsCard)
                        .fill(Color.panelCharcoalElevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.lawsCard)
                                .stroke(Color.warningAmber.opacity(0.3), lineWidth: 1)
                        }
                }
            }
        }
    }

    private func retryFailed(_ id: UUID) {
        retryingIds.insert(id)
        Task {
            let _ = await taskManager?.retryFailedTranscription(failedId: id) ?? false
            await MainActor.run { retryingIds.remove(id) }
        }
    }

    // MARK: - Speakers Section (Collapsible)

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("VOICE FINGERPRINTS")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.panelTextMuted)
                .tracking(0.8)

            VStack(alignment: .leading, spacing: 0) {
                // Collapsible header
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        speakersExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: speakersExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.panelTextMuted)
                            .frame(width: 16)

                        Text("\(speakers.count) speaker\(speakers.count == 1 ? "" : "s")")
                            .font(.bodyMedium)
                            .foregroundColor(.panelTextPrimary)

                        Spacer()

                        Text("Tap to manage")
                            .font(.caption)
                            .foregroundColor(.panelTextMuted)
                    }
                    .padding(Spacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Expanded speaker list
                if speakersExpanded {
                    Rectangle()
                        .fill(Color.panelCharcoalSurface)
                        .frame(height: 1)
                        .padding(.horizontal, Spacing.md)

                    VStack(spacing: Spacing.xs) {
                        ForEach(speakers) { speaker in
                            inlineSpeakerRow(speaker)
                        }

                        if speakers.isEmpty {
                            Text("No speakers yet — record a call with system audio to start")
                                .font(.caption)
                                .foregroundColor(.panelTextMuted)
                                .padding(.vertical, Spacing.md)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.md)
                    .padding(.top, Spacing.sm)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .fill(Color.panelCharcoalElevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .stroke(Color.panelCharcoalSurface, lineWidth: 1)
            }
        }
    }

    private func inlineSpeakerRow(_ speaker: SpeakerProfile) -> some View {
        HStack(spacing: Spacing.sm) {
            // Play button (only if persistent clip exists)
            if SpeakerClipExtractor.persistentClipURL(for: speaker.id) != nil {
                Button(action: { toggleClipPlayback(for: speaker.id) }) {
                    Image(systemName: isClipPlaying(speaker.id) ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                        .foregroundColor(isClipPlaying(speaker.id) ? .accentBlue : .panelTextMuted)
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .help(isClipPlaying(speaker.id) ? "Stop" : "Play voice clip")
            }

            // Simple avatar
            ZStack {
                Circle()
                    .fill(Color.panelCharcoalSurface)
                    .frame(width: 28, height: 28)

                Text(speaker.displayName?.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.panelTextSecondary)
            }

            // Name
            if editingId == speaker.id {
                TextField("Name", text: $editingName, onCommit: {
                    commitNameEdit(for: speaker.id)
                })
                .textFieldStyle(.plain)
                .font(.bodySmall)
                .foregroundColor(.panelTextPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.panelCharcoalSurface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentBlue, lineWidth: 1)
                        }
                }
                .onExitCommand { editingId = nil }
            } else {
                Text(speaker.displayName ?? "Unknown")
                    .font(.bodySmall)
                    .foregroundColor(speaker.displayName != nil ? .panelTextPrimary : .panelTextMuted)
                    .italic(speaker.displayName == nil)
                    .onTapGesture {
                        editingName = speaker.displayName ?? ""
                        editingId = speaker.id
                    }
            }

            // Meta
            Text("\(speaker.callCount) call\(speaker.callCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.panelTextMuted)

            Spacer()

            // Actions
            if deleteConfirmId == speaker.id {
                HStack(spacing: Spacing.xs) {
                    Text("Delete?")
                        .font(.caption)
                        .foregroundColor(.errorRed)
                    Button("Yes") {
                        SpeakerClipExtractor.deletePersistedClip(for: speaker.id)
                        SpeakerDatabase.shared.deleteSpeaker(id: speaker.id)
                        deleteConfirmId = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            speakers = SpeakerDatabase.shared.allSpeakers()
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.errorRed)
                    .buttonStyle(.plain)
                    Button("No") { deleteConfirmId = nil }
                        .font(.caption)
                        .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: Spacing.xs) {
                    if editingId != speaker.id {
                        Button {
                            editingName = speaker.displayName ?? ""
                            editingId = speaker.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11))
                                .foregroundColor(.panelTextMuted)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        deleteConfirmId = speaker.id
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.panelTextMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func commitNameEdit(for id: UUID) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editingId = nil
            return
        }
        SpeakerDatabase.shared.setDisplayName(id: id, name: trimmed, source: "user_manual")
        editingId = nil
        // Retroactively update all transcripts referencing this speaker
        Task.detached {
            TranscriptSaver.retroactivelyUpdateSpeaker(dbId: id, newName: trimmed)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            speakers = SpeakerDatabase.shared.allSpeakers()
        }
    }

    // MARK: - Clip Playback Helpers

    private func isClipPlaying(_ speakerId: UUID) -> Bool {
        guard let clipURL = SpeakerClipExtractor.persistentClipURL(for: speakerId) else { return false }
        return clipPlayer.isPlaying && clipPlayer.currentClipURL == clipURL
    }

    private func toggleClipPlayback(for speakerId: UUID) {
        guard let clipURL = SpeakerClipExtractor.persistentClipURL(for: speakerId) else { return }
        if isClipPlaying(speakerId) {
            clipPlayer.stop()
        } else {
            clipPlayer.play(url: clipURL)
        }
    }

    // MARK: - Profile Section

    private var profileSection: some View {
        SettingsSectionCard(icon: "person.fill", title: "Profile") {
            VStack(spacing: Spacing.md) {
                SettingsTextField(
                    title: "Your Name",
                    placeholder: "Enter your name",
                    text: $userName
                )

                Divider().background(Color.panelCharcoalSurface)

                SettingsPathRow(
                    title: "Save Location",
                    path: saveLocation,
                    defaultPath: "~/Documents/Transcripted/",
                    onChoose: chooseSaveFolder
                )
            }
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        SettingsSectionCard(icon: "paintbrush.fill", title: "Appearance") {
            VStack(spacing: Spacing.md) {
                SettingsToggleRow(
                    title: "Aurora Recording Indicator",
                    description: "Flowing color animation during recording",
                    isOn: $useAuroraRecording
                )

                Divider().background(Color.panelCharcoalSurface)

                SettingsToggleRow(
                    title: "Sound Feedback",
                    description: "Play sounds when recording starts/stops",
                    isOn: Binding(
                        get: { enableSounds },
                        set: { newValue in
                            enableSounds = newValue
                            UserDefaults.standard.set(newValue, forKey: "enableUISounds")
                        }
                    )
                )
            }
        }
    }

    // MARK: - Speaker Intelligence Section

    private var speakerIntelligenceSection: some View {
        SettingsSectionCard(icon: "sparkles", title: "Speaker Intelligence") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SettingsToggleRow(
                    title: "Auto-Detect Speaker Names",
                    description: "Uses Qwen 4B to infer names from conversation context",
                    isOn: $enableQwenInference
                )

                Divider().background(Color.panelCharcoalSurface)

                // Model status + download
                HStack(spacing: Spacing.sm) {
                    Image(systemName: qwenModelStatusIcon)
                        .font(.system(size: 12))
                        .foregroundColor(qwenModelStatusColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Qwen 3.5-4B")
                            .font(.bodySmall)
                            .foregroundColor(.panelTextPrimary)

                        Text(qwenModelStatusText)
                            .font(.caption)
                            .foregroundColor(.panelTextMuted)
                    }

                    Spacer()

                    if qwenModelCached {
                        localBadge
                    } else if case .downloading(let progress) = qwenService.modelState {
                        // Download progress bar
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.panelTextMuted)
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 80)
                                .tint(.accentBlue)
                        }
                    } else if case .loading = qwenService.modelState {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 20, height: 20)
                    } else if case .failed = qwenService.modelState {
                        Button {
                            downloadQwenModel()
                        } label: {
                            Text("Retry")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.accentBlueLight)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            downloadQwenModel()
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 11))
                                Text("Download")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.accentBlueLight)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentBlue.opacity(0.15))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Reads the first 15 minutes of transcript to extract names from greetings and introductions. Runs 100% on-device.")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
            }
        }
    }

    // MARK: - Qwen Model Helpers

    private var qwenModelStatusIcon: String {
        if qwenModelCached { return "checkmark.circle.fill" }
        switch qwenService.modelState {
        case .downloading: return "arrow.down.circle.fill"
        case .loading: return "circle.dotted"
        case .failed: return "exclamationmark.circle.fill"
        default: return "arrow.down.circle"
        }
    }

    private var qwenModelStatusColor: Color {
        if qwenModelCached { return .attentionGreen }
        switch qwenService.modelState {
        case .downloading: return .accentBlue
        case .failed: return .errorRed
        default: return .panelTextMuted
        }
    }

    private var qwenModelStatusText: String {
        if qwenModelCached { return "Cached locally" }
        switch qwenService.modelState {
        case .downloading(let progress): return "Downloading… \(Int(progress * 100))%"
        case .loading: return "Loading model…"
        case .failed(let msg): return "Failed: \(msg)"
        default: return "Not downloaded (~2.5 GB)"
        }
    }

    private func downloadQwenModel() {
        Task {
            await qwenService.loadModel()
            if case .ready = qwenService.modelState {
                qwenModelCached = true
                qwenService.unload()  // Free memory — we just wanted to cache it
            }
        }
    }

    // MARK: - AI Services Section

    private var aiServicesSection: some View {
        SettingsSectionCard(icon: "sparkles", title: "AI Services") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Transcription Engine")
                    .font(.bodyMedium)
                    .foregroundColor(.panelTextPrimary)

                HStack(spacing: Spacing.sm) {
                    Image(systemName: "cpu.fill").foregroundColor(.attentionGreen)
                    Text("Parakeet TDT V3").font(.bodySmall).foregroundColor(.panelTextPrimary)
                    Spacer()
                    localBadge
                }

                HStack(spacing: Spacing.sm) {
                    Image(systemName: "person.2.fill").foregroundColor(.attentionGreen)
                    Text("Sortformer Diarization").font(.bodySmall).foregroundColor(.panelTextPrimary)
                    Spacer()
                    localBadge
                }

                Text("100% local transcription. No cloud API, no internet, no cost.")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    private var localBadge: some View {
        Text("Local")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.panelTextMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.panelCharcoalSurface)
            .cornerRadius(4)
    }

    // MARK: - Actions

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select where to save your transcripts"
        if let url = URL(string: saveLocation.isEmpty ? TranscriptSaver.defaultSaveDirectory.path : saveLocation) {
            panel.directoryURL = url
        }
        if panel.runModal() == .OK, let url = panel.url {
            saveLocation = url.path
        }
    }

    private func openTranscriptsFolder() {
        let transcriptsFolder: URL
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            transcriptsFolder = URL(fileURLWithPath: customPath)
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            transcriptsFolder = documentsPath.appendingPathComponent("Transcripted")
        }
        try? FileManager.default.createDirectory(at: transcriptsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(transcriptsFolder)
    }
}

// MARK: - Top Bar with Branding

@available(macOS 14.0, *)
struct SettingsTopBar: View {

    @State private var audioDeviceName: String = "Unknown"

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Branding
            HStack(spacing: Spacing.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.recordingCoral)

                Text("Transcripted")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.panelTextPrimary)
            }

            Spacer()

            // Audio device
            HStack(spacing: Spacing.xs) {
                Image(systemName: "mic")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.panelTextMuted)

                Text(audioDeviceName)
                    .font(.system(size: 12))
                    .foregroundColor(.panelTextSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .frame(height: 40)
        .background(Color.panelCharcoal)
        .onAppear {
            if let device = AVCaptureDevice.default(for: .audio) {
                audioDeviceName = device.localizedName
            } else {
                audioDeviceName = "No input device"
            }
        }
    }
}

// MARK: - Migration Overlay

@available(macOS 26.0, *)
struct MigrationOverlayView: View {
    let progress: Double
    let status: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            VStack(spacing: Spacing.lg) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 48))
                    .foregroundColor(.recordingCoral)

                Text("Importing Transcripts")
                    .font(.headingLarge)
                    .foregroundColor(.panelTextPrimary)

                VStack(spacing: Spacing.sm) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.panelCharcoalSurface)
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.recordingCoral)
                                .frame(width: geometry.size.width * progress, height: 8)
                        }
                    }
                    .frame(height: 8)
                    .frame(width: 300)

                    Text(status)
                        .font(.bodySmall)
                        .foregroundColor(.panelTextSecondary)
                        .lineLimit(1)
                }

                Text("\(Int(progress * 100))%")
                    .font(.headingMedium)
                    .foregroundColor(.panelTextMuted)
            }
            .padding(Spacing.xl)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsCard)
                    .fill(Color.panelCharcoalElevated)
            }
        }
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    SettingsContainerView(
        statsService: StatsService.shared,
        navigationState: SettingsNavigationState()
    )
}
