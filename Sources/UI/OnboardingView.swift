// OnboardingView.swift
// 8-step standalone onboarding: Welcome → Dictation Intro → Drafting Intro → Name → Permissions → Try Dictation → Try Drafting → All Set

import SwiftUI
import AVFoundation
import ApplicationServices

struct OnboardingView: View {
    @ObservedObject var sessionController: DraftSessionController
    var overlayController: FloatingOverlayController
    @ObservedObject var appState: DraftAppState
    var onComplete: () -> Void
    /// Callback to raise/lower the onboarding window. `true` = floating (above other apps),
    /// `false` = normal (behind the user's messaging apps so hotkeys capture the right window).
    var adjustWindow: ((Bool) -> Void)?

    enum Step: Int, CaseIterable {
        case welcome, dictationIntro, draftingIntro, nameEntry, permissions, tryDictation, tryDrafting, allSet

        var previous: Step? {
            Step(rawValue: rawValue - 1)
        }
    }

    enum TryItState {
        case waiting, inProgress, completed
    }

    @State private var currentStep: Step = .welcome
    @State private var nameInput = UserDefaults.standard.string(forKey: "user-display-name")
        ?? NSFullUserName()
    @State private var dictationState: TryItState = .waiting
    @State private var draftingState: TryItState = .waiting
    @State private var dictationResult: String = ""
    @State private var draftResult: String = ""
    @State private var showStyleImport = false
    @State private var styleImportText = ""
    @State private var isImportingStyle = false

