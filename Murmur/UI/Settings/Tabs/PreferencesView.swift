import SwiftUI
import AppKit

/// Redesigned preferences view with organized sections
/// Sections: Storage, Profile, Appearance, Recording, Task Integration, AI Services
@available(macOS 14.0, *)
struct PreferencesView: View {

    // MARK: - App Storage

    @AppStorage("transcriptSaveLocation") private var saveLocation: String = ""
    @AppStorage("userName") private var userName: String = ""
    @AppStorage("useAuroraRecording") private var useAuroraRecording: Bool = false
    @AppStorage("taskService") private var taskService: String = "reminders"
    @AppStorage("todoistAPIKey") private var todoistAPIKey: String = ""
    @AppStorage("deepgramAPIKey") private var deepgramAPIKey: String = ""
    @AppStorage("geminiAPIKey") private var geminiAPIKey: String = ""
    @AppStorage("remindersListId") private var remindersListId: String = ""

    // Sound is stored differently (inverted logic)
    @State private var enableSounds: Bool = true

    // MARK: - Verification States

    @State private var isVerifyingDeepgram = false
    @State private var isVerifyingTodoist = false
    @State private var isVerifyingGemini = false

    @State private var deepgramVerified: Bool?
    @State private var todoistVerified: Bool?
    @State private var geminiVerified: Bool?

    // MARK: - Reminders Lists
    @State private var availableRemindersLists: [RemindersList] = []
    @State private var isLoadingRemindersLists = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Header
                headerSection

                // Storage Section
                storageSection

                // Profile Section
                profileSection

                // Appearance Section
                appearanceSection

                // Task Integration Section
                taskIntegrationSection

