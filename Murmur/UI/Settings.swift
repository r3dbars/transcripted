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
    @AppStorage("deepgramAPIKey") private var deepgramAPIKey: String = ""
    @AppStorage("useAuroraRecording") private var useAuroraRecording: Bool = false
    @AppStorage("enableMeetingDetection") private var enableMeetingDetection: Bool = true
    @Environment(\.dismiss) private var dismiss

    // MARK: - Tab State
    @State private var selectedTab: SettingsTab = .recording

    // MARK: - Accessibility
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // MARK: - Validation States
    @State private var isValidatingTodoistKey = false
    @State private var todoistKeyValidationResult: Bool? = nil
    @State private var isValidatingDeepgramKey = false
    @State private var deepgramKeyValidationResult: Bool? = nil

    // MARK: - Test States
    @State private var isTestingActionItems = false
    @State private var actionItemsTestStatus = ""

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

            // Transcription Provider Card (Deepgram)
            SettingsCard(title: "Transcription", icon: "waveform.circle") {
                deepgramConfigView
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

            // Appearance Card
            SettingsCard(title: "Appearance", icon: "paintbrush") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Toggle(isOn: $useAuroraRecording) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aurora Recording Indicator")
                                .font(.bodySmall)
                                .foregroundColor(.textOnCream)
                            Text("Flowing colors that dance with your conversation")
                                .font(.caption)
                                .foregroundColor(.textOnCreamMuted)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }

            // Meeting Detection Card
            SettingsCard(title: "Meeting Detection", icon: "person.2") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Toggle(isOn: $enableMeetingDetection) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remind me to record meetings")
                                .font(.bodySmall)
                                .foregroundColor(.textOnCream)
                            Text("Detects video calls and offers to record")
                                .font(.caption)
                                .foregroundColor(.textOnCreamMuted)
                        }
                    }
                    .toggleStyle(.switch)

                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.accentBlue)
                        Text("Uses audio + app detection to minimize false positives")
                            .font(.caption)
                            .foregroundColor(.textOnCreamMuted)
                    }
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

    // MARK: - Provider Config Views

    private var deepgramConfigView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Deepgram API Key:")
                .font(.caption)
                .foregroundColor(.textOnCreamSecondary)

            HStack(spacing: Spacing.sm) {
                SecureField("Enter your API key", text: $deepgramAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: deepgramAPIKey) { _, _ in
                        deepgramKeyValidationResult = nil
                    }

                validationIndicator(
                    isValidating: isValidatingDeepgramKey,
                    result: deepgramKeyValidationResult
                )

                Button("Verify") {
                    Task {
                        isValidatingDeepgramKey = true
                        deepgramKeyValidationResult = await DeepgramService.validateAPIKey(deepgramAPIKey)
                        isValidatingDeepgramKey = false
                    }
                }
                .buttonStyle(LawsSecondaryButtonStyle())
                .disabled(deepgramAPIKey.isEmpty || isValidatingDeepgramKey)
            }

            Text("Get free credits at console.deepgram.com")
                .font(.caption)
                .foregroundColor(.textOnCreamMuted)

            HStack(spacing: Spacing.xs) {
                Image(systemName: "star.fill")
                    .foregroundColor(.statusSuccessMuted)
                Text("Recommended: multichannel + speaker diarization in one call!")
                    .font(.caption)
                    .foregroundColor(.statusSuccessMuted)
            }

            HStack(spacing: Spacing.xs) {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentBlue)
                Text("Uses Nova-3 model with smart formatting")
                    .font(.caption)
                    .foregroundColor(.textOnCreamSecondary)
            }
        }
        .padding(.top, Spacing.xs)
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
            // UI Preferences Card
            uiPreferencesCard

            // Test Action Items Card
            testActionItemsCard

            // API Status Card
            apiStatusCard
        }
    }

    private var uiPreferencesCard: some View {
        SettingsCard(title: "Interface", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "enableUISounds") != false },
                    set: { UserDefaults.standard.set($0, forKey: "enableUISounds") }
                )) {
                    HStack {
                        Text("Sound feedback")
                            .font(.bodySmall)
                            .foregroundColor(.textOnCream)
                        Spacer()
                    }
                }
                .toggleStyle(.switch)

                Text("Play subtle sounds when recording starts, stops, and completes.")
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
                    name: "Deepgram",
                    isConfigured: !deepgramAPIKey.isEmpty,
                    isVerified: deepgramKeyValidationResult
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

            let taskResult: TaskCreationResult
            if taskService == "todoist" {
                let todoist = TodoistService()
                taskResult = await todoist.createTasks(from: result.actionItems)
            } else {
                let reminders = RemindersService()
                guard await reminders.requestAccess() else {
                    await MainActor.run {
                        actionItemsTestStatus = "❌ Reminders access denied"
                        isTestingActionItems = false
                    }
                    return
                }
                taskResult = await reminders.createReminders(from: result.actionItems)
            }

            print("✅ Created \(taskResult.successCount)/\(result.actionItems.count) tasks")

            await MainActor.run {
                if taskResult.allSucceeded {
                    actionItemsTestStatus = "✓ Created \(taskResult.successCount) tasks"
                } else if taskResult.partialSuccess {
                    actionItemsTestStatus = "⚠️ Created \(taskResult.successCount)/\(taskResult.totalAttempted) tasks (\(taskResult.failureCount) failed)"
                } else if taskResult.allFailed {
                    let firstError = taskResult.failures.first?.errorMessage ?? "Unknown error"
                    actionItemsTestStatus = "❌ Failed to create tasks: \(firstError)"
                } else {
                    actionItemsTestStatus = "No tasks to create"
                }
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
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    SettingsView()
}
#endif