    // Permission state
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            Group {
                switch currentStep {
                case .welcome:
                    welcomeStep
                case .dictationIntro:
                    dictationIntroStep
                case .draftingIntro:
                    draftingIntroStep
                case .nameEntry:
                    nameEntryStep
                case .permissions:
                    permissionsStep
                case .tryDictation:
                    tryDictationStep
                case .tryDrafting:
                    tryDraftingStep
                case .allSet:
                    allSetStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: currentStep)
        }
        .frame(width: 640, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 10) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(dotColor(for: step))
                    .frame(width: 9, height: 9)
            }
        }
    }

    private func dotColor(for step: Step) -> Color {
        if step.rawValue < currentStep.rawValue {
            return .green
        } else if step == currentStep {
            return .accentColor
        }
        return Color.secondary.opacity(0.3)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Welcome to Draft")
                .font(.system(size: 36, weight: .bold))

            Text("Two shortcuts. Zero typing.")
                .font(.title2)
                .foregroundColor(.secondary)

            Spacer()

            Button("Next") {
                withAnimation { currentStep = .dictationIntro }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Step 2: Dictation Intro

    private var dictationIntroStep: some View {
        VStack(spacing: 20) {
            Spacer()

            heroFeatureCard(
                icon: "mic.fill",
                shortcut: "⌥Space",
                title: "Dictation",
                description: "Speak and your words appear as text.\nOn-device, free, instant."
            )
            .padding(.horizontal, 80)

            Spacer()

            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation { currentStep = .welcome }
                }
                .buttonStyle(.bordered)

                Button("Next") {
                    withAnimation { currentStep = .draftingIntro }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Step 3: AI Drafting Intro

    private var draftingIntroStep: some View {
        VStack(spacing: 20) {
            Spacer()

            heroFeatureCard(
                icon: "doc.text.fill",
                shortcut: "⌥D",
                title: "AI Drafting",
                description: "Reads the conversation and writes\na reply in your voice."
            )
            .padding(.horizontal, 80)

            Spacer()

            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation { currentStep = .dictationIntro }
                }
                .buttonStyle(.bordered)

                Button("Next") {
                    withAnimation { currentStep = .nameEntry }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Step 4: Name Entry

    private var nameEntryStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("What's your name?")
                .font(.title)
                .fontWeight(.bold)

            Text("Draft uses this to identify you in conversations.")
                .font(.callout)
                .foregroundColor(.secondary)

            TextField("Your name", text: $nameInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .multilineTextAlignment(.center)

            Spacer()

            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation { currentStep = .draftingIntro }
                }
                .buttonStyle(.bordered)

                Button("Get Started") {
                    let trimmed = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        UserDefaults.standard.set(trimmed, forKey: "user-display-name")
                    }
                    withAnimation { currentStep = .permissions }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(nameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.bottom, 24)
        }
    }

    private func heroFeatureCard(icon: String, shortcut: String, title: String, description: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            Text(shortcut)
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.bold)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(MenuTokens.pillBackground)
                .cornerRadius(MenuTokens.pillCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: MenuTokens.pillCornerRadius)
                        .stroke(MenuTokens.pillBorder, lineWidth: 1)
                )

            Text(title)
                .font(.title)
                .fontWeight(.bold)

            Text(description)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(MenuTokens.cardBackground)
        .cornerRadius(MenuTokens.cardCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: MenuTokens.cardCornerRadius)
                .stroke(MenuTokens.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Grant Permissions")
                .font(.title)
                .fontWeight(.bold)

            Text("Draft needs a few system permissions to work.")
                .font(.callout)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    hint: "Hear you speak",
                    granted: micGranted,
                    action: requestMicrophone
                )
                permissionRow(
                    icon: "hand.raised.fill",
                    title: "Accessibility",
                    hint: "Find Draft in the list and toggle it on",
                    granted: accessibilityGranted,
                    action: openAccessibilitySettings
                )
                permissionRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    hint: "Read conversations for context",
                    granted: screenRecordingGranted,
                    action: openScreenRecordingSettings
                )
            }
            .padding(.horizontal, 60)

            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation { currentStep = .nameEntry }
                }
                .buttonStyle(.bordered)

                Button("Continue") {
                    withAnimation { currentStep = .tryDictation }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!allPermissionsGranted)
            }

            Spacer()
        }
        .onAppear {
            checkAllPermissions()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }

    private var allPermissionsGranted: Bool {
        micGranted && accessibilityGranted && screenRecordingGranted
    }

    private func permissionRow(icon: String, title: String, hint: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundColor(granted ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                if !granted {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(MenuTokens.cardBackground)
        .cornerRadius(MenuTokens.cardCornerRadius)
    }

    // MARK: - Permission Actions

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                micGranted = granted
            }
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openScreenRecordingSettings() {
        if #available(macOS 15.0, *) {
            CGRequestScreenCaptureAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func checkAllPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = checkScreenRecording()
    }

    private func checkScreenRecording() -> Bool {
        if #available(macOS 15.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        let testImage = CGWindowListCreateImage(
            CGRect(x: 0, y: 0, width: 1, height: 1),
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.nominalResolution]
        )
        return testImage != nil
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                checkAllPermissions()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Step 3: Try Dictation

    private var tryDictationStep: some View {
        VStack(spacing: 14) {
            Text("Try Dictation")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 12)

            // Model loading indicator
            if !appState.sttRouter.isModelLoaded {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading voice model (first time only, ~15 seconds)...")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.horizontal, 40)
            }

            Text("Press ⌥Space, say a few words, then press ⌥Space again.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Result area
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: MenuTokens.cardCornerRadius)
                    .fill(MenuTokens.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: MenuTokens.cardCornerRadius)
                            .stroke(dictationState == .completed ? Color.green.opacity(0.4) : MenuTokens.cardBorder, lineWidth: 1)
                    )

                if dictationResult.isEmpty {
                    Text("Your dictated words will appear here...")
                        .font(.body)
                        .foregroundColor(MenuTokens.textMuted)
                        .padding(12)
                } else {
                    Text(dictationResult)
                        .font(.body)
                        .padding(12)
                        .textSelection(.enabled)
                }
            }
            .frame(height: 80)
            .padding(.horizontal, 60)

            tryItStatusView(state: dictationState, inProgressText: "Listening...", completedText: "Transcribed on-device — no internet needed")

            if dictationState == .completed {
                Text("This works in any text field — Slack, iMessage, email, anywhere. Draft pastes your words directly.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation { currentStep = .permissions }
                }
                .buttonStyle(.bordered)

                Button("Skip") {
                    withAnimation { currentStep = .tryDrafting }
                }
                .buttonStyle(.bordered)

                if dictationState == .completed {
                    Button("Next") {
                        withAnimation { currentStep = .tryDrafting }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.bottom, 16)
        }
        .onChange(of: sessionController.isDictating) { _, newValue in
            if newValue && dictationState == .waiting {
                dictationState = .inProgress
            }
        }
        .onChange(of: sessionController.lastCompletedText) { _, newValue in
            if let text = newValue, !text.isEmpty, dictationState != .completed,
               !sessionController.isInSession {
                dictationResult = text
                dictationState = .completed
            }
        }
    }

    // MARK: - Step 7: Try AI Drafting

    private var tryDraftingStep: some View {
        VStack(spacing: 14) {
            Text("Try AI Drafting")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 12)

            // Simplified instructions
            Text("Draft sees the conversation, hears your reply, and writes it for you.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 8) {
                numberedInstruction(number: 1, text: "Press", shortcut: "⌥D", suffix: "to start")
                numberedInstruction(number: 2, text: "Say what you want to tell Alex", shortcut: nil)
                numberedInstruction(number: 3, text: "Press", shortcut: "⌥D", suffix: "again — AI drafts it")
                numberedInstruction(number: 4, text: "Press", shortcut: "Enter", suffix: "to send (Esc to cancel)")
            }
            .padding(.horizontal, 50)

            // Fake conversation + reply area paired together
            VStack(spacing: 0) {
                // Alex's message
                fakeConversationCard

                // Reply result area directly below
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 0)
                        .fill(MenuTokens.cardBackground)

                    if draftResult.isEmpty {
                        Text("Your AI-drafted reply will appear here...")
                            .font(.body)
                            .foregroundColor(MenuTokens.textMuted)
                            .padding(12)
                    } else {
                        Text(draftResult)
                            .font(.body)
                            .padding(12)
                            .textSelection(.enabled)
                    }
                }
                .frame(minHeight: 60)
            }
            .clipShape(RoundedRectangle(cornerRadius: MenuTokens.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: MenuTokens.cardCornerRadius)
                    .stroke(draftingState == .completed ? Color.green.opacity(0.4) : MenuTokens.cardBorder, lineWidth: 1)
            )
            .padding(.horizontal, 40)

            tryItStatusView(state: draftingState, inProgressText: "Draft in progress...", completedText: "That's AI drafting — your thoughts, polished.")

            if draftingState == .completed {
                Text("Draft learns your writing style over time — the more you use it, the better it gets.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation { currentStep = .tryDictation }
                }
                .buttonStyle(.bordered)

                Button("Skip") {
                    withAnimation { currentStep = .allSet }
                }
                .buttonStyle(.bordered)

                if draftingState == .completed {
                    Button("Next") {
                        withAnimation { currentStep = .allSet }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.bottom, 16)
        }
        .onAppear {
            // Inject fake conversation context so vision is bypassed — guaranteed to work
            // without screen recording permission or vision API latency
            sessionController.overrideContext = CapturedContext(
                platform: "slack",
                talkingTo: "Alex Chen",
                formality: "casual",
                conversation: "Alex Chen: Hey, I keep hearing about RAG for our search feature. What actually is it and would it help us? I don't want to sound clueless in the meeting tomorrow lol"
            )
        }
        .onDisappear {
            sessionController.overrideContext = nil
        }
        .onChange(of: sessionController.isInSession) { _, newValue in
            if newValue && draftingState == .waiting {
                draftingState = .inProgress
            }
        }
        .onChange(of: sessionController.lastCompletedText) { _, newValue in
            if let text = newValue, !text.isEmpty, draftingState != .completed,
               sessionController.isInSession || draftingState == .inProgress {
                draftResult = text
                draftingState = .completed
            }
        }
    }

    // Fake conversation message card for the onboarding demo
    private var fakeConversationCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Alex Chen")
                        .font(.body)
                        .fontWeight(.semibold)
                    Text("2:34 PM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("Hey, I keep hearing about RAG for our search feature. What actually is it and would it help us? I don't want to sound clueless in the meeting tomorrow lol")
                    .font(.body)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MenuTokens.cardBackground)
    }

    // MARK: - Step 5: All Set

    private var allSetStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.green)

            Text("You're all set")
                .font(.title)
                .fontWeight(.bold)

            // Quick reference card
            VStack(alignment: .leading, spacing: 10) {
                shortcutReference(shortcut: "⌥Space", description: "Dictation — speak, words appear as text")
                shortcutReference(shortcut: "⌥D", description: "AI Drafting — screenshots conversation, writes reply")
                shortcutReference(shortcut: "Enter", description: "Send the draft")
                shortcutReference(shortcut: "Esc", description: "Cancel anytime")
            }
            .padding(16)
            .background(MenuTokens.cardBackground)
            .cornerRadius(MenuTokens.cardCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: MenuTokens.cardCornerRadius)
                    .stroke(MenuTokens.cardBorder, lineWidth: 1)
            )
            .padding(.horizontal, 80)

            Text("Draft gets better the more you use it. Your writing style is learned from every message you accept.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)

            Button(action: { showStyleImport = true }) {
                Text("Have writing samples? Import them for a head start.")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation { currentStep = .tryDrafting }
                }
                .buttonStyle(.bordered)

                Button("Start Using Draft") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer()
        }
        .onAppear {
            adjustWindow?(true)
        }
        .sheet(isPresented: $showStyleImport) {
            styleImportSheet
        }
    }

    // MARK: - Style Import Sheet

    private var styleImportSheet: some View {
        VStack(spacing: 16) {
            Text("Import Writing Samples")
                .font(.headline)

            Text("Paste messages, emails, or Slack messages you've written. Draft will learn your style from them.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            TextEditor(text: $styleImportText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 200)
                .border(Color.secondary.opacity(0.2))
                .padding(.horizontal, 16)

            HStack {
                let wordCount = styleImportText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                Text("\(wordCount) words")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Button("Cancel") {
                    showStyleImport = false
                }
                .buttonStyle(.bordered)

                Button("Build Profile") {
                    importStyle()
                }
                .buttonStyle(.borderedProminent)
                .disabled(styleImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingStyle)
            }

            if isImportingStyle {
                ProgressView("Analyzing your writing style...")
                    .font(.caption)
            }
        }
        .padding(24)
        .frame(width: 480, height: 400)
    }

    private func importStyle() {
        guard appState.localInference.isReady else { return }
        let text = styleImportText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isImportingStyle = true
        Task {
            do {
                _ = try await appState.styleEngine.importBulkSamples(rawText: text, draftEngine: appState.localInference.draftEngine)
                showStyleImport = false
            } catch {
                // Non-fatal — user can still use Draft, style builds naturally
                appState.logger.log("ONBOARDING | style import failed: \(error.localizedDescription)")
            }
            isImportingStyle = false
        }
    }

    // MARK: - Shared Components

    private func numberedInstruction(number: Int, text: String, shortcut: String?, suffix: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor)
                .clipShape(Circle())

            HStack(spacing: 4) {
                Text(text)
                    .font(.body)
                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MenuTokens.pillBackground)
                        .cornerRadius(MenuTokens.pillCornerRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: MenuTokens.pillCornerRadius)
                                .stroke(MenuTokens.pillBorder, lineWidth: 1)
                        )
                }
                if let suffix = suffix {
                    Text(suffix)
                        .font(.body)
                }
            }
        }
    }

    private func tryItStatusView(state: TryItState, inProgressText: String, completedText: String) -> some View {
        Group {
            switch state {
            case .waiting:
                EmptyView()
            case .inProgress:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(inProgressText)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            case .completed:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(completedText)
                        .font(.callout)
                        .foregroundColor(.green)
                }
            }
        }
        .frame(height: 28)
    }

    private func shortcutReference(shortcut: String, description: String) -> some View {
        HStack(spacing: 12) {
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.bold)
                .frame(width: 80, alignment: .trailing)
            Text(description)
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }
}
