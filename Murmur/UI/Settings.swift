import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Settings Tab Enum

enum SettingsTab: String, CaseIterable {
    case recording = "Recording"
    case aiFeatures = "AI Features"
    case advanced = "Advanced"

    var icon: String {
        switch self {
        case .recording: return "waveform"
        case .aiFeatures: return "sparkles"
        case .advanced: return "gear"
        }
    }
}

// MARK: - Main Settings View

@available(macOS 26.0, *)
struct SettingsView: View {
    // MARK: - Storage Properties
    @AppStorage("transcriptSaveLocation") private var saveLocation: String = ""
    @AppStorage("userName") private var userName: String = ""
    @AppStorage("geminiAPIKey") private var geminiAPIKey: String = ""
    @AppStorage("taskService") private var taskService: String = "reminders"
    @AppStorage("todoistAPIKey") private var todoistAPIKey: String = ""
    @AppStorage("assemblyaiAPIKey") private var assemblyaiAPIKey: String = ""
    @Environment(\.dismiss) private var dismiss

    // MARK: - Tab State
    @State private var selectedTab: SettingsTab = .recording

    // MARK: - Accessibility
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // MARK: - Validation States
    @State private var isValidatingTodoistKey = false
    @State private var todoistKeyValidationResult: Bool? = nil
    @State private var isValidatingAssemblyAIKey = false
    @State private var assemblyAIKeyValidationResult: Bool? = nil

    // MARK: - Test States
    @State private var isTestingActionItems = false
    @State private var actionItemsTestStatus = ""
    @State private var isTestingAssemblyAI = false
    @State private var assemblyAITestStatus = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Tab Bar
            tabBarView

            // Content
            tabContentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Footer
            footerView
        }
        .frame(width: 520, height: 580)
        .background(Color.surfaceBackground)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: Spacing.xs) {
            Text("Settings")
                .font(.headingLarge)
                .foregroundColor(.textOnCream)

            Text("Configure how Transcripted works for you")
                .font(.bodySmall)
                .foregroundColor(.textOnCreamMuted)
        }
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.md)
    }

    // MARK: - Tab Bar (Laws of UX curved cells)

    private var tabBarView: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                TabButton(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    action: {
                        withAnimation(reduceMotion ? .none : .lawsStateChange) {
                            selectedTab = tab
                        }
                    }
                )
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                .fill(Color.surfaceCard)
                .shadow(color: CardStyle.shadowSubtle.color, radius: CardStyle.shadowSubtle.radius, y: CardStyle.shadowSubtle.y)
        )
        .padding(.horizontal, Spacing.lg)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContentView: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                switch selectedTab {
                case .recording:
                    recordingTabContent
                case .aiFeatures:
                    aiFeaturesTabContent
                case .advanced:
                    advancedTabContent
                }
            }
            .padding(Spacing.lg)
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(LawsPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.lg)
        .background(
            Rectangle()
                .fill(Color.surfaceBackground)
                .shadow(color: .black.opacity(0.05), radius: 4, y: -2)
        )
    }
}

// MARK: - Recording Tab Content

@available(macOS 26.0, *)
extension SettingsView {

    private var recordingTabContent: some View {
        VStack(spacing: Spacing.md) {
            // Save Location Card
            SettingsCard(title: "Save Location", icon: "folder") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(displayPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.textOnCreamSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Choose Folder...") {
                        chooseSaveFolder()
                    }
                    .buttonStyle(LawsSecondaryButtonStyle())

                    Text("Transcripts are saved as Markdown files with timestamps.")
                        .font(.caption)
                        .foregroundColor(.textOnCreamMuted)
                }
            }

            // AssemblyAI API Key Card
            SettingsCard(title: "Transcription", icon: "waveform.circle") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("AssemblyAI API Key:")
                        .font(.caption)
                        .foregroundColor(.textOnCreamSecondary)

