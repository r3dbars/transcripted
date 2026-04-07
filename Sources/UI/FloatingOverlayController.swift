// FloatingOverlayController.swift
// State machine, animations, panel lifecycle, and global Escape monitor for the floating overlay
// Pure AppKit — no SwiftUI, no NSHostingView, no AttributeGraph

import AppKit
import Combine

@MainActor
class FloatingOverlayController {
    enum SessionMode {
        case dictation
    }

    enum OverlayState {
        case idle
        case loading      // Voice model still loading — waiting for readiness
        case listening    // Recording (both modes)
        case drafting     // Processing (vision+draft for draft mode, polish for dictation)
        case success      // Finished successfully — brief confirmation before dismiss
        case streaming    // Tokens arriving (draft mode only)
        case review       // Editable draft (draft mode only)
        case diffFlash    // Read-only word diff of user's edits before confirming
    }

    /// Human-readable shortcut hints (reads live from UserDefaults)
    var dictationShortcutHint: String {
        if HotkeyPreferences.rightOptionDictationEnabled() { return "Right ⌥" }
        return HotkeyPreferences.displayString(for: HotkeyPreferences.dictationBinding())
    }

    // MARK: - State (plain vars with didSet — no @Published, no ObservableObject)

    var state: OverlayState = .idle {
        didSet {
            guard state != oldValue else { return }
            pushStateToViews()
        }
    }
    var activeMode: SessionMode = .dictation {
        didSet { pushStateToViews() }
    }
    var isVisible = false
    var reviewText: String = ""
    var streamingText: String = ""
    var errorMessage: String = ""
    var loadingElapsedSeconds: Int = 0 {
        didSet { pushStateToViews() }
    }
    /// Closure for Escape during non-review states (listening/drafting/streaming)
    var onEscapeDuringSession: (() -> Void)?
    var onStopListening: (() -> Void)?

    // MARK: - Panel & Views

    private var panel: FloatingOverlayPanel?
    private var rootView: OverlayRootView?
    private var blurView: NSVisualEffectView?
    private var dragHandleView: PanelDragView?
    private var escapeMonitor: Any?

    /// Generation counter — incremented on every showPanel(), checked in async _performHide()
    private var hideGeneration: UInt64 = 0

    /// Combine subscriptions for engine state → view updates
    private var subscriptions = Set<AnyCancellable>()

    deinit {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        errorDismissTask?.cancel()
        loadingTimerTask?.cancel()
        successDismissTask?.cancel()
    }

    var sttRouter: STTRouter?

    // MARK: - Setup

