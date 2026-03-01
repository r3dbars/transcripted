// FloatingOverlayController.swift
// State machine, animations, panel lifecycle, and global Escape monitor for the floating overlay

import SwiftUI
import AppKit

@MainActor
class FloatingOverlayController: ObservableObject {
    enum SessionMode {
        case draft      // Option+D: screenshot + voice + AI rewrite + review
        case dictation  // Option+Space: voice + light polish + auto-paste
    }

    enum OverlayState {
        case idle
        case loading      // Voice model still loading — waiting for readiness
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
    @Published var errorMessage: String = ""
    @Published var loadingElapsedSeconds: Int = 0

    /// Closures for Enter/Escape in review mode — set by DraftSessionController
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Closure for Escape during non-review states (listening/drafting/streaming) — set by DraftSessionController
    var onEscapeDuringSession: (() -> Void)?

    private var panel: FloatingOverlayPanel?
    private var hostingView: NSHostingView<AnyView>?

    private var dragHandleView: PanelDragView?
    private var escapeMonitor: Any?

    var sttRouter: STTRouter?

    func setup(sttRouter: STTRouter) {
        guard panel == nil else {
            print("⚠️ OVERLAY | setup() called twice — ignoring")
            return
        }
        self.sttRouter = sttRouter
        let panel = FloatingOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: OverlayTokens.panelWidth, height: OverlayTokens.panelMinHeight),
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
        blurView.layer?.cornerRadius = OverlayTokens.cornerRadius
        blurView.frame = panel.contentView?.bounds ?? .zero
        blurView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(blurView)

        let content = OverlayContentView(sttRouter: sttRouter, controller: self)
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
            x: 0,
            y: contentBounds.height - headerHeight,
            width: contentBounds.width,
            height: headerHeight
        )
        dragView.autoresizingMask = [.width, .minYMargin]  // Stay at top, stretch width
        panel.contentView?.addSubview(dragView, positioned: .above, relativeTo: hosting)
        self.dragHandleView = dragView

        // Round corners on the panel's content view
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = OverlayTokens.cornerRadius
        panel.contentView?.layer?.masksToBounds = true