                    HStack(spacing: Spacing.sm) {
                        SecureField("Enter your API key", text: $assemblyaiAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onChange(of: assemblyaiAPIKey) { _, _ in
                                assemblyAIKeyValidationResult = nil
                            }

                        validationIndicator(
                            isValidating: isValidatingAssemblyAIKey,
                            result: assemblyAIKeyValidationResult
                        )

                        Button("Verify") {
                            Task {
                                isValidatingAssemblyAIKey = true
                                assemblyAIKeyValidationResult = await AssemblyAIService.validateAPIKey(assemblyaiAPIKey)
                                isValidatingAssemblyAIKey = false
                            }
                        }
                        .buttonStyle(LawsSecondaryButtonStyle())
                        .disabled(assemblyaiAPIKey.isEmpty || isValidatingAssemblyAIKey)
                    }

                    Text("Get free credits at assemblyai.com/dashboard")
                        .font(.caption)
                        .foregroundColor(.textOnCreamMuted)

                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "sparkles")
                            .foregroundColor(.accentBlue)
                        Text("AI features: speaker diarization, sentiment, chapters, entities")
                            .font(.caption)
                            .foregroundColor(.textOnCreamSecondary)
                    }
                }
            }

            // Your Name Card
            SettingsCard(title: "Your Name", icon: "person") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    TextField("Enter your name", text: $userName)
                        .textFieldStyle(.roundedBorder)

                    Text("Used to identify you in transcripts and attribute action items.")
                        .font(.caption)
                        .foregroundColor(.textOnCreamMuted)
                }
            }
        }
    }

    private var displayPath: String {
        if saveLocation.isEmpty {
            return "~/Documents/Transcripted/ (default)"
        } else {
            return saveLocation.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }
}

// MARK: - AI Features Tab Content

@available(macOS 26.0, *)
extension SettingsView {

    private var aiFeaturesTabContent: some View {
        VStack(spacing: Spacing.md) {
            // Gemini API Key Card
            SettingsCard(title: "AI Action Items", icon: "sparkles") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Gemini API Key:")
                        .font(.caption)
                        .foregroundColor(.textOnCreamSecondary)

                    SecureField("Enter your Gemini API key", text: $geminiAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    Text("Get a free key at aistudio.google.com")
                        .font(.caption)
                        .foregroundColor(.textOnCreamMuted)

                    if !geminiAPIKey.isEmpty {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.statusSuccessMuted)
                            Text("Action items will be extracted from transcripts")
                                .font(.caption)
                                .foregroundColor(.textOnCreamSecondary)
                        }
                        .padding(.top, Spacing.xs)
                    }
                }
            }

            // Task Destination Card
            SettingsCard(title: "Task Destination", icon: "checklist") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Picker("", selection: $taskService) {
                        Text("Apple Reminders").tag("reminders")
                        Text("Todoist").tag("todoist")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: taskService) { _, newValue in
                        if newValue == "reminders" { todoistKeyValidationResult = nil }
                    }

                    if taskService == "todoist" {
                        todoistConfigView
                    } else {
                        remindersConfigView
                    }
                }
            }

            // Preview Card
            actionItemPreviewCard
        }
    }

    private var todoistConfigView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Todoist API Key:")
                .font(.caption)
                .foregroundColor(.textOnCreamSecondary)

            HStack(spacing: Spacing.sm) {
                SecureField("Enter your Todoist API key", text: $todoistAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: todoistAPIKey) { _, _ in
                        todoistKeyValidationResult = nil
                    }

                validationIndicator(
                    isValidating: isValidatingTodoistKey,
                    result: todoistKeyValidationResult
                )

                Button("Verify") {
                    Task {
                        isValidatingTodoistKey = true
                        todoistKeyValidationResult = await TodoistService.validateAPIKey(todoistAPIKey)
                        isValidatingTodoistKey = false
                    }
                }
                .buttonStyle(LawsSecondaryButtonStyle())
                .disabled(todoistAPIKey.isEmpty || isValidatingTodoistKey)
            }

            Text("Find at todoist.com/app/settings/integrations/developer")
                .font(.caption)
                .foregroundColor(.textOnCreamMuted)
        }
        .padding(.top, Spacing.xs)
    }

    private var remindersConfigView: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.statusSuccessMuted)
            Text("Tasks will appear in Apple Reminders")
                .font(.caption)
                .foregroundColor(.textOnCreamSecondary)
        }
    }

    private var actionItemPreviewCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundColor(.accentBlue)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("After each recording...")
                        .font(.bodyMedium)
                        .foregroundColor(.textOnCream)

                    if geminiAPIKey.isEmpty {
                        Text("Add a Gemini API key to enable action item extraction")
                            .font(.caption)
                            .foregroundColor(.textOnCreamMuted)
                    } else {
                        Text("Action items → \(taskService == "todoist" ? "Todoist Inbox" : "Apple Reminders")")
                            .font(.caption)
                            .foregroundColor(.statusSuccessMuted)
                    }
                }

                Spacer()
            }
        }
        .padding(Spacing.md)
        .background(Color.surfaceEggshell.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous))
    }
}

