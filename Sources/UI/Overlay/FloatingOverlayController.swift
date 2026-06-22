// FloatingOverlayController.swift
// State machine, animations, panel lifecycle, and global Escape monitor for the floating overlay
// Pure AppKit — no SwiftUI, no NSHostingView, no AttributeGraph

import AppKit
import Combine

@MainActor
class FloatingOverlayController {
    struct LoadingPresentation {
        let title: String
        let detail: String
        let progress: Double
        let status: String?

        static let initial = LoadingPresentation(
            title: "Loading voice model",
            detail: "Recording starts automatically when it's ready.",
            progress: 0.08,
            status: "Starting up"
        )
    }

    enum SessionMode {
        case dictation
    }

    enum OverlayState {
        case idle
        case starting     // Microphone start requested — cancellable before recording flips on
        case loading      // Voice model still loading — waiting for readiness
        case listening    // Recording dictation
        case drafting     // Processing dictation
        case success      // Finished successfully — brief confirmation before dismiss
    }

    /// Human-readable shortcut hints (reads live from UserDefaults)
    var dictationShortcutHint: String {
        DictationCancelHintPolicy.shortcutHint(
            dictationShortcutsEnabled: HotkeyPreferences.dictationShortcutsEnabled(),
            pushToTalkDisplay: PhysicalDictationTriggerPreferences.displayString(
                for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
            ),
            handsFreeDisplay: PhysicalDictationTriggerPreferences.displayString(
                for: PhysicalDictationTriggerPreferences.handsFreeBinding()
            )
        )
    }

    // MARK: - State (plain vars with didSet — no @Published, no ObservableObject)

    var state: OverlayState = .idle {
        didSet {
            guard state != oldValue else { return }
            if state != .loading {
                cancelMiniLoadingReveal()
            }
            pushStateToViews()
            updateCursorFollowTracking()
        }
    }
    var isVisible = false
    var errorMessage: String = ""
    private var errorActionTitle: String?
    private var errorActionHandler: (() -> Void)?
    var loadingElapsedSeconds: Int = 0 {
        didSet { pushStateToViews() }
    }
    var loadingPresentation: LoadingPresentation = .initial {
        didSet { pushStateToViews() }
    }
    /// Closure for Escape during active dictation overlay states.
    var onEscapeDuringSession: (() -> Void)?
    var onStopListening: (() -> Void)?

    // MARK: - Panel & Views

    private var panel: FloatingOverlayPanel?
    private var rootView: OverlayRootView?
    private var blurView: NSVisualEffectView?
    private var dragHandleView: PanelDragView?
    private var escapeMonitor: Any?
    private var cursorFollowTask: Task<Void, Never>?

    private static let cursorFollowIntervalNanoseconds: UInt64 = 33_000_000
    private static let cursorFollowOffset = NSSize(width: 22, height: 20)
    private static let cursorFollowScreenInset: CGFloat = 10
    private static let cursorFollowSmoothing: CGFloat = 0.32
    private static let miniLoadingRevealDelayNanoseconds: UInt64 = 700_000_000

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
        miniLoadingRevealTask?.cancel()
        successDismissTask?.cancel()
        cursorFollowTask?.cancel()
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

        // Glassmorphism: NSVisualEffectView behind content. Under Reduce
        // Transparency we drop the live blur and fall back to a solid backdrop.
        let reduceTransparency = AccessibilityDisplayPolicy.reduceTransparency
        let blurView = NSVisualEffectView()
        blurView.appearance = NSAppearance(named: .darkAqua)
        blurView.material = .underWindowBackground
        blurView.blendingMode = .behindWindow
        blurView.state = reduceTransparency ? .inactive : .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = OverlayTokens.cornerRadius
        blurView.layer?.backgroundColor = AccessibilityDisplayPolicy.backdropColor(OverlayTokens.panelBg).cgColor
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
        updatePanelCornerRadius()