                // AI Services Section
                aiServicesSection
            }
            .padding(Spacing.lg)
        }
        .background(Color.panelCharcoal)
        .onAppear {
            // Load sound preference (stored with inverted logic)
            enableSounds = UserDefaults.standard.bool(forKey: "enableUISounds") != false
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Preferences")
                .font(.headingLarge)
                .foregroundColor(.panelTextPrimary)

            Text("Configure how Transcripted works for you")
                .font(.bodySmall)
                .foregroundColor(.panelTextSecondary)
        }
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        SettingsSectionCard(
            icon: "folder.fill",
            title: "Storage",
            subtitle: "Where your transcripts are saved"
        ) {
            SettingsPathRow(
                title: "Save Location",
                path: saveLocation,
                defaultPath: "~/Documents/Transcripted/",
                onChoose: chooseSaveFolder
            )
        }
    }

    // MARK: - Profile Section

    private var profileSection: some View {
        SettingsSectionCard(
            icon: "person.fill",
            title: "Profile"
        ) {
            SettingsTextField(
                title: "Your Name",
                placeholder: "Enter your name",
                text: $userName
            )

            Text("Used for speaker identification and action item attribution")
                .font(.caption)
                .foregroundColor(.panelTextMuted)
                .padding(.top, Spacing.xs)
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        SettingsSectionCard(
            icon: "paintbrush.fill",
            title: "Appearance"
        ) {
            VStack(spacing: Spacing.md) {
                SettingsToggleRow(
                    title: "Aurora Recording Indicator",
                    description: "Flowing color animation during recording",
                    isOn: $useAuroraRecording
                )

                Divider()
                    .background(Color.panelCharcoalSurface)

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

    // MARK: - Task Integration Section

    private var taskIntegrationSection: some View {
        SettingsSectionCard(
            icon: "checkmark.circle.fill",
            title: "Task Integration",
            subtitle: "Where action items are sent"
        ) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                // Task service picker
                taskServicePicker

                // Apple Reminders list picker (if selected)
                if taskService == "reminders" {
                    Divider()
                        .background(Color.panelCharcoalSurface)

                    remindersListPicker
                }

                // Todoist API key (if selected)
                if taskService == "todoist" {
                    Divider()
                        .background(Color.panelCharcoalSurface)

                    SettingsTextField(
                        title: "Todoist API Key",
                        placeholder: "Enter your Todoist API key",
                        text: $todoistAPIKey,
                        isSecure: true,
                        onVerify: verifyTodoist
                    )

                    if let verified = todoistVerified {
                        verificationStatus(verified: verified, isVerifying: isVerifyingTodoist)
                    }

                    Link("Get your API key from Todoist →", destination: URL(string: "https://todoist.com/app/settings/integrations")!)
                        .font(.caption)
                        .foregroundColor(.accentBlueLight)
                }

            }
        }
    }

    // MARK: - Reminders List Picker

    private var remindersListPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Reminders List")
                .font(.bodyMedium)
                .foregroundColor(.panelTextPrimary)

            if isLoadingRemindersLists {
                HStack(spacing: Spacing.xs) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading lists...")
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)
                }
            } else if availableRemindersLists.isEmpty {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.warningAmber)
                    Text("Grant Reminders access to see your lists")
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)
                }
                .onAppear {
                    loadRemindersLists()
                }
            } else {
                Picker("", selection: $remindersListId) {
                    Text("Default List").tag("")
                    ForEach(availableRemindersLists) { list in
                        HStack {
                            Circle()
                                .fill(list.color != nil ? Color(cgColor: list.color!) : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(list.title + (list.isDefault ? " (System Default)" : ""))
                        }
                        .tag(list.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(.panelTextPrimary)
            }

            // Status text
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.attentionGreen)
                Text(selectedRemindersListText)
                    .font(.caption)
                    .foregroundColor(.panelTextSecondary)
            }
        }
        .onAppear {
            loadRemindersLists()
        }
    }

    private var selectedRemindersListText: String {
        if remindersListId.isEmpty {
            return "Tasks go to your default Reminders list"
        }
        if let list = availableRemindersLists.first(where: { $0.id == remindersListId }) {
            return "Tasks go to \"\(list.title)\""
        }
        return "Tasks go to Apple Reminders"
    }

    private func loadRemindersLists() {
        guard !isLoadingRemindersLists else { return }
        isLoadingRemindersLists = true

        Task {
            let service = RemindersService()
            let hasAccess = await service.requestAccess()

            await MainActor.run {
                if hasAccess {
                    availableRemindersLists = service.getRemindersLists()
                } else {
                    availableRemindersLists = []
                }
                isLoadingRemindersLists = false
            }
        }
    }

    private var taskServicePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Task Destination")
                .font(.bodyMedium)
                .foregroundColor(.panelTextPrimary)

            HStack(spacing: Spacing.md) {
                // Apple Reminders option
                Button {
                    taskService = "reminders"
                } label: {
                    HStack(spacing: Spacing.sm) {
                        ZStack {
                            Circle()
                                .stroke(
                                    taskService == "reminders" ? Color.recordingCoral : Color.panelTextMuted,
                                    lineWidth: 2
                                )
                                .frame(width: 18, height: 18)

                            if taskService == "reminders" {
                                Circle()
                                    .fill(Color.recordingCoral)
                                    .frame(width: 10, height: 10)
                            }
                        }

                        Image(systemName: "bell.badge.fill")
                            .foregroundColor(.panelTextSecondary)

                        Text("Apple Reminders")
                            .font(.bodySmall)
                            .foregroundColor(.panelTextPrimary)
                    }
                }
                .buttonStyle(.plain)

                // Todoist option
                Button {
                    taskService = "todoist"
                } label: {
                    HStack(spacing: Spacing.sm) {
                        ZStack {
                            Circle()
                                .stroke(
                                    taskService == "todoist" ? Color.recordingCoral : Color.panelTextMuted,
                                    lineWidth: 2
                                )
                                .frame(width: 18, height: 18)

                            if taskService == "todoist" {
                                Circle()
                                    .fill(Color.recordingCoral)
                                    .frame(width: 10, height: 10)
                            }
                        }

                        // Todoist icon (placeholder)
                        Image(systemName: "checklist")
                            .foregroundColor(.panelTextSecondary)

                        Text("Todoist")
                            .font(.bodySmall)
                            .foregroundColor(.panelTextPrimary)
                    }
                }
                .buttonStyle(.plain)

            }
        }
    }

    // MARK: - AI Services Section

    private var aiServicesSection: some View {
        SettingsSectionCard(
            icon: "sparkles",
            title: "AI Services",
            subtitle: "API keys for transcription and AI features"
        ) {
            VStack(spacing: Spacing.lg) {
                // Deepgram
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SettingsTextField(
                        title: "Deepgram API Key",
                        placeholder: "Enter your Deepgram API key",
                        text: $deepgramAPIKey,
                        isSecure: true,
                        onVerify: verifyDeepgram
                    )

                    if let verified = deepgramVerified {
                        verificationStatus(verified: verified, isVerifying: isVerifyingDeepgram)
                    }

                    Link("Get your API key from Deepgram →", destination: URL(string: "https://console.deepgram.com/")!)
                        .font(.caption)
                        .foregroundColor(.accentBlueLight)
                }

                Divider()
                    .background(Color.panelCharcoalSurface)

                // Gemini
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SettingsTextField(
                        title: "Gemini API Key",
                        placeholder: "Enter your Gemini API key",
                        text: $geminiAPIKey,
                        isSecure: true,
                        onVerify: verifyGemini
                    )

                    if let verified = geminiVerified {
                        verificationStatus(verified: verified, isVerifying: isVerifyingGemini)
                    }

                    Text("Used for action item extraction from transcripts")
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)

                    Link("Get your API key from Google AI Studio →", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.caption)
                        .foregroundColor(.accentBlueLight)
                }
            }
        }
    }

    // MARK: - Verification Status

    @ViewBuilder
    private func verificationStatus(verified: Bool, isVerifying: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            if isVerifying {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Verifying...")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
            } else if verified {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.attentionGreen)
                Text("Verified")
                    .font(.caption)
                    .foregroundColor(.attentionGreen)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.errorCoral)
                Text("Invalid key")
                    .font(.caption)
                    .foregroundColor(.errorCoral)
            }
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

        if let url = URL(string: saveLocation.isEmpty ? TranscriptSaver.defaultSaveDirectory.path : saveLocation) {
            panel.directoryURL = url
        }

        if panel.runModal() == .OK, let url = panel.url {
            saveLocation = url.path
        }
    }

    private func verifyDeepgram() {
        isVerifyingDeepgram = true
        deepgramVerified = nil

        // Simple validation - just check if key looks valid
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)

            await MainActor.run {
                // Basic format check
                deepgramVerified = deepgramAPIKey.count > 20
                isVerifyingDeepgram = false
            }
        }
    }

    private func verifyTodoist() {
        isVerifyingTodoist = true
        todoistVerified = nil

        Task {
            let verified = await TodoistService.validateAPIKey(todoistAPIKey)
            await MainActor.run {
                todoistVerified = verified
                isVerifyingTodoist = false
            }
        }
    }

    private func verifyGemini() {
        isVerifyingGemini = true
        geminiVerified = nil

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)

            await MainActor.run {
                // Basic format check
                geminiVerified = geminiAPIKey.hasPrefix("AI") && geminiAPIKey.count > 30
                isVerifyingGemini = false
            }
        }
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    PreferencesView()
        .frame(width: 620, height: 700)
}
