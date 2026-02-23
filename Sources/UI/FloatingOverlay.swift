// FloatingOverlay.swift
// Non-activating floating panel for the hotkey -> speak -> draft -> inject flow
// Saga-inspired dark overlay with mint green accent and mode-switching bubbles

import SwiftUI
import AppKit

// MARK: - Design Tokens (semi-transparent for glassmorphism blur)

private let panelBg       = Color.black.opacity(0.58)                   // translucent for blur
private let contentBg     = Color.black.opacity(0.14)                   // subtle content tint
private let bubbleBg      = Color.white.opacity(0.07)                   // frosted bubble fill
private let accentGreen   = Color(red: 0.07, green: 0.94, blue: 0.58)  // #13EF95  mint green
private let textPrimary   = Color.white
private let textSecondary = Color(white: 0.55)                          // gray labels
private let textMuted     = Color(white: 0.35)                          // placeholder
private let recordingRed  = Color.red

// MARK: - Layout Constants

private let overlayPanelWidth: CGFloat     = 480
private let overlayPanelMinHeight: CGFloat = 160
private let overlayPanelMaxHeight: CGFloat = 340
private let overlaySidebarWidth: CGFloat   = 60
private let overlayBubbleSize: CGFloat     = 40
private let overlayCornerRadius: CGFloat   = 16
private let overlayContentPadding: CGFloat = 16

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
        self.level = .popUpMenu  // Above .floating (3) — ensures visibility over Electron apps, status bars, etc.
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
    enum SessionMode {
        case draft      // Option+Space: screenshot + voice + AI rewrite + review
        case dictation  // Option+D: voice + light polish + auto-paste
    }

    enum OverlayState {
        case idle
        case listening    // Recording (both modes)
        case drafting     // Processing (vision+draft for draft mode, polish for dictation)
        case streaming    // Tokens arriving (draft mode only)
        case review       // Editable draft (draft mode only)
    }

    @Published var state: OverlayState = .idle
    @Published var activeMode: SessionMode = .draft
    @Published var isVisible = false
    @Published var reviewText: String = ""
    @Published var streamingText: String = ""

    /// Closures for Enter/Escape in review mode — set by DraftSessionController
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Closure for bubble-tap mode switching — set by DraftSessionController
    var onSwitchMode: ((SessionMode) -> Void)?

    private var panel: FloatingOverlayPanel?
    private var hostingView: NSHostingView<AnyView>?

    private var dragHandleView: PanelDragView?

    var whisperEngine: WhisperEngine?

    func setup(whisperEngine: WhisperEngine) {
        self.whisperEngine = whisperEngine
        let panel = FloatingOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: overlayPanelWidth, height: overlayPanelMinHeight),
            styleMask: [],
            backing: .buffered,
            defer: true
        )

        // Glassmorphism: NSVisualEffectView behind SwiftUI content
        let blurView = NSVisualEffectView()
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = overlayCornerRadius
        blurView.frame = panel.contentView?.bounds ?? .zero
        blurView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(blurView)

        let content = OverlayContentView(whisperEngine: whisperEngine, controller: self)
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting, positioned: .above, relativeTo: blurView)

        // Add drag handle at the top of the panel — pure AppKit, outside SwiftUI hierarchy.
        // This avoids NSViewRepresentable bridging which can crash during nested run loops
        // (DesignLibrary + swift_task_isCurrentExecutorWithFlagsImpl during layout passes).
        let headerHeight: CGFloat = 40
        let contentBounds = panel.contentView?.bounds ?? .zero
        let dragView = PanelDragView()
        dragView.panel = panel
        dragView.frame = NSRect(
            x: overlaySidebarWidth,
            y: contentBounds.height - headerHeight,
            width: contentBounds.width - overlaySidebarWidth,
            height: headerHeight
        )
        dragView.autoresizingMask = [.width, .minYMargin]  // Stay at top, stretch width
        panel.contentView?.addSubview(dragView, positioned: .above, relativeTo: hosting)
        self.dragHandleView = dragView

        // Round corners on the panel's content view
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = overlayCornerRadius
        panel.contentView?.layer?.masksToBounds = true

        self.panel = panel
        self.hostingView = hosting
    }

    /// Unified show method — positions the panel near the user's cursor/text field
    func showPanel(near sourceApp: NSRunningApplication?) {
        guard let panel = panel else { return }

        let rawTargetRect = sourceApp.flatMap { AccessibilityBridge.focusedTextFieldRect(for: $0) }
        let panelSize = NSSize(width: overlayPanelWidth, height: overlayPanelMinHeight)

        // Validate the accessibility rect — terminal emulators (iTerm2) report their entire
        // scrollback buffer as the text area rect (e.g., 4032px tall on a 982px screen).
        // Reject any rect taller/wider than the current screen — it's not a real visible field.
        let mousePos = NSEvent.mouseLocation
        let currentScreen = NSScreen.screens.first { NSMouseInRect(mousePos, $0.frame, false) }
            ?? NSScreen.main
        let screenSize = currentScreen?.frame.size ?? NSSize(width: 1920, height: 1080)
        let targetRect: CGRect?
        if let raw = rawTargetRect,
           raw.height > 0, raw.height <= screenSize.height,
           raw.width > 0, raw.width <= screenSize.width {
            targetRect = raw
        } else {
            targetRect = nil  // Fall through to mouse-cursor positioning
        }

        var origin: NSPoint
        if let rect = targetRect, let screen = NSScreen.main {
            // Primary path: position above the focused text field
            let screenHeight = screen.frame.height
            let flippedY = screenHeight - rect.origin.y
            origin = NSPoint(
                x: rect.midX - panelSize.width / 2,
                y: flippedY + 12
            )
        } else {
            // Fallback: position near mouse cursor (terminal apps, oversized text areas)
            origin = NSPoint(
                x: mousePos.x - panelSize.width / 2,
                y: mousePos.y + 20
            )
        }

        // Clamp to the screen the mouse is on — prevents off-screen positioning
        // on multi-monitor setups or when cursor is near the top/edge of a display
        if let visibleFrame = currentScreen?.visibleFrame {
            origin.x = max(visibleFrame.minX + 10,
                           min(origin.x, visibleFrame.maxX - panelSize.width - 10))
            if origin.y + panelSize.height > visibleFrame.maxY {
                origin.y = (targetRect != nil)
                    ? origin.y - panelSize.height - 24  // Below text field
                    : mousePos.y - panelSize.height - 10  // Below cursor
            }
            origin.y = max(visibleFrame.minY + 10, origin.y)
        }

        panel.setFrameOrigin(origin)
        panel.setContentSize(panelSize)
        panel.allowKeyStatus = false

        // Spring entrance: start transparent + slightly scaled down
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        if let contentLayer = panel.contentView?.layer {
            // Scale from 0.88 → 1.0 with spring physics
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.88
            spring.toValue = 1.0
            spring.damping = 18
            spring.stiffness = 280
            spring.initialVelocity = 3
            spring.duration = spring.settlingDuration
            contentLayer.add(spring, forKey: "entranceScale")
        }

        // Fade in over 200ms
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        })

        isVisible = true
    }

    func showReview(text: String) {
        reviewText = text
        state = .review

        // Resize: grow upward from bottom edge to fit text
        let lineCount = max(1, text.components(separatedBy: "\n").count)
        let charEstimate = CGFloat(text.count) / 50.0  // ~50 chars per line at 480pt width
        let lines = max(CGFloat(lineCount), charEstimate)
        let estimatedHeight = max(overlayPanelMinHeight, min(overlayPanelMaxHeight, lines * 20 + 120))
        resizePanel(to: NSSize(width: overlayPanelWidth, height: estimatedHeight))

        // Make key-capable so TextEditor receives input
        if let panel = panel {
            panel.allowKeyStatus = true
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func startStreaming(near sourceApp: NSRunningApplication? = nil) {
        streamingText = ""
        state = .streaming
        // Show panel if not visible
        if !isVisible {
            showPanel(near: sourceApp)
        }
        // Resize to initial streaming size
        resizePanel(to: NSSize(width: overlayPanelWidth, height: overlayPanelMinHeight))
        // Not key-capable yet (still receiving tokens)
        panel?.allowKeyStatus = false
    }

    func appendStreamToken(_ token: String) {
        streamingText += token
        // Dynamically resize as text grows
        let lineCount = max(1, streamingText.components(separatedBy: "\n").count)
        let charEstimate = CGFloat(streamingText.count) / 50.0
        let lines = max(CGFloat(lineCount), charEstimate)
        let estimatedHeight = max(overlayPanelMinHeight, min(overlayPanelMaxHeight, lines * 20 + 120))
        if let panel = panel, abs(panel.frame.height - estimatedHeight) > 20 {
            resizePanel(to: NSSize(width: overlayPanelWidth, height: estimatedHeight))
        }
    }

    func finishStreaming() {
        // Transfer to editable review
        showReview(text: streamingText)
        streamingText = ""
    }

    func hide() {
        _performHide()
    }

    /// Confirm animation: scale down + fade (content "sends" toward target app)
    func hideWithConfirmAnimation(completion: (() -> Void)? = nil) {
        guard let panel = panel else { completion?(); _performHide(); return }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            completion?()
            self?._performHide()
        })

        if let contentLayer = panel.contentView?.layer {
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.0
            shrink.toValue = 0.93
            shrink.duration = 0.14
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            contentLayer.add(shrink, forKey: "confirmShrink")
        }
    }

    /// Cancel animation: horizontal shake + fade (signals "nothing happened")
    func hideWithCancelAnimation(completion: (() -> Void)? = nil) {
        guard let panel = panel else { completion?(); _performHide(); return }

        // Horizontal shake using the window frame (not layer — layers don't move windows)
        let baseX = panel.frame.origin.x
        let offsets: [CGFloat] = [7, -5, 3, -1, 0]
        let stepDuration = 0.068  // ~340ms total for 5 steps

        for (i, offset) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration * Double(i)) {
                var frame = panel.frame
                frame.origin.x = baseX + offset
                panel.setFrame(frame, display: false)
            }
        }

        // Fade out after shake completes
        DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration * Double(offsets.count)) { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                completion?()
                self?._performHide()
            })
        }
    }

    private func _performHide() {
        panel?.allowKeyStatus = false
        panel?.orderOut(nil)
        panel?.alphaValue = 1.0  // Reset for next show
        panel?.contentView?.layer?.removeAllAnimations()
        isVisible = false
        state = .idle
        reviewText = ""
        streamingText = ""
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

// MARK: - Drag Handle (AppKit-level, outside SwiftUI hierarchy)

/// Transparent NSView that initiates a native window drag on mouseDown.
/// Uses NSWindow.performDrag(with:) which respects .nonactivatingPanel automatically.
/// Lives as a pure AppKit subview of the panel's content view — NOT an NSViewRepresentable.
/// This avoids executor isolation crashes during nested run loop body evaluations.
private class PanelDragView: NSView {
    weak var panel: NSPanel?

    override func mouseDown(with event: NSEvent) {
        if let panel = panel {
            panel.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

// MARK: - SwiftUI Overlay Content

struct OverlayContentView: View {
    @ObservedObject var whisperEngine: WhisperEngine
    @ObservedObject var controller: FloatingOverlayController
    @FocusState private var isReviewFocused: Bool
    @State private var lockInScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar with mode bubbles
            sidebarView

            // Thin vertical separator
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)

            // Right content area
            VStack(spacing: 0) {
                headerBar
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                bottomToolbar
            }
        }
        .background(panelBg)
        .onChange(of: whisperEngine.isTranscribing) {
            if !whisperEngine.isTranscribing {
                // Whisper finished — spring pulse "lock-in" (1.0 → 1.022 → 1.0)
                withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) {
                    lockInScale = 1.022
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        lockInScale = 1.0
                    }
                }
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarView: some View {
        VStack(spacing: 12) {
            Spacer()
            modeBubble(
                mode: .draft,
                symbol: "pencil.line",
                label: "Draft"
            )
            modeBubble(
                mode: .dictation,
                symbol: "waveform",
                label: "Dictate"
            )
            Spacer()
        }
        .frame(width: overlaySidebarWidth)
        .background(panelBg)
    }

    @ViewBuilder
    private func modeBubble(
        mode: FloatingOverlayController.SessionMode,
        symbol: String,
        label: String
    ) -> some View {
        let isActive = controller.activeMode == mode && controller.state != .idle

        Button(action: {
            controller.onSwitchMode?(mode)
        }) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(isActive ? accentGreen.opacity(0.15) : bubbleBg)
                        .frame(width: overlayBubbleSize, height: overlayBubbleSize)

                    if isActive {
                        Circle()
                            .strokeBorder(accentGreen, lineWidth: 2)
                            .frame(width: overlayBubbleSize, height: overlayBubbleSize)
                    }

                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isActive ? accentGreen : textSecondary)
                }

                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isActive ? accentGreen : textMuted)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Header Bar

    @ViewBuilder
    private var headerBar: some View {
        HStack {
            // Mode label
            Group {
                switch (controller.state, controller.activeMode) {
                case (.listening, .draft):
                    HStack(spacing: 8) {
                        Label("Draft Mode", systemImage: "pencil.line")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(textSecondary)
                        AudioWaveformView(level: whisperEngine.audioLevel, compact: true)
                    }
                case (.listening, .dictation):
                    HStack(spacing: 8) {
                        Label("Dictation", systemImage: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(textSecondary)
                        AudioWaveformView(level: whisperEngine.audioLevel, compact: true)
                    }
                case (.drafting, .dictation):
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(accentGreen)
                        Text("Polishing...")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(textSecondary)
                    }
                case (.drafting, _), (.streaming, _):
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(accentGreen)
                        Text("Drafting...")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(textSecondary)
                    }
                case (.review, _):
                    Text("Review Draft")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(textSecondary)
                default:
                    Text("Draft")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(textMuted)
                }
            }

            // Subtle drag grip indicator
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8))
                .foregroundColor(textMuted.opacity(0.5))

            Spacer()

            // Shortcut hint
            Group {
                switch (controller.state, controller.activeMode) {
                case (.listening, .draft):
                    Text("\u{2325}Space to stop")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                case (.listening, .dictation):
                    Text("\u{2325}D to stop")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                case (.review, _):
                    Text("Esc cancel")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, overlayContentPadding)
        .padding(.vertical, 10)
    }

    // MARK: - Central Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch controller.state {
        case .listening:
            listeningContent
        case .drafting:
            draftingContent
        case .streaming:
            streamingContent
        case .review:
            reviewContent
        case .idle:
            idleContent
        }
    }

    @ViewBuilder
    private var listeningContent: some View {
        Group {
            if !whisperEngine.liveTranscript.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        AnimatedTranscriptView(text: whisperEngine.liveTranscript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("transcript")
                    }
                    .onChange(of: whisperEngine.liveTranscript) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("transcript", anchor: .bottom)
                        }
                    }
                }
            } else {
                Text(controller.activeMode == .dictation
                     ? "Recording... press \u{2325}D to stop"
                     : "Recording... press \u{2325}Space to stop")
                    .font(.system(size: 12))
                    .foregroundColor(textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, overlayContentPadding)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var draftingContent: some View {
        VStack(spacing: 8) {
            if whisperEngine.isTranscribing, !whisperEngine.liveTranscript.isEmpty {
                // Show live transcript at reduced opacity with blur (provisional feel)
                ScrollView(.vertical, showsIndicators: false) {
                    AnimatedTranscriptView(text: whisperEngine.liveTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .opacity(0.45)
                .blur(radius: 0.5)
                .scaleEffect(lockInScale)

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(accentGreen)
                    Text("Refining...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(textSecondary)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(accentGreen)
                Text(whisperEngine.isTranscribing ? "Transcribing..." : "Processing...")
                    .font(.system(size: 12))
                    .foregroundColor(textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(overlayContentPadding)
    }

    @ViewBuilder
    private var streamingContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(controller.streamingText)
                .font(.system(size: 13))
                .foregroundColor(textPrimary)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, overlayContentPadding)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var reviewContent: some View {
        TextEditor(text: $controller.reviewText)
            .focused($isReviewFocused)
            .font(.system(size: 13))
            .foregroundColor(textPrimary)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, overlayContentPadding - 4)
            .padding(.vertical, 8)
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
            .onAppear {
                // Small delay lets the panel finish becoming key before we claim focus
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isReviewFocused = true
                }
            }
    }

    @ViewBuilder
    private var idleContent: some View {
        Text("Press \u{2325}Space or \u{2325}D to start")
            .font(.system(size: 12))
            .foregroundColor(textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Toolbar

    @ViewBuilder
    private var bottomToolbar: some View {
        HStack {
            // Left: status indicator
            Group {
                switch controller.state {
                case .listening:
                    HStack(spacing: 6) {
                        Circle()
                            .fill(recordingRed)
                            .frame(width: 6, height: 6)
                            .modifier(PulsingDotModifier())
                        Text("Recording")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(textSecondary)
                    }
                case .drafting, .streaming:
                    HStack(spacing: 6) {
                        Circle()
                            .fill(accentGreen)
                            .frame(width: 6, height: 6)
                        Text("Working...")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(textSecondary)
                    }
                case .review:
                    Text("\u{21A9} Enter to send")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(textSecondary)
                default:
                    EmptyView()
                }
            }

            Spacer()

            // Right: keyboard shortcut hints
            Group {
                switch (controller.state, controller.activeMode) {
                case (.listening, .draft):
                    Text("\u{2325}Space stop \u{00B7} Esc cancel")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                case (.listening, .dictation):
                    Text("\u{2325}D stop \u{00B7} Esc cancel")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                case (.review, _):
                    Text("\u{21E7}\u{21A9} newline \u{00B7} Esc cancel")
                        .font(.system(size: 10))
                        .foregroundColor(textMuted)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, overlayContentPadding)
        .padding(.vertical, 8)
    }
}

// MARK: - Pulsing Dot Animation

private struct PulsingDotModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Draft Session Controller

@MainActor
class DraftSessionController: ObservableObject {
    @Published var isInSession = false
    @Published var isDictating = false

    var appState: DraftAppState!
    var overlayController: FloatingOverlayController! {
        didSet {
            overlayController?.onSwitchMode = { [weak self] mode in
                self?.switchToMode(mode)
            }
        }
    }

    private var lastCapturedContext: CapturedContext?
    private var sessionSourceApp: NSRunningApplication?
    private var streamingTask: Task<Void, Never>?
    private var visionTask: Task<Void, Never>?

    // MARK: - Mode Switching (Bubble Taps)

    /// Called when a sidebar bubble is tapped
    func switchToMode(_ newMode: FloatingOverlayController.SessionMode) {
        if newMode == overlayController.activeMode {
            // Tapped the currently active mode — act as stop/toggle
            if newMode == .draft {
                if overlayController.state == .review {
                    cancelSession()
                } else if isInSession {
                    stopSessionAndDraft()
                }
            } else {
                if isDictating {
                    stopDictationAndPaste()
                }
            }
            return
        }

        // Switching to a different mode — cancel current, start new
        if isInSession { cancelSession() }
        if isDictating { cancelDictation() }

        if newMode == .draft {
            let frontApp = NSWorkspace.shared.frontmostApplication
            let imageData = frontApp.flatMap { ScreenCapture.captureFrontmostWindow(of: $0) }
            startSession(imageData: imageData, sourceApp: frontApp)
        } else {
            startDictation(sourceApp: sessionSourceApp ?? NSWorkspace.shared.frontmostApplication)
        }
    }

    // MARK: - Draft Mode (Option+Space)

    /// Start a new recording session — called on first hotkey press
    func startSession(imageData: Data?, sourceApp: NSRunningApplication?) {
        guard !isInSession, !isDictating else { return }
        isInSession = true
        sessionSourceApp = sourceApp

        // Store source app for paste-back
        if let app = sourceApp {
            appState.contextCapture.sourceApp = app
        }

        lastCapturedContext = nil
        appState.drafter.clear()

        // Show overlay and start recording
        overlayController.activeMode = .draft
        overlayController.state = .listening
        overlayController.showPanel(near: sourceApp)
        appState.whisperEngine.startRecording()

        appState.logger.log("SESSION | started (Whisper), voice recording + vision in parallel")

        // Start vision processing in parallel (stored so we can await it before drafting)
        visionTask = Task {
            await processVision(imageData: imageData, sourceApp: sourceApp)
        }
    }

    /// Stop recording and trigger drafting — called on second hotkey press
    func stopSessionAndDraft() {
        guard isInSession else { return }
        overlayController.state = .drafting

        streamingTask = Task {
            // Stop Whisper recording and batch-transcribe
            appState.whisperEngine.stopRecording()
            let voiceText = (await appState.whisperEngine.transcribe() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !voiceText.isEmpty else {
                appState.logger.log("SESSION | no voice input, cancelling")
                cancelSession()
                return
            }

            let platform = PlatformFormatter.detect(from: sessionSourceApp)

            guard let auth = AuthCredential.load() else {
                cancelSession()
                return
            }

            // Wait for vision to complete (or its 8-second timeout) before checking context
            await visionTask?.value
            visionTask = nil

            appState.logger.log("SESSION | streaming draft [\(platform.rawValue)] — \(voiceText.count) chars, context: \(lastCapturedContext?.hasConversation == true ? "yes" : "no")")

            var systemPrompt = appState.styleEngine.buildSystemPrompt()
            if !platform.formattingInstructions.isEmpty {
                systemPrompt += "\n\n" + platform.formattingInstructions
            }

            let userMessage: String
            if let context = lastCapturedContext, context.hasConversation {
                userMessage = context.draftingPrompt(userInstructions: voiceText)
            } else {
                userMessage = "The user dictated the following message. Clean it up, fix grammar, and make it sound natural while preserving their intent and tone. Do NOT add greetings, sign-offs, or change the meaning. Output ONLY the cleaned-up message.\n\nDICTATED:\n\(voiceText.trimmingCharacters(in: .whitespacesAndNewlines))"
            }

            let model = appState.promptStore.config.draftModel
            let stream = AnthropicAPI.streamDraft(
                rawText: userMessage,
                auth: auth,
                model: model,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt
            )

            var fullText = ""
            var gotFirstToken = false

            do {
                for try await token in stream {
                    guard !Task.isCancelled else { break }
                    if !gotFirstToken {
                        gotFirstToken = true
                        overlayController.startStreaming(near: sessionSourceApp)
                    }
                    fullText += token
                    overlayController.appendStreamToken(token)
                }
            } catch {
                guard !Task.isCancelled else { return }
                appState.logger.log("SESSION | stream error: \(error.localizedDescription)")
                overlayController.hideWithCancelAnimation()
                isInSession = false
                return
            }

            guard !Task.isCancelled, !fullText.isEmpty else {
                if !Task.isCancelled {
                    appState.logger.log("SESSION | empty draft")
                    overlayController.hideWithCancelAnimation()
                    isInSession = false
                }
                return
            }

            let processed = platform.postProcess(fullText)
            appState.drafter.originalDraft = processed
            appState.drafter.lastRawText = voiceText

            overlayController.onConfirm = { [weak self] in
                self?.confirmAndInject(platform: platform)
            }
            overlayController.onCancel = { [weak self] in
                self?.cancelSession()
            }
            overlayController.finishStreaming()
            appState.logger.log("REVIEW | streaming complete, \(processed.count) chars")
        }
    }

    func cancelSession() {
        visionTask?.cancel()
        visionTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        if appState.whisperEngine.isRecording {
            appState.whisperEngine.cancel()
        }
        overlayController.hideWithCancelAnimation()
        isInSession = false
        appState.logger.log("SESSION | cancelled")
    }

    // MARK: - Dictation Mode (Option+D)

    /// Start dictation — show overlay and begin voice recording (no screenshot/vision)
    func startDictation(sourceApp: NSRunningApplication?) {
        guard !isDictating, !isInSession else { return }
        isDictating = true
        sessionSourceApp = sourceApp

        if let app = sourceApp {
            appState.contextCapture.sourceApp = app
        }

        overlayController.activeMode = .dictation
        overlayController.state = .listening
        overlayController.showPanel(near: sourceApp)

        appState.whisperEngine.startRecording()
        appState.logger.log("DICTATION | started (Whisper)")
    }

    /// Stop dictation and paste — Whisper batch transcription
    func stopDictationAndPaste() {
        guard isDictating, overlayController.state == .listening else { return }
        overlayController.state = .drafting

        appState.whisperEngine.stopRecording()
        Task {
            let voiceText = await appState.whisperEngine.transcribe()

            guard let text = voiceText, !text.isEmpty else {
                appState.logger.log("DICTATION | no transcription, cancelling")
                cancelDictation()
                return
            }

            appState.logger.log("DICTATION | pasting \(text.count) chars")
            overlayController.hideWithConfirmAnimation { [weak self] in
                self?.pasteWithClipboardRestore(text)
            }
            isDictating = false
            appState.logger.log("DICTATION | pasted \(text.count) chars")
        }
    }

    /// Cancel dictation without pasting
    func cancelDictation() {
        if appState.whisperEngine.isRecording {
            appState.whisperEngine.cancel()
        }
        overlayController.hideWithCancelAnimation()
        isDictating = false
        appState.logger.log("DICTATION | cancelled")
    }

    /// Apply light polish (punctuation, capitalization, grammar) to raw dictation.
    /// Falls back to raw text if API call fails — dictation must NEVER lose text.
    private func polishDictation(_ rawText: String) async -> String {
        guard let auth = AuthCredential.load() else {
            appState.logger.log("DICTATION | no auth, pasting raw text")
            return rawText
        }

        let polishPrompt = """
            Fix punctuation, capitalization, and obvious grammar errors in this dictation. \
            Do NOT rephrase, reorganize, or change wording. Preserve the user's exact words. \
            Do NOT add greetings, sign-offs, or extra text. Output ONLY the corrected text.
            """

        let model = appState.promptStore.config.draftModel

        do {
            let polished = try await AnthropicAPI.withTimeout(seconds: 5) {
                try await AnthropicAPI.draft(
                    rawText: "DICTATED:\n\(rawText)",
                    auth: auth,
                    model: model,
                    systemPrompt: polishPrompt,
                    maxTokens: 1024
                )
            }

            // Sanity check: reject if length ratio is suspicious (hallucination or truncation)
            let ratio = Double(polished.count) / Double(max(1, rawText.count))
            if ratio < 0.5 || ratio > 2.0 {
                appState.logger.log("DICTATION | polish length suspicious (ratio \(String(format: "%.2f", ratio))), using raw")
                return rawText
            }

            return polished.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            appState.logger.log("DICTATION | polish failed: \(error.localizedDescription), pasting raw text")
            return rawText
        }
    }

    // MARK: - Private

    private func processVision(imageData: Data?, sourceApp: NSRunningApplication?) async {
        guard let auth = AuthCredential.load(), let imageData = imageData else {
            appState.logger.log("SESSION | no auth or screenshot, proceeding voice-only")
            return
        }

        let userName = UserDefaults.standard.string(forKey: "user-display-name")
        let appName = sourceApp?.localizedName
        let model = appState.promptStore.config.model
        let extractionPrompt = appState.promptStore.contextExtractionPrompt(userName: userName, appName: appName)

        do {
            // 8-second timeout — vision calls typically take 2-6s; 4s was too tight and caused frequent timeouts
            let context = try await AnthropicAPI.withTimeout(seconds: 8) {
                try await AnthropicAPI.extractStructuredContext(
                    imageData: imageData,
                    auth: auth,
                    model: model,
                    systemPrompt: extractionPrompt
                )
            }
            lastCapturedContext = context
            appState.logger.log("SESSION | vision complete — platform=\(context.platform ?? "nil")")
        } catch {
            appState.logger.log("SESSION | vision timeout/error: \(error.localizedDescription), proceeding voice-only")
            // Proceed without context — voiceText alone is enough to draft
        }
    }

    /// Detect if a draft is Claude refusing/asking for clarification rather than an actual message
    private func looksLikeRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let refusalPhrases = [
            "i need the actual",
            "i need more context",
            "could you provide",
            "i'd need to see",
            "please provide",
            "i can't write",
            "i don't have enough"
        ]
        return refusalPhrases.contains { lower.contains($0) }
    }

    /// Called by Enter key in review — injects the (possibly edited) text
    private func confirmAndInject(platform: PlatformFormatter) {
        guard isInSession else { return }
        let editedText = overlayController.reviewText
        let originalDraft = appState.drafter.originalDraft

        // Confirm animation, then paste to target app
        overlayController.hideWithConfirmAnimation { [weak self] in
            self?.pasteWithClipboardRestore(editedText)
        }

        // Record with REAL edit data — but skip refusals to avoid poisoning style training
        if !looksLikeRefusal(originalDraft) {
            // Capture voice instructions + vision metadata for richer training signal
            let voiceInstructions = appState.drafter.lastRawText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let formalityLevel = lastCapturedContext?.formality

            appState.styleEngine.recordExample(
                aiDraft: originalDraft,
                userFinal: editedText,
                platform: platform.rawValue,
                userInstructions: voiceInstructions.isEmpty ? nil : voiceInstructions,
                formality: formalityLevel
            )
            appState.feedbackStore.record(
                rawText: voiceInstructions,
                draftedText: originalDraft,
                acceptedText: editedText,
                action: .paste,
                exampleCount: appState.styleEngine.exampleCount,
                formality: formalityLevel
            )
        } else {
            appState.logger.log("STYLE | skipping refusal example — not recording as training data")
        }

        // Check if style refinement is needed
        if appState.styleEngine.shouldRefineNow(), let auth = appState.drafter.getAuth() {
            Task {
                await appState.styleEngine.regenerateStyleSummary(auth: auth)
                appState.logger.log("STYLE | summary updated")
            }
        }

        isInSession = false
        appState.logger.log("SESSION | confirmed and injected (\(editedText.count) chars)")
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
            appState.logger.log("SESSION | requesting Accessibility permission")
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