        // Combine subscriptions: push live engine data to views
        sttRouter.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                guard let self else { return }
                let presentation = DictationMeterPolicy.presentation(
                    isListening: self.state == .listening,
                    sttIsRecording: sttRouter.isRecording,
                    rawLevel: level
                )
                self.rootView?.headerView.updateWaveformLevel(presentation.level)
            }
            .store(in: &subscriptions)

        sttRouter.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.pushStateToViews()
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
            dictationShortcutHint: dictationShortcutHint,
            errorMessage: errorMessage,
            errorActionTitle: errorActionTitle,
            onErrorAction: errorActionHandler,
            loadingPresentation: loadingPresentation,
            loadingElapsedSeconds: loadingElapsedSeconds,
            isTranscribing: sttRouter?.isTranscribing ?? false,
            isRecording: sttRouter?.isRecording ?? false,
            isMiniCursorMode: isCursorMiniPanelMode,
            audioLevel: sttRouter?.audioLevel ?? 0,
            liveTranscript: sttRouter?.liveTranscript ?? ""
        )
        updatePanelMouseBehavior()
        updatePanelCornerRadius()
    }

    // MARK: - Panel Show/Hide

    func showPanel(near sourceApp: NSRunningApplication?, anchorRect: NSRect? = nil) {
        guard let panel = panel else { return }

        // Invalidate any pending async _performHide() from a previous session's animation
        hideGeneration &+= 1

        // Cancel stale timers from a previous session
        errorDismissTask?.cancel()
        errorDismissTask = nil
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
        errorMessage = ""

        let shouldOpenAtCursor = isCursorMiniPanelMode
        let rawTargetRect = shouldOpenAtCursor
            ? nil
            : sourceApp.flatMap { AccessibilityBridge.focusedTextFieldRect(for: $0) }
        let anchorTargetRect: NSRect?
        if let anchorRect, anchorRect.width > 0, anchorRect.height > 0 {
            anchorTargetRect = anchorRect
        } else {
            anchorTargetRect = nil
        }
        let panelSize = preferredPanelSize(for: state)

        // Validate the accessibility rect — terminal emulators report oversized text areas
        let mousePos = NSEvent.mouseLocation
        let referencePoint = anchorTargetRect.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mousePos
        let currentScreen = NSScreen.screens.first { NSMouseInRect(referencePoint, $0.frame, false) }
            ?? NSScreen.screens.first { NSMouseInRect(mousePos, $0.frame, false) }
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
        if shouldOpenAtCursor {
            origin = cursorFollowOrigin(for: mousePos, panelSize: panelSize)
        } else if let rect = anchorTargetRect {
            origin = NSPoint(
                x: rect.midX - panelSize.width / 2,
                y: rect.midY - panelSize.height / 2
            )
        } else if let rect = targetRect, let screen = currentScreen {
            let flippedY = screen.frame.maxY - rect.origin.y
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
                if anchorTargetRect != nil {
                    origin.y = visibleFrame.maxY - panelSize.height - 10
                } else {
                    origin.y = targetRect != nil
                        ? origin.y - panelSize.height - 24
                        : mousePos.y - panelSize.height - 10
                }
            }
            origin.y = max(
                visibleFrame.minY + 10,
                min(origin.y, visibleFrame.maxY - panelSize.height - 10)
            )
        }

        panel.setFrameOrigin(origin)
        panel.setContentSize(panelSize)
        panel.ignoresMouseEvents = isCursorMiniPanelMode
        updatePanelCornerRadius()

        // Spring entrance
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        if !isCursorMiniPanelMode, let contentLayer = panel.contentView?.layer {
            // Skip the entrance spring entirely under Reduce Motion.
            if !AccessibilityDisplayPolicy.reduceMotion {
                let spring = CASpringAnimation(keyPath: "transform.scale")
                spring.fromValue = 0.88
                spring.toValue = 1.0
                spring.damping = 18
                spring.stiffness = 280
                spring.initialVelocity = 3
                spring.duration = spring.settlingDuration
                contentLayer.add(spring, forKey: "entranceScale")
            }
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        })

        isVisible = true
        pushStateToViews()
        updateCursorFollowTracking()
        installEscapeMonitor()
    }

    func resizePanelToCompact() {
        resizePanelInstant(to: preferredPanelSize(for: state))
        if isCursorMiniTrackingMode {
            updateCursorFollowPosition(snap: true)
        }
    }

    func showStartingState(near sourceApp: NSRunningApplication?, anchorRect: NSRect? = nil) {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
        cancelMiniLoadingReveal()
        errorMessage = ""
        errorActionTitle = nil
        errorActionHandler = nil
        state = .starting
        resizePanelToCompact()
        if !isVisible {
            showPanel(near: sourceApp, anchorRect: anchorRect)
        }
    }

    @discardableResult
    func showMiniCursorStartingStateIfNeeded(
        near sourceApp: NSRunningApplication?,
        anchorRect: NSRect? = nil
    ) -> Bool {
        guard isCursorMiniPresentationMode else { return false }
        showStartingState(near: sourceApp, anchorRect: anchorRect)
        return true
    }

    // MARK: - Hide Animations

    func hideWithConfirmAnimation(completion: (() -> Void)? = nil) {
        guard let panel = panel else { completion?(); _performHide(); return }
        let gen = hideGeneration
        panel.ignoresMouseEvents = true

        // Make sure the overlay cannot intercept the follow-up paste.
        panel.resignKey()
        panel.orderOut(nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            completion?()
            Task { @MainActor [weak self] in
                guard let self = self, self.hideGeneration == gen else { return }
                self._performHide()
            }
        })

        if !AccessibilityDisplayPolicy.reduceMotion, let contentLayer = panel.contentView?.layer {
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.0
            shrink.toValue = 0.96
            shrink.duration = 0.22
            shrink.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
    private var miniLoadingRevealTask: Task<Void, Never>?
    private var successDismissTask: Task<Void, Never>?

    func showLoadingState(
        near sourceApp: NSRunningApplication? = nil,
        presentation: LoadingPresentation? = nil,
        anchorRect: NSRect? = nil
    ) {
        errorDismissTask?.cancel()
        errorMessage = ""
        errorActionTitle = nil
        errorActionHandler = nil
        if let presentation {
            loadingPresentation = presentation
        }
        if isCursorMiniPresentationMode, state == .starting || state == .listening {
            scheduleMiniLoadingReveal()
            return
        }
        let enteringLoading = state != .loading
        if enteringLoading {
            loadingElapsedSeconds = 0
        }
        state = .loading
        if !isVisible {
            showPanel(near: sourceApp, anchorRect: anchorRect)
        }
        let loadingSize = NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelLoadingHeight)
        if enteringLoading {
            resizePanel(to: loadingSize)
        } else {
            resizePanelInstant(to: loadingSize)
        }
        if enteringLoading || loadingTimerTask == nil {
            loadingTimerTask?.cancel()
            loadingTimerTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self = self, !Task.isCancelled, self.state == .loading else { break }
                    self.loadingElapsedSeconds += 1
                }
            }
        }
    }

    private func scheduleMiniLoadingReveal() {
        guard miniLoadingRevealTask == nil else { return }
        miniLoadingRevealTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.miniLoadingRevealDelayNanoseconds)
            } catch { return }
            guard let self,
                  !Task.isCancelled,
                  self.isVisible,
                  self.isCursorMiniTrackingMode else { return }
            self.miniLoadingRevealTask = nil
            self.state = .loading
            self.loadingElapsedSeconds = 0
            self.stopCursorFollowTracking()
            let loadingSize = NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelLoadingHeight)
            self.resizePanel(to: loadingSize, keepingVisible: true)
            self.pushStateToViews()
            self.startLoadingTimerIfNeeded()
        }
    }

    private func cancelMiniLoadingReveal() {
        miniLoadingRevealTask?.cancel()
        miniLoadingRevealTask = nil
    }

    private func startLoadingTimerIfNeeded() {
        guard loadingTimerTask == nil else { return }
        loadingTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.state == .loading else { break }
                self.loadingElapsedSeconds += 1
            }
        }
    }

    func showError(
        _ message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        errorDismissTask?.cancel()
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
        errorMessage = message
        errorActionTitle = actionTitle
        errorActionHandler = action
        state = .drafting
        resizePanel(to: errorPanelSize())
        if !isVisible {
            showPanel(near: nil)
        }
        pushStateToViews()  // Force update for error message
        guard actionTitle == nil else { return }
        errorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: TranscriptedConstants.errorDismissDelay)
            } catch { return }
            guard let self = self, !self.errorMessage.isEmpty else { return }
            self.errorMessage = ""
            self.errorActionTitle = nil
            self.errorActionHandler = nil
            self.hideWithCancelAnimation()
        }
    }

    /// Fast dismiss for empty dictation audio — brief flash then clean fade (no shake).
    func showNoSpeechAndDismiss(trigger: String = "unknown") {
        errorDismissTask?.cancel()
        errorMessage = DictationNoSpeechPresentationPolicy.message(trigger: trigger)
        errorActionTitle = nil
        errorActionHandler = nil
        state = .drafting
        resizePanel(to: NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelMinHeight))
        if !isVisible {
            showPanel(near: nil)
        }
        pushStateToViews()
        errorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: TranscriptedConstants.noSpeechDismissDelay)
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
        errorActionTitle = nil
        errorActionHandler = nil
        state = .success
        resizePanelToCompact()
        if !isVisible {
            showPanel(near: nil)
        }
        pushStateToViews()
        successDismissTask = Task { @MainActor [weak self] in
            do {
                // Let the "Pasted" confirmation stay readable before it eases out
                // instead of flashing past in under half a second.
                try await Task.sleep(nanoseconds: 800_000_000)
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
        panel?.orderOut(nil)
        panel?.alphaValue = 1.0
        panel?.contentView?.layer?.removeAllAnimations()

        isVisible = false
        stopCursorFollowTracking()
        errorDismissTask?.cancel()
        errorDismissTask = nil
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
        cancelMiniLoadingReveal()
        successDismissTask?.cancel()
        successDismissTask = nil
        state = .idle
        errorMessage = ""
        errorActionTitle = nil
        errorActionHandler = nil
        loadingPresentation = .initial
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
                guard self.state == .starting || self.state == .loading || self.state == .listening || self.state == .drafting else { return }
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

    private func resizePanelInstant(to size: NSSize, keepingVisible: Bool = false) {
        guard let panel = panel else { return }
        var frame = panel.frame
        let widthDelta = size.width - frame.size.width
        let heightDelta = size.height - frame.size.height
        frame.size = size
        frame.origin.x -= widthDelta / 2
        frame.origin.y -= heightDelta
        if keepingVisible {
            frame = clampedVisiblePanelFrame(frame)
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    private func resizePanel(to size: NSSize, keepingVisible: Bool = false) {
        guard let panel = panel else { return }
        var frame = panel.frame
        let widthDelta = size.width - frame.size.width
        let heightDelta = size.height - frame.size.height
        frame.size = size
        frame.origin.x -= widthDelta / 2
        frame.origin.y -= heightDelta
        if keepingVisible {
            frame = clampedVisiblePanelFrame(frame)
        }
        panel.setFrame(frame, display: true, animate: true)
    }

    private func clampedVisiblePanelFrame(_ frame: NSRect) -> NSRect {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            ?? NSScreen.screens.first { frame.intersects($0.frame) }
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return frame }

        let inset = Self.cursorFollowScreenInset
        var clamped = frame
        let minX = visibleFrame.minX + inset
        let maxX = visibleFrame.maxX - frame.width - inset
        let minY = visibleFrame.minY + inset
        let maxY = visibleFrame.maxY - frame.height - inset

        clamped.origin.x = maxX < minX ? minX : max(minX, min(clamped.origin.x, maxX))
        clamped.origin.y = maxY < minY ? minY : max(minY, min(clamped.origin.y, maxY))
        return clamped
    }

    private func preferredPanelSize(for state: OverlayState) -> NSSize {
        switch state {
        case .loading:
            return NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelLoadingHeight)
        case .drafting where !errorMessage.isEmpty:
            return errorPanelSize()
        case .starting where isCursorMiniPresentationMode:
            return NSSize(width: OverlayTokens.panelCursorMiniWidth, height: OverlayTokens.panelCursorMiniHeight)
        case .listening where isCursorMiniPresentationMode:
            return NSSize(width: OverlayTokens.panelCursorMiniWidth, height: OverlayTokens.panelCursorMiniHeight)
        case .drafting where errorMessage.isEmpty && isCursorMiniPresentationMode:
            return NSSize(width: OverlayTokens.panelCursorMiniWidth, height: OverlayTokens.panelCursorMiniHeight)
        case .success where isCursorMiniPresentationMode:
            return NSSize(width: OverlayTokens.panelCursorMiniWidth, height: OverlayTokens.panelCursorMiniHeight)
        case .idle, .starting, .listening, .drafting, .success:
            return NSSize(width: OverlayTokens.panelCompactWidth, height: OverlayTokens.panelCompactHeight)
        }
    }

    private func errorPanelSize() -> NSSize {
        let height = errorActionTitle == nil
            ? OverlayTokens.panelMinHeight
            : OverlayTokens.panelActionErrorHeight
        return NSSize(width: OverlayTokens.panelWidth, height: height)
    }

    // MARK: - Cursor Following

    private var isCursorMiniPresentationMode: Bool {
        DictationOverlayPresentationPreferences.mode() == .cursorMini
    }

    private var isCursorMiniPanelMode: Bool {
        guard isCursorMiniPresentationMode else { return false }
        switch state {
        case .starting, .listening, .success:
            return true
        case .drafting:
            return errorMessage.isEmpty
        case .idle, .loading:
            return false
        }
    }

    private var isCursorMiniListeningMode: Bool {
        state == .listening && isCursorMiniPresentationMode
    }

    private var isCursorMiniTrackingMode: Bool {
        (state == .starting || state == .listening) && isCursorMiniPresentationMode
    }

    private func updateCursorFollowTracking() {
        updatePanelMouseBehavior()
        guard isVisible, isCursorMiniTrackingMode else {
            stopCursorFollowTracking()
            return
        }
        startCursorFollowTracking()
    }

    private func startCursorFollowTracking() {
        guard cursorFollowTask == nil else { return }
        updateCursorFollowPosition(snap: true)
        cursorFollowTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isVisible, self.isCursorMiniTrackingMode else { break }
                self.updateCursorFollowPosition(snap: false)
                try? await Task.sleep(nanoseconds: Self.cursorFollowIntervalNanoseconds)
            }
        }
    }

    private func stopCursorFollowTracking() {
        cursorFollowTask?.cancel()
        cursorFollowTask = nil
    }

    private func updateCursorFollowPosition(snap: Bool) {
        guard let panel, isVisible, isCursorMiniTrackingMode else { return }

        let target = cursorFollowOrigin(
            for: NSEvent.mouseLocation,
            panelSize: panel.frame.size
        )
        var frame = panel.frame
        if snap || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            frame.origin = target
        } else {
            frame.origin.x += (target.x - frame.origin.x) * Self.cursorFollowSmoothing
            frame.origin.y += (target.y - frame.origin.y) * Self.cursorFollowSmoothing
        }
        panel.setFrameOrigin(frame.origin)
    }

    private func updatePanelCornerRadius() {
        let radius = isCursorMiniPanelMode
            ? OverlayTokens.panelCursorMiniCornerRadius
            : OverlayTokens.cornerRadius
        blurView?.layer?.cornerRadius = radius
        panel?.contentView?.layer?.cornerRadius = radius
    }

    private func updatePanelMouseBehavior() {
        guard isVisible else { return }
        panel?.ignoresMouseEvents = isCursorMiniPanelMode
    }

    private func cursorFollowOrigin(for mouseLocation: NSPoint, panelSize: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return NSPoint(
                x: mouseLocation.x + Self.cursorFollowOffset.width,
                y: mouseLocation.y + Self.cursorFollowOffset.height
            )
        }

        let inset = Self.cursorFollowScreenInset
        var x = mouseLocation.x + Self.cursorFollowOffset.width
        if x + panelSize.width > visibleFrame.maxX - inset {
            x = mouseLocation.x - panelSize.width - Self.cursorFollowOffset.width
        }

        var y = mouseLocation.y + Self.cursorFollowOffset.height
        if y + panelSize.height > visibleFrame.maxY - inset {
            y = mouseLocation.y - panelSize.height - Self.cursorFollowOffset.height
        }

        return NSPoint(
            x: max(visibleFrame.minX + inset, min(x, visibleFrame.maxX - panelSize.width - inset)),
            y: max(visibleFrame.minY + inset, min(y, visibleFrame.maxY - panelSize.height - inset))
        )
    }
}
