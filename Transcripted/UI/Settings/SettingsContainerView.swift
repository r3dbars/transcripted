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
    @AppStorage("enableQwenSpeakerInference") private var enableQwenInference: Bool = true
    @AppStorage("enableObsidianFormat") private var enableObsidianFormat: Bool = false
    @AppStorage("autoRecordMeetings") private var autoRecordMeetings: Bool = false

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
                    StatsSettingsSection(
                        statsService: statsService,
                        openTranscriptsFolder: openTranscriptsFolder
                    )

                    // Failed transcriptions (only if any)
                    if let manager = failedTranscriptionManager, manager.count > 0 {
                        FailedTranscriptionsSettingsSection(
                            failedTranscriptionManager: failedTranscriptionManager,
                            taskManager: taskManager,
                            retryingIds: $retryingIds
                        )
                    }

                    // Voice Fingerprints (collapsible)
                    SpeakersSettingsSection(
                        speakers: $speakers,
                        speakersExpanded: $speakersExpanded,
                        editingId: $editingId,
                        editingName: $editingName,
                        deleteConfirmId: $deleteConfirmId,
                        clipPlayer: clipPlayer
                    )

                    // Preferences
                    ProfileSettingsSection(
                        userName: $userName,
                        saveLocation: $saveLocation,
                        chooseSaveFolder: chooseSaveFolder
                    )

                    MeetingDetectionSettingsSection(
                        autoRecordMeetings: $autoRecordMeetings
                    )

                    SpeakerIntelligenceSettingsSection(
                        enableQwenInference: $enableQwenInference,
                        qwenService: qwenService,
                        qwenModelCached: $qwenModelCached
                    )

                    AIServicesSettingsSection()
                }
                .padding(Spacing.lg)
                .padding(.bottom, Spacing.xl)
            }
        }
        .frame(minWidth: 500, maxWidth: 800, minHeight: 400, maxHeight: 900)
        .background(Color.panelCharcoal)
        .onAppear {
            // object(forKey:) returns nil for unset keys; default to enabled for new users
            if let val = UserDefaults.standard.object(forKey: "enableUISounds") as? Bool {
                enableSounds = val
            } else {
                enableSounds = true
            }
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

    // MARK: - Actions

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select where to save your transcripts"
        let directoryPath = saveLocation.isEmpty ? TranscriptSaver.defaultSaveDirectory.path : saveLocation
        panel.directoryURL = URL(fileURLWithPath: directoryPath)
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

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    SettingsContainerView(
        statsService: StatsService.shared,
        navigationState: SettingsNavigationState()
    )
}