// MARK: - Advanced Tab Content

@available(macOS 26.0, *)
extension SettingsView {

    private var advancedTabContent: some View {
        VStack(spacing: Spacing.md) {
            // Test AssemblyAI Card
            testAssemblyAICard

            // Test Action Items Card
            testActionItemsCard

            // API Status Card
            apiStatusCard
        }
    }

    private var testAssemblyAICard: some View {
        SettingsCard(title: "Test AssemblyAI", icon: "play.circle") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Button("Test with Audio File...") {
                        testAssemblyAIWithAudio()
                    }
                    .buttonStyle(LawsSecondaryButtonStyle())
                    .disabled(isTestingAssemblyAI || assemblyaiAPIKey.isEmpty)

                    if isTestingAssemblyAI {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                if !assemblyAITestStatus.isEmpty {
                    statusText(assemblyAITestStatus)
                }

                Text("Processing may take 1-2 minutes.")
                    .font(.caption)
                    .foregroundColor(.textOnCreamMuted)
            }
        }
    }

    private var testActionItemsCard: some View {
        SettingsCard(title: "Test Action Items", icon: "checklist") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Button("Test with Transcript...") {
                        testWithTranscript()
                    }
                    .buttonStyle(LawsSecondaryButtonStyle())
                    .disabled(isTestingActionItems || geminiAPIKey.isEmpty)

                    if isTestingActionItems {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                if !actionItemsTestStatus.isEmpty {
                    statusText(actionItemsTestStatus)
                }

                Text("Re-extract action items from a saved transcript.")
                    .font(.caption)
                    .foregroundColor(.textOnCreamMuted)
            }
        }
    }

    private var apiStatusCard: some View {
        SettingsCard(title: "API Status", icon: "key") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                apiStatusRow(
                    name: "AssemblyAI",
                    isConfigured: !assemblyaiAPIKey.isEmpty,
                    isVerified: assemblyAIKeyValidationResult
                )

                apiStatusRow(
                    name: "Gemini",
                    isConfigured: !geminiAPIKey.isEmpty
                )

                if taskService == "todoist" {
                    apiStatusRow(
                        name: "Todoist",
                        isConfigured: !todoistAPIKey.isEmpty,
                        isVerified: todoistKeyValidationResult
                    )
                }
            }
        }
    }

    private func apiStatusRow(name: String, isConfigured: Bool, isVerified: Bool? = nil) -> some View {
        HStack {
            Text(name)
                .font(.bodySmall)
                .foregroundColor(.textOnCream)

            Spacer()

            if let verified = isVerified {
                Image(systemName: verified ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(verified ? .statusSuccessMuted : .statusErrorMuted)
                Text(verified ? "Verified" : "Invalid")
                    .font(.caption)
                    .foregroundColor(verified ? .statusSuccessMuted : .statusErrorMuted)
            } else if isConfigured {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.statusWarningMuted)
                Text("Not verified")
                    .font(.caption)
                    .foregroundColor(.statusWarningMuted)
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.textOnCreamMuted)
                Text("Not set")
                    .font(.caption)
                    .foregroundColor(.textOnCreamMuted)
            }
        }
    }

    @ViewBuilder
    private func statusText(_ text: String) -> some View {
        let color: Color = {
            if text.hasPrefix("✓") { return .statusSuccessMuted }
            if text.hasPrefix("❌") { return .statusErrorMuted }
            return .textOnCreamSecondary
        }()

        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(color)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func validationIndicator(isValidating: Bool, result: Bool?) -> some View {
        if isValidating {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 20)
        } else if let isValid = result {
            Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isValid ? .statusSuccessMuted : .statusErrorMuted)
                .frame(width: 20)
        }
    }
}

// MARK: - Settings Card Component

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let content: () -> Content

    @State private var isHovered = false

    init(title: String, icon: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.accentBlue)

                Text(title)
                    .font(.headingSmall)
                    .foregroundColor(.textOnCream)
            }

            // Content
            content()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lawsCard(isHovered: isHovered)
        .onHover { hovering in
            withAnimation(.lawsCardHover) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Tab Button Component

@available(macOS 26.0, *)
struct TabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .medium))
                Text(tab.rawValue)
                    .font(.bodyMedium)
            }
            .foregroundColor(isSelected ? .white : .textOnCream)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .fill(isSelected ? Color.accentBlue : (isHovered ? Color.surfaceEggshell : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.lawsCardHover) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Button Styles (Laws of UX)

struct LawsPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.buttonText)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .fill(Color.accentBlue)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.lawsTap, value: configuration.isPressed)
    }
}