    func setup(sttRouter: STTRouter) {
        guard panel == nil else {
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "setup_called_twice",
                message: "setup() called but panel already exists — ignoring")
            return
        }
        self.sttRouter = sttRouter
        let panel = FloatingOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: OverlayTokens.panelWidth, height: OverlayTokens.panelMinHeight),
            styleMask: [],
            backing: .buffered,
            defer: true
        )

        // Glassmorphism: NSVisualEffectView behind content
        let blurView = NSVisualEffectView()
        blurView.appearance = NSAppearance(named: .darkAqua)
        blurView.material = .underWindowBackground
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = OverlayTokens.cornerRadius
        blurView.layer?.backgroundColor = OverlayTokens.panelBg.cgColor
        blurView.layer?.borderWidth = 1
        blurView.layer?.borderColor = OverlayTokens.panelStroke.cgColor
        blurView.frame = panel.contentView?.bounds ?? .zero
        blurView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(blurView)
        self.blurView = blurView

        // Pure AppKit root view (replaces NSHostingView — no AttributeGraph, no AG corruption)
        let rootView = OverlayRootView(frame: panel.contentView?.bounds ?? .zero)
        rootView.autoresizingMask = [.width, .height]
        rootView.headerView.onStopRequested = { [weak self] in
            self?.onStopListening?()
        }
        panel.contentView?.addSubview(rootView, positioned: .above, relativeTo: blurView)
        self.rootView = rootView

        // Drag handle at the top — pure AppKit, above the root view
        let headerHeight: CGFloat = OverlayTokens.headerHeight
        let contentBounds = panel.contentView?.bounds ?? .zero
        let dragView = PanelDragView()
        dragView.panel = panel
        dragView.frame = NSRect(
            x: 0,
            y: contentBounds.height - headerHeight,
            width: contentBounds.width,
            height: headerHeight
        )
        dragView.autoresizingMask = [.width, .minYMargin]
        panel.contentView?.addSubview(dragView, positioned: .above, relativeTo: rootView)
        self.dragHandleView = dragView

        // Round corners on the panel's content view
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = OverlayTokens.cornerRadius
        panel.contentView?.layer?.masksToBounds = true
        panel.contentView?.layer?.borderWidth = 1
        panel.contentView?.layer?.borderColor = OverlayTokens.panelStroke.cgColor

        self.panel = panel

        // Combine subscriptions: push live engine data to views
        sttRouter.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.rootView?.headerView.updateWaveformLevel(level)
            }
            .store(in: &subscriptions)

        sttRouter.$isTranscribing
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.pushStateToViews()
            }
            .store(in: &subscriptions)
    }

    // MARK: - State → View Push

    /// Push current state to the AppKit view hierarchy. Called on state changes.
    private func pushStateToViews() {
        rootView?.updateForState(
            state,
            mode: activeMode,
            transcriptExpanded: false,
            hasContext: true,
            draftShortcutHint: "",
            dictationShortcutHint: dictationShortcutHint,
            errorMessage: errorMessage,
            loadingElapsedSeconds: loadingElapsedSeconds,
            isTranscribing: sttRouter?.isTranscribing ?? false,
            liveTranscript: sttRouter?.liveTranscript ?? "",
            originalDraft: "",
            reviewText: ""
        )
    }

    // MARK: - Panel Show/Hide

    func showPanel(near sourceApp: NSRunningApplication?) {
        guard let panel = panel else { return }

        // Invalidate any pending async _performHide() from a previous session's animation
        hideGeneration &+= 1

        // Cancel stale timers from a previous session
        errorDismissTask?.cancel()
        errorDismissTask = nil
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
        errorMessage = ""

        let rawTargetRect = sourceApp.flatMap { AccessibilityBridge.focusedTextFieldRect(for: $0) }
        let initialHeight = (state == .listening || state == .idle || state == .success)
            ? OverlayTokens.panelCompactHeight
            : OverlayTokens.panelMinHeight
        let panelSize = NSSize(width: OverlayTokens.panelWidth, height: initialHeight)

        // Validate the accessibility rect — terminal emulators report oversized text areas
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
            targetRect = nil
        }

        var origin: NSPoint
        if let rect = targetRect, let screen = NSScreen.main {
            let screenHeight = screen.frame.height
            let flippedY = screenHeight - rect.origin.y
            origin = NSPoint(
                x: rect.midX - panelSize.width / 2,
                y: flippedY + 12
            )
        } else {
            origin = NSPoint(
                x: mousePos.x - panelSize.width / 2,
                y: mousePos.y + 20
            )
        }

        // Clamp to current screen
        if let visibleFrame = currentScreen?.visibleFrame {
            origin.x = max(visibleFrame.minX + 10,
                           min(origin.x, visibleFrame.maxX - panelSize.width - 10))
            if origin.y + panelSize.height > visibleFrame.maxY {
                origin.y = (targetRect != nil)
                    ? origin.y - panelSize.height - 24
                    : mousePos.y - panelSize.height - 10
            }
            origin.y = max(visibleFrame.minY + 10, origin.y)
        }

        panel.setFrameOrigin(origin)
        panel.setContentSize(panelSize)
        panel.allowKeyStatus = false
        panel.ignoresMouseEvents = false

        // Spring entrance
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        if let contentLayer = panel.contentView?.layer {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.88
            spring.toValue = 1.0
            spring.damping = 18
            spring.stiffness = 280
            spring.initialVelocity = 3
            spring.duration = spring.settlingDuration
            contentLayer.add(spring, forKey: "entranceScale")
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        })

        isVisible = true
        pushStateToViews()
        installEscapeMonitor()
    }

    func enterDraftingState() {
        state = .drafting
        resizePanelToCompact()
    }

    func resizePanelToCompact() {
        resizePanelInstant(to: NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelCompactHeight))
    }

    // MARK: - Hide Animations

    func hideWithConfirmAnimation(completion: (() -> Void)? = nil) {
        guard let panel = panel else { completion?(); _performHide(); return }
        let gen = hideGeneration
        panel.ignoresMouseEvents = true

        // Demote panel from key BEFORE animation — prevents intercepting ⌘V paste
        panel.allowKeyStatus = false
        panel.resignKey()
        panel.orderOut(nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            completion?()
            Task { @MainActor [weak self] in
                guard let self = self, self.hideGeneration == gen else { return }
                self._performHide()
            }
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

    func hideWithCancelAnimation() {
        guard let panel = panel else { _performHide(); return }
        let gen = hideGeneration
        panel.ignoresMouseEvents = true

        let baseX = panel.frame.origin.x
        let offsets: [CGFloat] = [7, -5, 3, -1, 0]
        let stepDuration = 0.068

        for (i, offset) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration * Double(i)) { [weak panel] in
                guard let panel = panel else { return }
                var frame = panel.frame
                frame.origin.x = baseX + offset
                panel.setFrame(frame, display: false)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration * Double(offsets.count)) { [weak self, weak panel] in
            guard let panel = panel else {
                Task { @MainActor [weak self] in
                    guard let self = self, self.hideGeneration == gen else { return }
                    self._performHide()
                }
                return
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self, self.hideGeneration == gen else { return }
                    self._performHide()
                }
            })
        }
    }

    // MARK: - Error & Loading

    private var errorDismissTask: Task<Void, Never>?
    private var loadingTimerTask: Task<Void, Never>?
    private var successDismissTask: Task<Void, Never>?

    func showLoadingState() {
        errorDismissTask?.cancel()
        errorMessage = ""
        loadingElapsedSeconds = 0
        state = .loading
        if !isVisible {
            showPanel(near: nil)
        }
        resizePanel(to: NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelMinHeight))
        loadingTimerTask?.cancel()
        loadingTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, !Task.isCancelled, self.state == .loading else { break }
                self.loadingElapsedSeconds += 1
            }
        }
    }

    func showError(_ message: String) {
        errorDismissTask?.cancel()
        errorMessage = message
        state = .drafting
        resizePanel(to: NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelMinHeight))
        if !isVisible {
            showPanel(near: nil)
        }
        pushStateToViews()  // Force update for error message
        errorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: DraftConstants.errorDismissDelay)
            } catch { return }
            guard let self = self, !self.errorMessage.isEmpty else { return }
            self.errorMessage = ""
            self.hideWithCancelAnimation()
        }
    }

    /// Fast dismiss for "no speech detected" — brief flash then clean fade (no shake).
    func showNoSpeechAndDismiss() {
        errorDismissTask?.cancel()
        errorMessage = "No speech detected"
        state = .drafting
        resizePanel(to: NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelMinHeight))
        if !isVisible {
            showPanel(near: nil)
        }
        pushStateToViews()
        errorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: DraftConstants.noSpeechDismissDelay)
            } catch { return }
            guard let self = self else { return }
            self.errorMessage = ""
            self.hideWithConfirmAnimation()
        }
    }

    func showSuccessAndDismiss(completion: (() -> Void)? = nil) {
        errorDismissTask?.cancel()
        loadingTimerTask?.cancel()
        successDismissTask?.cancel()
        errorMessage = ""
        state = .success
        resizePanelToCompact()
        if !isVisible {
            showPanel(near: nil)
        }
        pushStateToViews()
        successDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch { return }
            guard let self else { return }
            self.hideWithConfirmAnimation(completion: completion)
        }
    }

    // MARK: - Internal Hide

    private func _performHide() {
        guard isVisible else { return }
        removeEscapeMonitor()
        panel?.ignoresMouseEvents = true
        panel?.allowKeyStatus = false
        panel?.orderOut(nil)
        panel?.alphaValue = 1.0
        panel?.contentView?.layer?.removeAllAnimations()

        isVisible = false
        errorDismissTask?.cancel()
        errorDismissTask = nil
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
        successDismissTask?.cancel()
        successDismissTask = nil
        state = .idle
        reviewText = ""
        streamingText = ""
        errorMessage = ""
    }

    // MARK: - System Wake Recovery & Periodic AG Refresh

    func handleSystemWake() {
        // No NSHostingView to recreate. AppKit views survive sleep/wake without corruption.
        // Reset state to idle as a safety measure.
        guard !isVisible else { return }
        state = .idle
    }

    // MARK: - Global Escape Monitor

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.state == .loading || self.state == .listening || self.state == .drafting else { return }
                self.onEscapeDuringSession?()
            }
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    // MARK: - Panel Resize

    private func resizePanelInstant(to size: NSSize) {
        guard let panel = panel else { return }
        var frame = panel.frame
        let heightDelta = size.height - frame.size.height
        frame.size = size
        frame.origin.y -= heightDelta
        panel.setFrame(frame, display: true, animate: false)
    }

    private func resizePanel(to size: NSSize) {
        guard let panel = panel else { return }
        var frame = panel.frame
        let heightDelta = size.height - frame.size.height
        frame.size = size
        frame.origin.y -= heightDelta
        panel.setFrame(frame, display: true, animate: true)
    }
}
