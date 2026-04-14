// FloatingOverlayController.swift
// State machine, animations, panel lifecycle, and global Escape monitor for the floating overlay.
// The shell stays AppKit; an optional SwiftUI listening pill can be enabled for experiments.

import AppKit
import Combine
import SwiftUI

private enum OverlayExperiments {
    static var experimentalListeningOverlayEnabled: Bool {
        if let rawValue = ProcessInfo.processInfo.environment["TRANSCRIPTED_EXPERIMENTAL_GLASS_OVERLAY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
            return ["1", "true", "yes", "on"].contains(rawValue)
        }

        return UserDefaults.standard.bool(forKey: "ExperimentalGlassOverlay")
    }
}

@MainActor
class FloatingOverlayController {
    struct LoadingPresentation {
        let title: String
        let detail: String
        let progress: Double
        let status: String

        static let initial = LoadingPresentation(
            title: "Loading dictation",
            detail: "Transcripted is getting the local voice model ready.",
            progress: 0.08,
            status: "Starting up"
        )
    }

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
    var isVisible = false
    var reviewText: String = ""
    var streamingText: String = ""
    var errorMessage: String = ""
    private var errorActionTitle: String?
    private var errorActionHandler: (() -> Void)?
    var loadingElapsedSeconds: Int = 0 {
        didSet { pushStateToViews() }
    }
    var loadingPresentation: LoadingPresentation = .initial {
        didSet { pushStateToViews() }
    }
    /// Closure for Escape during non-review states (listening/drafting/streaming)
    var onEscapeDuringSession: (() -> Void)?
    var onStopListening: (() -> Void)?

    // MARK: - Panel & Views

    private var panel: FloatingOverlayPanel?
    private var rootView: OverlayRootView?
    private var overlayContentView: NSView?
    private var glassContainerView: NSGlassEffectContainerView?
    private var glassSurfaceView: NSGlassEffectView?
    private var dragHandleView: PanelDragView?
    private let usesExperimentalListeningOverlay = OverlayExperiments.experimentalListeningOverlayEnabled
    private var experimentalListeningModel: ExperimentalListeningOverlayModel?
    private var experimentalListeningHostingView: TransparentHostingView<ExperimentalListeningOverlayView>?
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

        let glassContainerView = NSGlassEffectContainerView(frame: panel.contentView?.bounds ?? .zero)
        glassContainerView.autoresizingMask = [.width, .height]
        glassContainerView.spacing = OverlayTokens.glassGroupingSpacing

        let glassStageView = NSView(frame: glassContainerView.bounds)
        glassStageView.autoresizingMask = [.width, .height]
        glassContainerView.contentView = glassStageView
        panel.contentView?.addSubview(glassContainerView)
        self.glassContainerView = glassContainerView

        let glassSurfaceView = NSGlassEffectView(frame: glassStageView.bounds)
        glassSurfaceView.autoresizingMask = [.width, .height]
        glassSurfaceView.cornerRadius = OverlayTokens.compactCornerRadius
        glassSurfaceView.style = .regular
        glassSurfaceView.tintColor = OverlayTokens.compactGlassTint
        glassStageView.addSubview(glassSurfaceView)
        self.glassSurfaceView = glassSurfaceView

        let overlayContentView = NSView(frame: glassSurfaceView.bounds)
        overlayContentView.autoresizingMask = [.width, .height]
        glassSurfaceView.contentView = overlayContentView
        self.overlayContentView = overlayContentView

        // The AppKit root view remains the default renderer and fallback path.
        let rootView = OverlayRootView(frame: overlayContentView.bounds)
        rootView.autoresizingMask = [.width, .height]
        rootView.headerView.onStopRequested = { [weak self] in
            self?.onStopListening?()
        }
        overlayContentView.addSubview(rootView)
        self.rootView = rootView

        if usesExperimentalListeningOverlay {
            let listeningModel = ExperimentalListeningOverlayModel()
            listeningModel.onStopRequested = { [weak self] in
                self?.onStopListening?()
            }

            let hostingView = TransparentHostingView(
                rootView: ExperimentalListeningOverlayView(model: listeningModel)
            )
            hostingView.frame = overlayContentView.bounds
            hostingView.autoresizingMask = [.width, .height]
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            hostingView.isHidden = true
            overlayContentView.addSubview(hostingView)

            self.experimentalListeningModel = listeningModel
            self.experimentalListeningHostingView = hostingView
        }

        // Drag handle at the top — pure AppKit, above the root view
        let headerHeight: CGFloat = OverlayTokens.headerHeight
        let contentBounds = glassStageView.bounds
        let dragView = PanelDragView()
        dragView.panel = panel
        dragView.frame = NSRect(
            x: 0,
            y: contentBounds.height - headerHeight,
            width: contentBounds.width,
            height: headerHeight
        )
        dragView.autoresizingMask = [.width, .minYMargin]
        glassStageView.addSubview(dragView, positioned: .above, relativeTo: glassSurfaceView)
        self.dragHandleView = dragView

        // The panel itself stays clear; the visible glass comes from the AppKit
        // glass effect views so the overlay feels like a native floating control.
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 0
        panel.contentView?.layer?.masksToBounds = false
        panel.contentView?.layer?.borderWidth = 0