struct LawsSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bodySmall)
            .foregroundColor(.textOnCream)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .fill(Color.surfaceEggshell)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .stroke(Color.accentBlue.opacity(0.2), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.lawsTap, value: configuration.isPressed)
    }
}

// MARK: - Actions (File Choosers & Tests)

@available(macOS 26.0, *)
extension SettingsView {

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Save Location"
        panel.message = "Select a folder to save your transcripts"

        if !saveLocation.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: saveLocation)
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            panel.directoryURL = documentsPath
        }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                saveLocation = url.path
            }
        }
    }

    private func testWithTranscript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.prompt = "Test"
        panel.message = "Select a transcript file to test action item extraction"

        if !saveLocation.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: saveLocation)
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            panel.directoryURL = documentsPath.appendingPathComponent("Transcripted")
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await runActionItemTest(transcriptURL: url) }
        }
    }

    private func runActionItemTest(transcriptURL: URL) async {
        await MainActor.run {
            isTestingActionItems = true
            actionItemsTestStatus = "Reading transcript..."
        }

        print("\n" + String(repeating: "=", count: 60))
        print("🧪 TEST: Action Item Extraction")
        print("📄 File: \(transcriptURL.lastPathComponent)")
        print(String(repeating: "=", count: 60))

        do {
            let content = try String(contentsOf: transcriptURL, encoding: .utf8)
            print("📖 Read \(content.count) characters")

            await MainActor.run { actionItemsTestStatus = "Extracting action items..." }

            let result = try await ActionItemExtractor.extract(from: content, apiKey: geminiAPIKey)

            if result.actionItems.isEmpty {
                print("ℹ️ No action items found")
                await MainActor.run {
                    actionItemsTestStatus = "No action items found."
                    isTestingActionItems = false
                }
                return
            }

            print("\n📋 Found \(result.actionItems.count) action items")

            await MainActor.run { actionItemsTestStatus = "Creating \(result.actionItems.count) tasks..." }

            let count: Int
            if taskService == "todoist" {
                let todoist = TodoistService()
                count = await todoist.createTasks(from: result.actionItems)
            } else {
                let reminders = RemindersService()
                guard await reminders.requestAccess() else {
                    await MainActor.run {
                        actionItemsTestStatus = "❌ Reminders access denied"
                        isTestingActionItems = false
                    }
                    return
                }
                count = await reminders.createReminders(from: result.actionItems)
            }

            print("✅ Created \(count)/\(result.actionItems.count) tasks")

            await MainActor.run {
                actionItemsTestStatus = "✓ Created \(count)/\(result.actionItems.count) tasks"
                isTestingActionItems = false
            }

        } catch {
            print("❌ TEST FAILED: \(error)")
            await MainActor.run {
                actionItemsTestStatus = "❌ \(error.localizedDescription)"
                isTestingActionItems = false
            }
        }
    }

    private func testAssemblyAIWithAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio, .audio]
        panel.prompt = "Test AssemblyAI"
        panel.message = "Select an audio file to test AssemblyAI transcription"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await runAssemblyAITest(audioURL: url) }
        }
    }

    private func runAssemblyAITest(audioURL: URL) async {
        await MainActor.run {
            isTestingAssemblyAI = true
            assemblyAITestStatus = "Uploading..."
        }

        print("\n🧪 TEST: AssemblyAI Transcription with Speaker Identification")

        do {
            // Phase 1: Transcribe with AssemblyAI
            let result = try await AssemblyAIService.transcribe(
                audioURL: audioURL,
                apiKey: assemblyaiAPIKey,
                onStatusUpdate: { status in
                    Task { @MainActor in
                        assemblyAITestStatus = status.rawValue
                    }
                }
            )

            if result.utterances.isEmpty {
                await MainActor.run {
                    assemblyAITestStatus = "No speech detected."
                    isTestingAssemblyAI = false
                }
                return
            }

            let duration = result.metadata.duration ?? 0
            let combinedResult = CombinedAssemblyAIResult(
                micResult: result,  // Treat test file as mic input
                systemResult: nil,
                duration: TimeInterval(duration),
                processingTime: 0  // Not tracked for test files
            )

            print("✅ Phase 1 complete: \(result.metadata.utteranceCount) utterances, \(combinedResult.allSpeakerIds.count) speakers detected")

            // Phase 2: Identify speakers with Gemini (if API key available)
            var speakerMappings: [String: SpeakerMapping] = [:]

            if !geminiAPIKey.isEmpty && !combinedResult.allSpeakerIds.isEmpty {
                await MainActor.run {
                    assemblyAITestStatus = "Identifying speakers..."
                }

                print("📋 Phase 2: Identifying \(combinedResult.allSpeakerIds.count) speakers with Gemini...")

                // Generate preliminary transcript for Gemini
                let preliminaryTranscript = ActionItemExtractor.generatePreliminaryTranscript(from: combinedResult)

                // Identify speakers
                let speakerResult = await ActionItemExtractor.identifySpeakersWithFallback(
                    from: preliminaryTranscript,
                    speakerIds: Array(combinedResult.allSpeakerIds).sorted(),
                    userName: userName,
                    apiKey: geminiAPIKey
                )

                // Build speaker mappings
                speakerMappings = ActionItemExtractor.buildSpeakerMappings(
                    from: speakerResult,
                    allSpeakerIds: combinedResult.allSpeakerIds,
                    userName: userName
                )

                let identifiedCount = speakerMappings.values.filter { $0.identifiedName != nil }.count
                print("✅ Phase 2 complete: Identified \(identifiedCount) of \(speakerMappings.count) speakers")
            } else {
                // No Gemini key - use generic mappings
                for id in combinedResult.allSpeakerIds {
                    speakerMappings[id] = SpeakerMapping(speakerId: id, identifiedName: nil, confidence: nil)
                }
                print("ℹ️ Phase 2 skipped: No Gemini API key, using generic speaker labels")
            }

            // Phase 3: Save with speaker names
            await MainActor.run {
                assemblyAITestStatus = "Saving transcript..."
            }

            guard let savedURL = TranscriptSaver.saveRichAssemblyAITranscript(
                combinedResult,
                speakerMappings: speakerMappings
            ) else {
                await MainActor.run {
                    assemblyAITestStatus = "❌ Failed to save transcript"
                    isTestingAssemblyAI = false
                }
                return
            }

            print("✅ Phase 3 complete: Transcript saved")

            // Phase 4: Extract action items, summary, and rename file (if Gemini available)
            var currentURL = savedURL
            if !geminiAPIKey.isEmpty {
                await MainActor.run {
                    assemblyAITestStatus = "Extracting summary & action items..."
                }

                print("📋 Phase 4: Extracting action items and summary with Gemini...")

                do {
                    let content = try String(contentsOf: savedURL, encoding: .utf8)
                    let extractionResult = try await ActionItemExtractor.extract(from: content, apiKey: geminiAPIKey)

                    // Update transcript with Gemini-generated summary
                    if let summary = extractionResult.meetingSummary, !summary.isEmpty {
                        TranscriptUtils.updateWithSummary(at: currentURL, summary: summary)
                    }

                    // Rename file with descriptive title
                    if let title = extractionResult.meetingTitle, !title.isEmpty {
                        currentURL = TranscriptUtils.renameWithTitle(at: currentURL, title: title)
                    }

                    print("✅ Phase 4 complete: \(extractionResult.actionItems.count) action items found")
                } catch {
                    print("⚠️ Phase 4 failed: \(error.localizedDescription)")
                }
            }

            let identifiedCount = speakerMappings.values.filter { $0.identifiedName != nil }.count
            await MainActor.run {
                if identifiedCount > 0 {
                    assemblyAITestStatus = "✓ \(result.metadata.utteranceCount) utterances, \(identifiedCount)/\(result.metadata.speakerCount) speakers identified!"
                } else {
                    assemblyAITestStatus = "✓ \(result.metadata.utteranceCount) utterances, \(result.metadata.speakerCount) speakers (generic labels)"
                }
                isTestingAssemblyAI = false
            }

        } catch {
            await MainActor.run {
                assemblyAITestStatus = "❌ \(error.localizedDescription)"
                isTestingAssemblyAI = false
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    SettingsView()
}
#endif
