// FloatingOverlay.swift
// Non-activating floating panel for the hotkey → speak → draft → inject flow

import SwiftUI
import AppKit

// MARK: - NSPanel Subclass

class FloatingOverlayPanel: NSPanel {
    /// When true, the panel can become key window (for text editing in review mode)
    var allowKeyStatus = false

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        self.level = .floating
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // Dynamic: non-key during listening/drafting, key-capable during review
    override var canBecomeKey: Bool { allowKeyStatus }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay Controller

@MainActor
class FloatingOverlayController: ObservableObject {
    enum OverlayState {
        case idle
        case listening
        case drafting
        case review
    }

    @Published var state: OverlayState = .idle
    @Published var isVisible = false
    @Published var reviewText: String = ""

    /// Closures for Enter/Escape in review mode — set by DraftSessionController
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    private var panel: FloatingOverlayPanel?
    private var hostingView: NSHostingView<AnyView>?

    func setup(speech: SpeechEngine) {
        let panel = FloatingOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [],
            backing: .buffered,
            defer: true
        )

        let content = OverlayContentView(speech: speech, controller: self)
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)

        // Round corners on the panel's content view
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 20
        panel.contentView?.layer?.masksToBounds = true

        self.panel = panel
        self.hostingView = hosting
    }

    func show(near sourceApp: NSRunningApplication?) {
        guard let panel = panel else { return }

        // Try to position near the focused text field
        let targetRect = sourceApp.flatMap { AccessibilityBridge.focusedTextFieldRect(for: $0) }

        if let rect = targetRect, let screen = NSScreen.main {
            let screenHeight = screen.frame.height
            let flippedY = screenHeight - rect.origin.y
            let overlayWidth: CGFloat = 400
            let x = max(10, rect.midX - overlayWidth / 2)
            let y = flippedY + 12
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            if let screen = NSScreen.main {
                let x = screen.frame.midX - 200
                let y = screen.frame.midY + 50
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }

        panel.setContentSize(NSSize(width: 400, height: 120))
        panel.orderFront(nil)
        isVisible = true
    }

    func showReview(text: String) {
        reviewText = text
        state = .review

        // Resize: grow upward from bottom edge to fit text
        let lineCount = max(1, text.components(separatedBy: "\n").count)
        let charEstimate = CGFloat(text.count) / 45.0  // ~45 chars per line at 400pt width
        let lines = max(CGFloat(lineCount), charEstimate)
        let estimatedHeight = max(160, min(280, lines * 20 + 100))
        resizePanel(to: NSSize(width: 400, height: estimatedHeight))

        // Make key-capable so TextEditor receives input
        if let panel = panel {
            panel.allowKeyStatus = true
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        panel?.allowKeyStatus = false
        panel?.orderOut(nil)
        isVisible = false
        state = .idle
        reviewText = ""
    }

    private func resizePanel(to size: NSSize) {
        guard let panel = panel else { return }
        var frame = panel.frame
        let heightDelta = size.height - frame.size.height
        frame.size = size
        frame.origin.y -= heightDelta  // Grow upward, bottom edge anchored
        panel.setFrame(frame, display: true, animate: true)
    }
}

// MARK: - SwiftUI Overlay Content

struct OverlayContentView: View {
    @ObservedObject var speech: SpeechEngine
    @ObservedObject var controller: FloatingOverlayController

    var body: some View {
        if controller.state == .review {
            reviewView
        } else {
            listenDraftView
        }
    }

    @ViewBuilder
    private var listenDraftView: some View {
        HStack(spacing: 12) {
            // Left: audio waveform
            if controller.state == .listening {
                AudioWaveformView(level: speech.audioLevel)
            } else {
                // Drafting spinner
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 32, height: 44)
            }

            VStack(alignment: .leading, spacing: 6) {
                // State label
                HStack(spacing: 6) {
                    if controller.state == .listening {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("Listening...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else {
                        Text("Drafting...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }

                // Transcription
                if !speech.displayText.isEmpty {
                    HStack(spacing: 0) {
                        Text(speech.finalTranscript)
                            .foregroundColor(.white)
                        Text(speech.volatileText)
                            .foregroundColor(.gray.opacity(0.7))
                    }
                    .font(.system(size: 13))
                    .lineLimit(3)
                } else if controller.state == .listening {
                    Text("Start speaking...")
                        .font(.system(size: 13))
                        .foregroundColor(.gray.opacity(0.5))
                        .italic()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 400, height: 120)
        .background(Color.black.opacity(0.88))
    }

    @ViewBuilder
    private var reviewView: some View {
        VStack(spacing: 0) {
            TextEditor(text: $controller.reviewText)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .onKeyPress(keys: [.return], phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        return .ignored  // Shift+Enter inserts newline
                    }
                    controller.onConfirm?()
                    return .handled
                }
                .onKeyPress(keys: [.escape], phases: .down) { _ in
                    controller.onCancel?()
                    return .handled
                }

            // Hint bar
            HStack {
                Text("Enter to send · ⇧Enter newline · Esc cancel")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.6))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.88))
    }
}

// MARK: - Draft Session Controller

@MainActor
class DraftSessionController: ObservableObject {
    @Published var isInSession = false

    var appState: DraftAppState!
    var overlayController: FloatingOverlayController!

    private var lastCapturedContext: CapturedContext?
    private var sessionSourceApp: NSRunningApplication?

    /// Start a new recording session — called on first hotkey press
    func startSession(imageData: Data?, sourceApp: NSRunningApplication?) {
        guard !isInSession else { return }
        isInSession = true
        sessionSourceApp = sourceApp

        // Store source app for paste-back
        if let app = sourceApp {
            appState.contextCapture.sourceApp = app
        }

        lastCapturedContext = nil
        appState.speech.clear()
        appState.drafter.clear()

        // Show overlay and start recording
        overlayController.state = .listening
        overlayController.show(near: sourceApp)
        appState.speech.startListening()

        appState.logger.log("🚀 SESSION | started, voice recording + vision in parallel")

        // Start vision processing in parallel
        Task {
            await processVision(imageData: imageData, sourceApp: sourceApp)
        }
    }

    /// Stop recording and trigger drafting — called on second hotkey press
    func stopSessionAndDraft() {
        guard isInSession else { return }
        appState.speech.stopListening()
        overlayController.state = .drafting

        // Collect final voice text
        let voiceText = (appState.speech.finalTranscript + appState.speech.volatileText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !voiceText.isEmpty else {
            appState.logger.log("⚠️ SESSION | no voice input, cancelling")
            cancelSession()
            return
        }

        let platform = PlatformFormatter.detect(from: sessionSourceApp)
        appState.logger.log("✨ SESSION | drafting [\(platform.rawValue)] — \(voiceText.count) chars")

        // Build input text with context if available
        var inputText = voiceText
        if let context = lastCapturedContext, context.hasConversation {
            inputText = context.displayText + "\n\nYOUR INSTRUCTIONS:\n" + voiceText
            appState.drafter.draftWithContext(voiceText: inputText, context: context, platform: platform)
        } else {
            appState.drafter.draftMessage(from: inputText)
        }

        // Watch for draft completion, then show review
        Task {
            await waitForDraftAndShowReview(platform: platform)
        }
    }

    func cancelSession() {
        if appState.speech.isListening {
            appState.speech.stopListening()
        }
        appState.speech.clear()
        overlayController.hide()
        isInSession = false
        appState.logger.log("❌ SESSION | cancelled")
    }

    // MARK: - Private

    private func processVision(imageData: Data?, sourceApp: NSRunningApplication?) async {
        guard let auth = AuthCredential.load(), let imageData = imageData else {
            appState.logger.log("⚠️ SESSION | no auth or screenshot, proceeding voice-only")
            return
        }

        let userName = UserDefaults.standard.string(forKey: "user-display-name")
        let appName = sourceApp?.localizedName
        let model = appState.promptStore.config.model
        let extractionPrompt = appState.promptStore.contextExtractionPrompt(userName: userName, appName: appName)

        do {
            let context = try await AnthropicAPI.extractStructuredContext(
                imageData: imageData,
                auth: auth,
                model: model,
                systemPrompt: extractionPrompt
            )
            lastCapturedContext = context
            appState.logger.log("📸 SESSION | vision complete — platform=\(context.platform ?? "nil") talkingTo=\(context.talkingTo ?? "nil")")
        } catch {
            appState.logger.log("⚠️ SESSION | vision failed: \(error.localizedDescription), proceeding voice-only")
        }
    }

    private func waitForDraftAndShowReview(platform: PlatformFormatter) async {
        // Poll for draft completion (check every 100ms, up to 30s)
        for _ in 0..<300 {
            if !appState.drafter.isDrafting {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard !appState.drafter.draftedText.isEmpty else {
            appState.logger.log("❌ SESSION | draft failed or empty")
            overlayController.hide()
            isInSession = false
            return
        }

        let draftedText = appState.drafter.draftedText
        appState.logger.log("👁 REVIEW | showing draft for review (\(draftedText.count) chars)")

        // Wire Enter/Escape closures before showing review
        overlayController.onConfirm = { [weak self] in
            self?.confirmAndInject(platform: platform)
        }
        overlayController.onCancel = { [weak self] in
            self?.cancelSession()
        }

        overlayController.showReview(text: draftedText)
    }

    /// Called by Enter key in review — injects the (possibly edited) text
    private func confirmAndInject(platform: PlatformFormatter) {
        guard isInSession else { return }
        let editedText = overlayController.reviewText
        let originalDraft = appState.drafter.originalDraft

        // Hide overlay first (resets key status)
        overlayController.hide()

        // Paste to target app
        pasteWithClipboardRestore(editedText)

        // Record with REAL edit data — this is the whole point
        appState.styleEngine.recordExample(
            aiDraft: originalDraft,
            userFinal: editedText,
            platform: platform.rawValue
        )
        appState.feedbackStore.record(
            rawText: appState.speech.finalTranscript,
            draftedText: originalDraft,
            acceptedText: editedText,
            action: .paste,
            exampleCount: appState.styleEngine.exampleCount
        )

        // Check if style refinement is needed
        if appState.styleEngine.shouldRefineNow(), let auth = appState.drafter.getAuth() {
            Task {
                await appState.styleEngine.regenerateStyleSummary(auth: auth)
                appState.logger.log("✅ STYLE | summary updated")
            }
        }

        isInSession = false
        appState.logger.log("✅ SESSION | confirmed and injected (\(editedText.count) chars)")
    }

    private func pasteWithClipboardRestore(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var typeData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeData[type] = data
                }
            }
            return typeData
        } ?? []

        // Set our drafted text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Check Accessibility permission
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            appState.logger.log("⚠️ SESSION | requesting Accessibility permission")
            return
        }

        // Simulate Cmd+V — target app is already frontmost (overlay is non-activating)
        let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)

        let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)

        // Restore clipboard after paste completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            for typeData in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in typeData {
                    item.setData(data, forType: type)
                }
                pasteboard.writeObjects([item])
            }
        }
    }
}
