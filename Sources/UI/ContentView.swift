// ContentView.swift
// Main app view — TabView with Draft and Style tabs

import SwiftUI
import Carbon

struct ContentView: View {
    @StateObject private var speech = SpeechEngine()
    @StateObject private var drafter = DraftEngine()
    @StateObject private var styleEngine = StyleEngine()
    @StateObject private var logger = AppLogger()
    @StateObject private var previousAppTracker = PreviousAppTracker()
    @StateObject private var contextCapture = ContextCaptureEngine()

    var body: some View {
        ZStack {
            TabView {
                DraftTab(
                    speech: speech,
                    drafter: drafter,
                    styleEngine: styleEngine,
                    logger: logger,
                    previousAppTracker: previousAppTracker,
                    contextCapture: contextCapture
                )
                .tabItem { Label("Draft", systemImage: "sparkles") }

                StyleProfileView(styleEngine: styleEngine)
                    .tabItem { Label("Style", systemImage: "person.text.rectangle") }
            }

            // Onboarding overlays (sequential gates)
            if !drafter.hasAPIKey {
                APIKeyEntryView(draftEngine: drafter)
            } else if !styleEngine.hasCompletedOnboarding {
                StyleOnboardingView(styleEngine: styleEngine, draftEngine: drafter)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .task {
            _ = await speech.requestPermissions()
            drafter.checkAPIKey()
            drafter.styleEngine = styleEngine

            // Wire up context capture
            contextCapture.registerHotkey()

            logger.log("🚀 APP LAUNCHED | permissions requested, API key checked, style: \(styleEngine.exampleCount) examples, hotkey registered")
        }
    }
}

// MARK: - Draft Tab

struct DraftTab: View {
    @ObservedObject var speech: SpeechEngine
    @ObservedObject var drafter: DraftEngine
    @ObservedObject var styleEngine: StyleEngine
    @ObservedObject var logger: AppLogger
    @ObservedObject var previousAppTracker: PreviousAppTracker
    @ObservedObject var contextCapture: ContextCaptureEngine

    @State private var showSettings = false
    @State private var settingsName = UserDefaults.standard.string(forKey: "user-display-name") ?? ""
    @State private var showDebugLog = false
    @State private var inputText = ""
    @State private var textBeforeRecording = ""
    @State private var previousInputLength = 0
    @State private var lastCapturedContext: CapturedContext?
    @State private var isParallelCapture = false  // True when hotkey triggered parallel voice+vision
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Draft")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                // Context capture status
                if contextCapture.isCapturing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Capturing context...")
                            .font(.caption)
                            .foregroundColor(.purple)
                    }
                }