        self.panel = panel
        self.hostingView = hosting
    }

    /// Unified show method — positions the panel near the user's cursor/text field
    func showPanel(near sourceApp: NSRunningApplication?) {
        guard let panel = panel else { return }

        let rawTargetRect = sourceApp.flatMap { AccessibilityBridge.focusedTextFieldRect(for: $0) }
        let panelSize = NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelMinHeight)

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
        panel.ignoresMouseEvents = false  // Re-enable after hide animations

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
        installEscapeMonitor()
    }

    func showReview(text: String) {
        reviewText = text
        state = .review

        // Resize: grow upward from bottom edge to fit text
        let lineCount = max(1, text.components(separatedBy: "\n").count)
        let charEstimate = CGFloat(text.count) / 50.0  // ~50 chars per line at 480pt width
        let lines = max(CGFloat(lineCount), charEstimate)
        let estimatedHeight = max(OverlayTokens.panelMinHeight, min(OverlayTokens.panelMaxHeight, lines * 20 + 120))
        resizePanel(to: NSSize(width: OverlayTokens.panelWidth, height: estimatedHeight))

        // Make key-capable so TextEditor receives input
        if let panel = panel {
            panel.allowKeyStatus = true
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func startStreaming(near sourceApp: NSRunningApplication? = nil) {
        guard state == .drafting || state == .listening else { return }
        streamingText = ""
        state = .streaming
        // Show panel if not visible
        if !isVisible {
            showPanel(near: sourceApp)
        }
        // Resize to initial streaming size
        resizePanel(to: NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelMinHeight))
        // Not key-capable yet (still receiving tokens)
        panel?.allowKeyStatus = false
    }

    func appendStreamToken(_ token: String) {
        guard state == .streaming else { return }
        streamingText += token
        // Dynamically resize as text grows
        let lineCount = max(1, streamingText.components(separatedBy: "\n").count)
        let charEstimate = CGFloat(streamingText.count) / 50.0
        let lines = max(CGFloat(lineCount), charEstimate)
        let estimatedHeight = max(OverlayTokens.panelMinHeight, min(OverlayTokens.panelMaxHeight, lines * 20 + 120))
        if let panel = panel, abs(panel.frame.height - estimatedHeight) > 20 {
            resizePanel(to: NSSize(width: OverlayTokens.panelWidth, height: estimatedHeight))
        }
    }

    func finishStreaming() {
        guard state == .streaming else { return }
        // Transfer to editable review
        showReview(text: streamingText)
        streamingText = ""
    }

    /// Confirm animation: scale down + fade (content "sends" toward target app)
    func hideWithConfirmAnimation(completion: (() -> Void)? = nil) {
        guard let panel = panel else { completion?(); _performHide(); return }
        panel.ignoresMouseEvents = true  // Prevent gesture dispatch during teardown

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
    func hideWithCancelAnimation() {
        guard let panel = panel else { _performHide(); return }
        panel.ignoresMouseEvents = true  // Prevent gesture dispatch during teardown

        // Horizontal shake using the window frame (not layer — layers don't move windows)
        let baseX = panel.frame.origin.x
        let offsets: [CGFloat] = [7, -5, 3, -1, 0]
        let stepDuration = 0.068  // ~340ms total for 5 steps

        for (i, offset) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration * Double(i)) { [weak panel] in
                guard let panel = panel else { return }
                var frame = panel.frame
                frame.origin.x = baseX + offset
                panel.setFrame(frame, display: false)
            }
        }

        // Fade out after shake completes
        DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration * Double(offsets.count)) { [weak self, weak panel] in
            guard let panel = panel else { self?._performHide(); return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                self?._performHide()
            })
        }
    }

    private var errorDismissTask: Task<Void, Never>?

    private var loadingTimerTask: Task<Void, Never>?

    /// Show a persistent loading state (stays visible until state changes or session ends).
    func showLoadingState() {
        errorDismissTask?.cancel()
        errorMessage = ""
        loadingElapsedSeconds = 0
        state = .loading
        if !isVisible {
            showPanel(near: nil)
        }
        // Tick elapsed seconds so the user knows it's alive
        loadingTimerTask?.cancel()
        loadingTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self, !Task.isCancelled, self.state == .loading else { break }
                self.loadingElapsedSeconds += 1
            }
        }
    }

    /// Show a brief error message in the overlay, then auto-hide after ~1.5s (plus cancel animation).
    func showError(_ message: String) {
        errorDismissTask?.cancel()
        errorMessage = message
        state = .drafting  // Reuse drafting state for error display
        if !isVisible {
            showPanel(near: nil)
        }
        errorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: DraftConstants.errorDismissDelay)
            } catch {
                return  // Cancelled — bail
            }
            guard let self = self, !self.errorMessage.isEmpty else { return }
            self.errorMessage = ""
            self.hideWithCancelAnimation()
        }
    }

    private func _performHide() {
        guard isVisible else { return }  // Prevent double-hide during animation overlap
        removeEscapeMonitor()
        panel?.allowKeyStatus = false
        panel?.orderOut(nil)
        panel?.alphaValue = 1.0  // Reset for next show
        panel?.contentView?.layer?.removeAllAnimations()
        isVisible = false
        errorDismissTask?.cancel()
        errorDismissTask = nil
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
        state = .idle
        reviewText = ""
        streamingText = ""
        errorMessage = ""
    }

    // MARK: - Global Escape Monitor

    /// Installs a global key monitor that intercepts Escape while the overlay is visible.
    /// Needed because the panel is non-key during listening/drafting, so SwiftUI .onKeyPress won't fire.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }  // 53 = Escape
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Handle during loading/listening/drafting/streaming — review has its own SwiftUI handler
                guard self.state == .loading || self.state == .listening || self.state == .drafting || self.state == .streaming else { return }
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

    private func resizePanel(to size: NSSize) {
        guard let panel = panel else { return }
        var frame = panel.frame
        let heightDelta = size.height - frame.size.height
        frame.size = size
        frame.origin.y -= heightDelta  // Grow upward, bottom edge anchored
        panel.setFrame(frame, display: true, animate: true)
    }
}