        self.panel = panel
        updatePanelAppearance()

        // Combine subscriptions: push live engine data to views
        sttRouter.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.rootView?.headerView.updateWaveformLevel(level)
                self?.experimentalListeningModel?.audioLevel = CGFloat(max(0, min(1, level)))
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
            liveTranscript: sttRouter?.liveTranscript ?? ""
        )
        syncExperimentalOverlayVisibility()
        updatePanelAppearance()
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
        let panelSize = preferredPanelSize(for: state)

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

        if let contentLayer = glassSurfaceView?.layer ?? panel.contentView?.layer {
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
        resizePanel(to: preferredPanelSize(for: state))
    }

    func resizePanelToCompact() {
        resizePanelInstant(to: NSSize(width: OverlayTokens.panelCompactWidth, height: OverlayTokens.panelCompactHeight))
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

        if let contentLayer = glassSurfaceView?.layer ?? panel.contentView?.layer {
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

    func showLoadingState(near sourceApp: NSRunningApplication? = nil, presentation: LoadingPresentation? = nil) {
        errorDismissTask?.cancel()
        errorMessage = ""
        errorActionTitle = nil
        errorActionHandler = nil
        if let presentation {
            loadingPresentation = presentation
        }
        let enteringLoading = state != .loading
        if enteringLoading {
            loadingElapsedSeconds = 0
        }
        state = .loading
        if !isVisible {
            showPanel(near: sourceApp)
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

    /// Fast dismiss for "no speech detected" — brief flash then clean fade (no shake).
    func showNoSpeechAndDismiss() {
        errorDismissTask?.cancel()
        errorMessage = "No speech detected"
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
        glassSurfaceView?.layer?.removeAllAnimations()
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
        errorActionTitle = nil
        errorActionHandler = nil
        loadingPresentation = .initial
    }

    // MARK: - System Wake Recovery & Periodic AG Refresh

    func handleSystemWake() {
        // The panel shell still lives in AppKit. The experimental SwiftUI pill is only
        // used while listening, so resetting to idle on wake drops back to the safe path.
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
        let widthDelta = size.width - frame.size.width
        let heightDelta = size.height - frame.size.height
        frame.size = size
        frame.origin.x -= widthDelta / 2
        frame.origin.y -= heightDelta
        panel.setFrame(frame, display: true, animate: false)
    }

    private func resizePanel(to size: NSSize) {
        guard let panel = panel else { return }
        var frame = panel.frame
        let widthDelta = size.width - frame.size.width
        let heightDelta = size.height - frame.size.height
        frame.size = size
        frame.origin.x -= widthDelta / 2
        frame.origin.y -= heightDelta
        panel.setFrame(frame, display: true, animate: true)
    }

    private func preferredPanelSize(for state: OverlayState) -> NSSize {
        switch state {
        case .loading:
            return NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelLoadingHeight)
        case .drafting where !errorMessage.isEmpty:
            return errorPanelSize()
        case .drafting:
            return NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelMinHeight)
        case .idle, .listening, .success:
            return NSSize(width: OverlayTokens.panelCompactWidth, height: OverlayTokens.panelCompactHeight)
        default:
            return NSSize(width: OverlayTokens.panelWidth, height: OverlayTokens.panelMinHeight)
        }
    }

    private func errorPanelSize() -> NSSize {
        let height = errorActionTitle == nil
            ? OverlayTokens.panelMinHeight
            : OverlayTokens.panelActionErrorHeight
        return NSSize(width: OverlayTokens.panelWidth, height: height)
    }

    private func syncExperimentalOverlayVisibility() {
        let shouldShowExperimentalListeningOverlay = usesExperimentalListeningOverlay && state == .listening
        rootView?.isHidden = shouldShowExperimentalListeningOverlay
        experimentalListeningHostingView?.isHidden = !shouldShowExperimentalListeningOverlay

        if shouldShowExperimentalListeningOverlay {
            experimentalListeningModel?.audioLevel = CGFloat(max(0, min(1, sttRouter?.audioLevel ?? 0)))
        }
    }

    private func updatePanelAppearance() {
        guard let glassSurfaceView else { return }

        if usesExperimentalListeningOverlay && state == .listening {
            glassSurfaceView.cornerRadius = OverlayTokens.compactCornerRadius
            glassSurfaceView.style = .clear
            glassSurfaceView.tintColor = .clear
            return
        }

        let usesExpandedChrome = state == .loading || state == .drafting
        let cornerRadius = usesExpandedChrome
            ? OverlayTokens.expandedCornerRadius
            : OverlayTokens.compactCornerRadius

        glassSurfaceView.cornerRadius = cornerRadius
        glassSurfaceView.style = usesExpandedChrome ? .clear : .regular

        switch state {
        case .listening:
            glassSurfaceView.tintColor = OverlayTokens.listeningGlassTint
        case .success:
            glassSurfaceView.tintColor = OverlayTokens.successGlassTint
        case .loading, .drafting:
            glassSurfaceView.tintColor = OverlayTokens.expandedGlassTint
        default:
            glassSurfaceView.tintColor = OverlayTokens.compactGlassTint
        }
    }
}