                Text(speech.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSettings) {
                    VStack(spacing: 16) {
                        Text("Settings")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your Name")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Your name", text: $settingsName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .onChange(of: settingsName) {
                                    let trimmed = settingsName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        UserDefaults.standard.set(trimmed, forKey: "user-display-name")
                                    }
                                }
                            Text("Used to identify your messages in screenshots")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        VStack(spacing: 4) {
                            Text("Key is stored in macOS Keychain")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Reset API Key") {
                                logger.log("🔑 API KEY reset")
                                drafter.clearAPIKey()
                                showSettings = false
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                        }
                    }
                    .padding(20)
                }
            }

            // Context label with capture button
            HStack {
                Text("Context")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    logger.log("📸 CAPTURE | manual trigger")
                    Task { await contextCapture.manualCapture(app: previousAppTracker.previousApp) }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.viewfinder")
                        Text("Capture Screen")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(contextCapture.isCapturing || previousAppTracker.previousApp == nil)

                Text("⌃⌥D")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(3)
            }

            // Capture error
            if let error = contextCapture.captureError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Input area
            TextEditor(text: $inputText)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .overlay(alignment: .topLeading, content: {
                    if inputText.isEmpty && !speech.isListening {
                        Text("Speak, type, or paste your rough thoughts here...")
                            .foregroundColor(.secondary)
                            .italic()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                })
                .focused($isInputFocused)
                .disabled(drafter.isDrafting)

            // Voice indicator
            if speech.isListening && !speech.volatileText.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text(speech.volatileText)
                        .font(.callout)
                        .foregroundColor(.blue)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }

            // Controls row
            HStack(spacing: 12) {
                // Record / Stop
                Button(action: {
                    // Cancel parallel auto-draft if user manually controls recording
                    isParallelCapture = false

                    if speech.isListening {
                        speech.stopListening()
                        let separator = textBeforeRecording.isEmpty || textBeforeRecording.hasSuffix("\n") || textBeforeRecording.hasSuffix(" ") ? "" : " "
                        inputText = textBeforeRecording + separator + speech.finalTranscript
                        logger.log("⏹️ STOP | total \(inputText.count) chars")
                    } else {
                        textBeforeRecording = inputText
                        speech.clear()
                        speech.startListening()
                        logger.log("▶️ RECORD | snapshotted \(inputText.count) chars")
                    }
                }) {
                    HStack {
                        Image(systemName: speech.isListening ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title2)
                        Text(speech.isListening ? "Stop" : "Record")
                            .fontWeight(.medium)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(speech.isListening ? .red : .blue)
                .keyboardShortcut("r", modifiers: .command)

                // Draft button
                Button(action: {
                    // Cancel parallel auto-draft if user manually clicks Draft
                    isParallelCapture = false

                    // Stop voice recording and collect final text
                    if speech.isListening {
                        speech.stopListening()
                        let separator = textBeforeRecording.isEmpty || textBeforeRecording.hasSuffix("\n") || textBeforeRecording.hasSuffix(" ") ? "" : " "
                        inputText = textBeforeRecording + separator + speech.finalTranscript
                    }

                    if let context = lastCapturedContext, context.hasConversation {
                        let platform = PlatformFormatter.detect(from: previousAppTracker.previousApp)
                        logger.log("✨ DRAFT | context-aware [\(platform.rawValue)] talking to \(context.talkingTo ?? "?")")
                        drafter.draftWithContext(
                            voiceText: inputText,
                            context: context,
                            platform: platform
                        )
                    } else {
                        logger.log("✨ DRAFT | sending \(inputText.count) chars to Haiku")
                        drafter.draftMessage(from: inputText)
                    }
                }) {
                    HStack {
                        Image(systemName: "sparkles")
                            .font(.title2)
                        Text("Draft")
                            .fontWeight(.medium)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || drafter.isDrafting || !drafter.hasAPIKey)
                .keyboardShortcut(.return, modifiers: .command)

                Spacer()

                // Clear
                Button(action: {
                    logger.log("🗑️ CLEAR | reset all")
                    inputText = ""
                    textBeforeRecording = ""
                    speech.clear()
                    drafter.clear()
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear")
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.bordered)
                .disabled(inputText.isEmpty && drafter.draftedText.isEmpty)
            }

            // Output area
            if drafter.isDrafting || !drafter.draftedText.isEmpty || drafter.error != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Drafted Message")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)

                        Spacer()

                        if !drafter.draftedText.isEmpty {
                            Button(action: { acceptAndCopy() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.on.doc")
                                    Text("Copy")
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(action: { acceptAndPasteToLastApp() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.uturn.left")
                                    Text("Paste to \(previousAppTracker.previousApp?.localizedName ?? "Last App")")
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(previousAppTracker.previousApp == nil)
                        }
                    }

                    if drafter.isDrafting {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Drafting...")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    } else if let error = drafter.error {
                        Text(error)
                            .font(.body)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        TextEditor(text: $drafter.draftedText)
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .scrollContentBackground(.hidden)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(Color.purple.opacity(0.05))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                )
            }

            // Debug log panel
            DisclosureGroup(isExpanded: $showDebugLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logger.entries.enumerated()), id: \.offset) { index, entry in
                                Text(entry)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                    .frame(maxHeight: 120)
                    .onChange(of: logger.entries.count) {
                        if let last = logger.entries.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            } label: {
                Text("Debug Log (\(logger.entries.count))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        // Sync speech into inputText
        .onChange(of: speech.finalTranscript) {
            guard speech.isListening || !speech.finalTranscript.isEmpty else { return }
            let separator = textBeforeRecording.isEmpty || textBeforeRecording.hasSuffix("\n") || textBeforeRecording.hasSuffix(" ") ? "" : " "
            inputText = textBeforeRecording + separator + speech.finalTranscript
            if !speech.volatileText.isEmpty {
                inputText += speech.volatileText
            }
            logger.log("📝 SPEECH FINAL | \"\(speech.finalTranscript.suffix(40))\"")
        }
        .onChange(of: speech.volatileText) {
            guard speech.isListening else { return }
            let separator = textBeforeRecording.isEmpty || textBeforeRecording.hasSuffix("\n") || textBeforeRecording.hasSuffix(" ") ? "" : " "
            inputText = textBeforeRecording + separator + speech.finalTranscript + speech.volatileText
            logger.log("💬 SPEECH VOLATILE | \"\(speech.volatileText.suffix(40))\"")
        }
        .onChange(of: drafter.draftedText) {
            if !drafter.draftedText.isEmpty {
                logger.log("✅ DRAFTED | received \(drafter.draftedText.count) chars from Haiku")
            }
        }
        .onChange(of: drafter.error) {
            if let error = drafter.error {
                logger.log("❌ DRAFT ERROR | \(error)")
            }
        }
        .onChange(of: inputText) {
            let diff = abs(inputText.count - previousInputLength)
            if diff > 5 && !speech.isListening {
                logger.log("✏️ INPUT CHANGED | \(inputText.count) chars (was \(previousInputLength))")
            }
            previousInputLength = inputText.count
        }
        // Wire context capture to pre-fill input
        .onAppear {
            // Fires immediately on hotkey — start voice recording in parallel with vision
            contextCapture.onHotkeyFired = {
                inputText = ""
                textBeforeRecording = ""
                lastCapturedContext = nil
                drafter.clear()
                speech.clear()

                // Start voice recording immediately
                speech.startListening()
                isParallelCapture = true
                isInputFocused = true

                logger.log("🚀 PARALLEL | hotkey fired, voice started, waiting for vision...")
            }

            // Fires when vision processing completes with structured context
            contextCapture.onContextCaptured = { context in
                lastCapturedContext = context

                logger.log("📸 CONTEXT RAW | platform=\(context.platform ?? "nil") talkingTo=\(context.talkingTo ?? "nil") formality=\(context.formality ?? "nil") conversation=\(context.conversation?.prefix(100) ?? "nil") hasConversation=\(context.hasConversation)")

                if isParallelCapture {
                    // Inject context at the TOP of the input by setting textBeforeRecording.
                    // The speech .onChange handlers rebuild inputText as:
                    //   textBeforeRecording + separator + speech.finalTranscript + volatileText
                    // So this naturally prepends context above voice text.
                    let contextPrefix = context.displayText
                    if !contextPrefix.isEmpty {
                        textBeforeRecording = contextPrefix + "\n\nYOUR INSTRUCTIONS:\n"
                        // Trigger an immediate rebuild of inputText with the context prefix
                        let separator = ""
                        inputText = textBeforeRecording + separator + speech.finalTranscript + speech.volatileText
                        logger.log("📎 PARALLEL | injected context at top: \(contextPrefix.prefix(60))")
                    }

                    // Check if speech is also done → auto-draft
                    if speech.speechFinished {
                        logger.log("✅ PARALLEL | vision arrived, speech already done → auto-draft")
                        triggerAutoDraft()
                    } else {
                        logger.log("⏳ PARALLEL | vision done, waiting for speech to finish...")
                    }
                } else {
                    // Manual capture mode: fill input with context as before
                    inputText = context.displayText
                    drafter.clear()
                    isInputFocused = true
                }
            }
        }
        .onChange(of: contextCapture.captureError) {
            if let error = contextCapture.captureError {
                logger.log("❌ CAPTURE ERROR | \(error)")
            }
        }
        // Auto-draft trigger: speech finished in parallel mode
        .onChange(of: speech.speechFinished) {
            guard speech.speechFinished, isParallelCapture else { return }
            guard lastCapturedContext != nil else {
                logger.log("⏳ PARALLEL | speech done, waiting for vision...")
                return
            }
            logger.log("✅ PARALLEL | speech finished, vision already done → auto-draft")
            triggerAutoDraft()
        }
    }

    // MARK: - Parallel Pipeline Auto-Draft

    private func triggerAutoDraft() {
        // Stop recording, collect final text
        speech.stopListening()
        let separator = textBeforeRecording.isEmpty || textBeforeRecording.hasSuffix("\n") || textBeforeRecording.hasSuffix(" ") ? "" : " "
        inputText = textBeforeRecording + separator + speech.finalTranscript

        isParallelCapture = false

        // Need voice input to draft
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.log("⚠️ PARALLEL | no voice input, skipping auto-draft")
            return
        }

        let platform = PlatformFormatter.detect(from: previousAppTracker.previousApp)
        logger.log("✨ AUTO-DRAFT | parallel complete, drafting [\(platform.rawValue)]")
        drafter.draftWithContext(voiceText: inputText, context: lastCapturedContext, platform: platform)
    }

    // MARK: - Accept & Copy/Paste

    private func acceptAndCopy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(drafter.draftedText, forType: .string)
        logger.log("📋 COPY | \(drafter.draftedText.count) chars to clipboard")
        recordAcceptedExample()
    }

    private func acceptAndPasteToLastApp() {
        recordAcceptedExample()
        pasteToLastApp(drafter.draftedText)
    }

    private func recordAcceptedExample() {
        styleEngine.recordExample(acceptedMessage: drafter.draftedText)
        logger.log("📚 STYLE | recorded example #\(styleEngine.exampleCount)")

        // Regenerate style summary every 5 examples
        if styleEngine.exampleCount % 5 == 0, let apiKey = drafter.getAPIKey() {
            logger.log("🔄 STYLE | regenerating summary at \(styleEngine.exampleCount) examples")
            Task {
                await styleEngine.regenerateStyleSummary(apiKey: apiKey)
                logger.log("✅ STYLE | summary updated")
            }
        }
    }

    // MARK: - Paste to Last App

    private func pasteToLastApp(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let trusted = AXIsProcessTrusted()
        if !trusted {
            logger.log("⚠️ PASTE | requesting Accessibility permission")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let _ = AXIsProcessTrustedWithOptions(options)
            return
        }

        let appName = previousAppTracker.previousApp?.localizedName ?? "Last App"
        logger.log("📤 PASTE TO \(appName) | \(text.count) chars")

        previousAppTracker.previousApp?.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
            vDown?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)

            let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
            vUp?.flags = .maskCommand
            vUp?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Style Profile Tab

struct StyleProfileView: View {
    @ObservedObject var styleEngine: StyleEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Writing Style")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(styleEngine.exampleCount) examples")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(4)
            }

            if styleEngine.exampleCount == 0 {
                VStack(spacing: 8) {
                    Text("No examples yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Draft a message and hit Copy or Paste — each accepted message teaches Draft your style.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(styleEngine.styleFileContents)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
    }
}
