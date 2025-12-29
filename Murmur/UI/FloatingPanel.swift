import SwiftUI
import AppKit
import Combine

// MARK: - Pill State (Dynamic Island-style states)

/// Represents the visual states of the floating pill UI
enum PillState: Equatable {
    case idle           // 40x20px - Dormant waveform, capsule shape
    case recording      // 180x40px - Live visualizer + timer + stop
    case processing     // 180x40px - Status text + progress
    case reviewing      // 280px wide - Tray expands upward for action items
}

// MARK: - Pill State Manager

/// Manages pill state transitions with animation protection
/// Replaces EdgeDockingManager with event-driven state changes
class PillStateManager: ObservableObject {
    @Published var state: PillState = .idle
    @Published var isLocked = false  // Prevents state changes during review

    /// Flag to prevent rapid state changes during animations
    @Published private(set) var isTransitioning = false
    private let transitionCooldown: TimeInterval = 0.35

    // MARK: - Timeout Recovery (Phase 1 Bug Fix)

    /// Timestamp when current transition started (for timeout recovery)
    private var transitionStartTime: Date?

    /// Maximum time a transition can be "in progress" before force-reset
    /// 2 seconds is long enough for any animation but catches stuck states quickly
    private let transitionTimeout: TimeInterval = 2.0

    // MARK: - Computed Dimensions

    var pillWidth: CGFloat {
        switch state {
        case .idle:
            return PillDimensions.idleWidth
        case .recording, .processing:
            return PillDimensions.recordingWidth
        case .reviewing:
            return PillDimensions.trayWidth
        }
    }

    var pillHeight: CGFloat {
        switch state {
        case .idle:
            return PillDimensions.idleHeight
        case .recording, .processing:
            return PillDimensions.recordingHeight
        case .reviewing:
            return PillDimensions.recordingHeight  // Base pill stays same, tray expands above
        }
    }

    /// Total window height including tray when reviewing
    var windowHeight: CGFloat {
        switch state {
        case .idle:
            return PillDimensions.idleHeight + 20  // Small padding
        case .recording, .processing:
            return PillDimensions.recordingHeight + 20
        case .reviewing:
            return PillDimensions.recordingHeight + PillDimensions.trayMaxHeight
        }
    }

    // MARK: - State Transitions

    /// Transition to a new state with animation protection and timeout recovery
    func transition(to newState: PillState) {
        // PHASE 1 FIX: Timeout recovery - if stuck in transition for > 2s, force reset
        if isTransitioning,
           let startTime = transitionStartTime,
           Date().timeIntervalSince(startTime) > transitionTimeout {
            print("[PillState] ⚠️ Force-resetting stuck transition (was \(state) for \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s)")
            isTransitioning = false
            transitionStartTime = nil
        }

        // Don't transition if locked (e.g., during review) - UNLESS transitioning to idle (emergency escape)
        guard !isLocked || newState == .idle else {
            print("[PillState] Blocked transition to \(newState) - pill is locked")
            return
        }

        // Don't transition if already in that state
        guard state != newState else { return }

        // Don't allow transitions during cooldown (unless unlocking from review)
        guard !isTransitioning || (isLocked && newState == .idle) else {
            print("[PillState] Blocked transition to \(newState) - cooldown active")
            return
        }

        let previousState = state
        isTransitioning = true
        transitionStartTime = Date()
        state = newState
        print("[PillState] Transition: \(previousState) → \(newState)")

        // Reset transition flag after cooldown
        DispatchQueue.main.asyncAfter(deadline: .now() + transitionCooldown) { [weak self] in
            self?.isTransitioning = false
            self?.transitionStartTime = nil
        }
    }

    /// Lock the pill in current state (used during review)
    func lock() {
        isLocked = true
    }

    /// Unlock and optionally transition to idle
    func unlock(transitionToIdle: Bool = true) {
        isLocked = false
        if transitionToIdle {
            transition(to: .idle)
        }
    }

    // MARK: - Emergency Recovery (Phase 1 Bug Fix)

    /// Force unlock and reset all state flags - use only for emergency recovery
    /// This bypasses all guards and forces the pill back to idle state
    func forceUnlock() {
        print("[PillState] ⚠️ Force unlock triggered - resetting all state")
        isLocked = false
        isTransitioning = false
        transitionStartTime = nil
        state = .idle
    }
}

// MARK: - Edge Docking Manager (DEPRECATED - to be removed)

/// Monitors mouse position and triggers panel expansion when near screen edge
/// Panel stays expanded while mouse is inside the panel OR near the edge
class EdgeDockingManager: ObservableObject {
    @Published var shouldExpand = false
    @Published var isLocked = false  // Prevents mouse-triggered collapse (e.g., for meeting prompts)

    // Reference to panel window for bounds checking
    weak var panelWindow: NSWindow?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var expandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?

    // Configuration
    private let edgeThreshold: CGFloat = 20  // Pixels from edge to trigger
    private let expandDelay: TimeInterval = 0.3  // 300ms delay before expanding
    private let collapseDelay: TimeInterval = 0.15  // 150ms grace period before collapsing

    func startMonitoring() {
        // Global monitor for when app is not focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMove()
        }

        // Local monitor for when app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMove()
            return event
        }
    }

    private func handleMouseMove() {
        guard let screen = NSScreen.main else { return }
        let mouseLocation = NSEvent.mouseLocation
        let rightEdge = screen.visibleFrame.maxX

        // Check if mouse is near the screen edge
        let nearEdge = mouseLocation.x >= rightEdge - edgeThreshold

        // Check if mouse is inside the expanded panel
        let insidePanel: Bool = {
            guard shouldExpand, let window = panelWindow else { return false }
            return window.frame.contains(mouseLocation)
        }()

        if nearEdge || insidePanel {
            // Cancel any pending collapse and schedule/maintain expansion
            cancelCollapse()
            scheduleExpand()
        } else {
            // Cancel pending expansion and schedule collapse with grace period
            cancelExpand()
            scheduleCollapse()
        }
    }

    private func scheduleExpand() {
        // Don't schedule if already expanded or already scheduling
        guard !shouldExpand, expandWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.shouldExpand = true
            self?.expandWorkItem = nil
        }
        expandWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay, execute: workItem)
    }

    private func cancelExpand() {
        expandWorkItem?.cancel()
        expandWorkItem = nil
    }

    private func scheduleCollapse() {
        // Don't schedule if already collapsed, already scheduling, or locked
        guard shouldExpand, collapseWorkItem == nil, !isLocked else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isLocked else { return }  // Double-check lock
            self.shouldExpand = false
            self.collapseWorkItem = nil
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: workItem)
    }

    private func cancelCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    func stopMonitoring() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    deinit {
        stopMonitoring()
    }
}

// MARK: - Window Controller

@available(macOS 26.0, *)
class FloatingPanelController: NSWindowController {
    private var taskManager: TranscriptionTaskManager
    private var audio: Audio
    let pillStateManager = PillStateManager()
    private var cancellables = Set<AnyCancellable>()

    // DEPRECATED: Keep dockingManager temporarily for backward compatibility during transition
    private let dockingManager = EdgeDockingManager()

    // Maximum window dimensions (window stays fixed, content animates within)
    private let maxWindowWidth: CGFloat = PillDimensions.trayWidth + 40  // Extra padding for shadows
    private let maxWindowHeight: CGFloat = PillDimensions.trayMaxHeight + PillDimensions.recordingHeight + 40

    init(taskManager: TranscriptionTaskManager, audio: Audio) {
        self.taskManager = taskManager
        self.audio = audio

        let screen = NSScreen.main ?? NSScreen.screens.first!

        // Calculate position: centered above dock
        let dockHeight = Self.detectDockHeight(for: screen)
        let x = (screen.frame.width - maxWindowWidth) / 2
        let y = dockHeight + PillDimensions.dockPadding

        let initialFrame = NSRect(
            x: x,
            y: y,
            width: maxWindowWidth,
            height: maxWindowHeight
        )

        let window = FloatingPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false  // Fixed position above dock
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isOpaque = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.hidesOnDeactivate = false  // Stay visible when app loses focus

        // Create view with pill state manager (pass dockingManager for backward compat during transition)
        let view = FloatingPanelView(
            taskManager: taskManager,
            audio: audio,
            dockingManager: dockingManager,
            pillStateManager: pillStateManager
        )
        window.contentView = NSHostingView(rootView: view)

        // DEPRECATED: Keep for backward compatibility
        dockingManager.panelWindow = window
        dockingManager.startMonitoring()

        // Wire up pill state transitions based on app events
        setupStateBindings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        dockingManager.stopMonitoring()
    }

    // MARK: - Dock Height Detection

    /// Detect the height of the macOS dock
    private static func detectDockHeight(for screen: NSScreen) -> CGFloat {
        // The dock takes space from visibleFrame
        // Dock can be at bottom, left, or right
        // We detect bottom dock by comparing frame.height vs visibleFrame.height

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        // Bottom dock: difference between frame bottom and visible frame bottom
        let bottomDockHeight = visibleFrame.origin.y - screenFrame.origin.y

        // If dock is at bottom and has significant height, use it
        if bottomDockHeight > 20 {
            return bottomDockHeight
        }

        // Dock might be hidden or on sides - use default
        return PillDimensions.defaultDockHeight
    }

    // MARK: - State Bindings

    private func setupStateBindings() {
        // React to recording state changes
        // PHASE 1 FIX: Add debouncing to prevent rapid state changes from causing stuck states
        audio.$isRecording
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording {
                    self.pillStateManager.transition(to: .recording)
                } else if self.taskManager.displayStatus.isProcessing {
                    self.pillStateManager.transition(to: .processing)
                } else if !self.pillStateManager.isLocked {
                    self.pillStateManager.transition(to: .idle)
                }
            }
            .store(in: &cancellables)

        // React to task manager status changes
        taskManager.$displayStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                switch status {
                case .preparing, .transcribing, .extractingActionItems, .saving:
                    if !self.audio.isRecording {
                        self.pillStateManager.transition(to: .processing)
                    }
                case .pendingReview:
                    // IMPORTANT: Transition BEFORE locking - lock() would block the transition
                    self.pillStateManager.transition(to: .reviewing)
                    self.pillStateManager.lock()
                case .completed, .transcriptSaved, .idle:
                    self.pillStateManager.unlock(transitionToIdle: !self.audio.isRecording)
                case .failed:
                    // Stay in current state for errors
                    break
                }
            }
            .store(in: &cancellables)

        // DEPRECATED: Bridge pill state to docking manager for backward compatibility
        pillStateManager.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                // Expand panel when not idle (for transition period)
                self.dockingManager.shouldExpand = state != .idle
                self.dockingManager.isLocked = self.pillStateManager.isLocked
            }
            .store(in: &cancellables)
    }

    /// Reposition window if screen changes
    func repositionIfNeeded() {
        guard let window = self.window, let screen = NSScreen.main else { return }

        let dockHeight = Self.detectDockHeight(for: screen)
        let x = (screen.frame.width - maxWindowWidth) / 2
        let y = dockHeight + PillDimensions.dockPadding

        var frame = window.frame
        frame.origin.x = x
        frame.origin.y = y
        window.setFrame(frame, display: true)
    }
}

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}







// MARK: - Attention Prompt View

/// Expandable prompt for notifications like "Start Recording?" or "Still Recording?"
/// Features animated green ring, shake animation, and auto-dismiss
struct AttentionPromptView: View {
    let promptType: AttentionPromptType
    let onPrimaryAction: () -> Void
    let onDismiss: () -> Void

    @State private var isVisible = false
    @State private var dismissProgress: CGFloat = 1.0

    private let autoDismissSeconds: Double = 10.0

    enum AttentionPromptType {
        case startRecording(appName: String)  // "Zoom opened - Record?"
        case stillRecording(duration: TimeInterval, silenceMinutes: Int)  // "Still recording? 2 min silence"

        var icon: String {
            switch self {
            case .startRecording: return "mic.fill"
            case .stillRecording: return "waveform.badge.exclamationmark"
            }
        }

        var title: String {
            switch self {
            case .startRecording(let appName): return "\(appName) Active"
            case .stillRecording: return "Still Recording?"
            }
        }

        var subtitle: String {
            switch self {
            case .startRecording: return "Start recording?"
            case .stillRecording(_, let minutes): return "\(minutes)m silence detected"
            }
        }

        var primaryButtonText: String {
            switch self {
            case .startRecording: return "Record"
            case .stillRecording: return "Stop"
            }
        }

        var secondaryButtonText: String {
            switch self {
            case .startRecording: return "Dismiss"
            case .stillRecording: return "Keep"
            }
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.premiumCoral.opacity(0.2), Color.premiumCoral.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 36, height: 36)
                
                Image(systemName: promptType.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.premiumCoral)
            }

            // Text Content
            VStack(alignment: .leading, spacing: 2) {
                Text(promptType.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.softWhite)

                Text(promptType.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.panelTextSecondary)
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                // Secondary (Dismiss)
                Button(action: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isVisible = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onDismiss()
                    }
                }) {
                    Text(promptType.secondaryButtonText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.panelTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(PlainButtonStyle())

                // Primary (Action)
                Button(action: {
                    onPrimaryAction()
                }) {
                    Text(promptType.primaryButtonText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color.premiumCoral, Color.premiumCoral.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .shadow(color: Color.premiumCoral.opacity(0.3), radius: 8, x: 0, y: 4)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(12)
        .background(
            ZStack {
                // Glass Background
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.glassBackground)
                    .background(
                        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    )
                
                // Subtle Border
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.2), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        // Entry Animation
        .offset(y: isVisible ? 0 : 20)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                isVisible = true
            }
            startDismissCountdown()
        }
    }

    private func startDismissCountdown() {
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissSeconds) {
            withAnimation(.easeOut(duration: 0.3)) {
                isVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onDismiss()
            }
        }
    }
}

// Helper for Glassmorphism
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Edge Peek View (Laws of UX Warm Minimalism)

/// Minimal view shown when panel is docked at edge - warm cream theme
/// Shows distinctly different content based on recording state:
/// - Idle: warm cream edge with subtle grip dots
/// - Recording: pulsing red dot with compact waveform
/// - Silence warning: amber ring around recording indicator
struct EdgePeekView: View {
    let isRecording: Bool
    let audioLevels: [Float]
    let systemAudioLevels: [Float]
    let recordingDuration: TimeInterval
    var silenceWarning: Bool = false  // Amber ring when silence detected
    var onStop: () -> Void = {}

    var body: some View {
        ZStack {
            // Warm cream background with vibrancy
            RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                .fill(Color.surfaceEggshell.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                        .stroke(
                            isRecording ? Color.recordingCoral.opacity(0.5) : Color.accentBlue.opacity(0.15),
                            lineWidth: isRecording ? 2 : 1
                        )
                )
                .shadow(
                    color: CardStyle.shadowSubtle.color,
                    radius: CardStyle.shadowSubtle.radius,
                    x: CardStyle.shadowSubtle.x,
                    y: CardStyle.shadowSubtle.y
                )

            if isRecording {
                VStack(spacing: 8) {
                    // Recording Indicator (Red dot, amber ring when silence warning)
                    ZStack {
                        // Amber pulsing ring when silence detected (UX: non-intrusive warning)
                        if silenceWarning {
                            Circle()
                                .stroke(Color.statusWarningMuted, lineWidth: 2)
                                .frame(width: 18, height: 18)
                                .opacity(Double(Int(Date().timeIntervalSince1970 * 1.5) % 2 == 0 ? 1.0 : 0.4))
                        }

                        Circle()
                            .fill(silenceWarning ? Color.statusWarningMuted : Color.recordingCoral)
                            .frame(width: 10, height: 10)
                            .shadow(color: (silenceWarning ? Color.statusWarningMuted : Color.recordingCoral).opacity(0.6), radius: 4)
                            .opacity(Double(Int(Date().timeIntervalSince1970 * 2) % 2 == 0 ? 1.0 : 0.5))
                    }

                    // Dual Waveform showing both mic and system audio
                    WaveformMiniView(levels: audioLevels, systemLevels: systemAudioLevels)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.vertical, 8)
            } else {
                // Idle: Subtle grip dots (Laws of UX minimal)
                VStack(spacing: 6) {
                    ForEach(0..<8, id: \.self) { _ in
                        Circle()
                            .fill(Color.accentBlue.opacity(0.2))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
        .frame(width: isRecording ? 60 : 28, height: 110) // Match panelHeight (110), idle 28px for discoverability
    }
}

// MARK: - Waveform Mini View (Abstract, Laws of UX style)
// Shows both mic and system audio with distinct visual styles:
// - Mic audio: Filled bars (your voice)
// - System audio: Outlined bars (what you're hearing)

struct WaveformMiniView: View {
    let levels: [Float]  // Microphone audio levels
    var systemLevels: [Float]? = nil  // Optional system audio levels
    var barCount: Int = 8
    var maxHeight: CGFloat = 40

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                let micLevel = index < levels.count ? CGFloat(levels[index]) : 0
                let sysLevel = systemLevels.map { index < $0.count ? CGFloat($0[index]) : 0 } ?? 0

                ZStack(alignment: .bottom) {
                    // System audio: Outlined bar (behind mic bar)
                    if let _ = systemLevels, sysLevel > 0.05 {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(colorForSystemLevel(sysLevel), lineWidth: 1.5)
                            .frame(width: 4, height: max(4, sysLevel * maxHeight))
                    }

                    // Mic audio: Filled bar (foreground)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorForMicLevel(micLevel))
                        .frame(width: 4, height: max(4, micLevel * maxHeight))
                }
                .frame(height: maxHeight, alignment: .bottom)
            }
        }
    }

    /// Color for microphone audio (your voice) - warm tones
    private func colorForMicLevel(_ level: CGFloat) -> Color {
        if level > 0.75 {
            return Color.recordingCoral
        } else if level > 0.5 {
            return Color.statusWarningMuted
        } else if level > 0.1 {
            return Color.accentBlue.opacity(0.7)
        } else {
            return Color.accentBlue.opacity(0.3)
        }
    }

    /// Color for system audio (what you're hearing) - cool tones to differentiate
    private func colorForSystemLevel(_ level: CGFloat) -> Color {
        if level > 0.75 {
            return Color.purple.opacity(0.8)
        } else if level > 0.5 {
            return Color.purple.opacity(0.6)
        } else {
            return Color.purple.opacity(0.4)
        }
    }
}

// MARK: - Dormant Waveform View (Idle state - subtle breathing animation)

/// 8 flat bars that subtly "breathe" using sine wave animation
/// Terracotta color at 60% opacity, 2px bar width, 2px spacing
@available(macOS 14.0, *)
struct DormantWaveformView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var phase: Double = 0

    private let barCount = 8
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 8

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.terracotta.opacity(0.6))
                    .frame(width: barWidth, height: barHeight(for: index))
            }
        }
        .onAppear {
            if !reduceMotion {
                startBreathing()
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard !reduceMotion else { return (minHeight + maxHeight) / 2 }

        // Create wave pattern across bars
        let offset = Double(index) * 0.4
        let wave = sin(phase + offset)
        let normalized = (wave + 1) / 2  // 0 to 1
        return minHeight + (maxHeight - minHeight) * CGFloat(normalized)
    }

    private func startBreathing() {
        // Slow, subtle breathing animation (3 second cycle)
        withAnimation(
            .linear(duration: 3)
            .repeatForever(autoreverses: false)
        ) {
            phase = .pi * 2
        }
    }
}

// MARK: - Pill Idle View (40x20px - Dynamic Island style)

/// Minimal capsule shown when app is idle
/// Frosted glass background, dormant waveform, tap to start recording
@available(macOS 14.0, *)
struct PillIdleView: View {
    let onTap: () -> Void
    let failedCount: Int  // Badge for failed transcriptions

    @State private var isHovered = false

    init(onTap: @escaping () -> Void, failedCount: Int = 0) {
        self.onTap = onTap
        self.failedCount = failedCount
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Frosted glass capsule background
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.3), Color.white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.5
                            )
                    )

                // Dormant waveform centered
                DormantWaveformView()

                // Failed transcription badge (top-right)
                if failedCount > 0 {
                    FailedBadgeOverlay(count: failedCount)
                        .offset(x: PillDimensions.idleWidth / 2 - 6, y: -PillDimensions.idleHeight / 2 + 4)
                }
            }
            .frame(width: PillDimensions.idleWidth, height: PillDimensions.idleHeight)
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .shadow(color: Color.black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.pillMorph) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("Start recording")
        .accessibilityHint("Double-tap to start recording audio")
    }
}

// MARK: - Failed Badge Overlay

/// Small red circle showing count of failed transcriptions
struct FailedBadgeOverlay: View {
    let count: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.errorCoral)
                .frame(width: 14, height: 14)

            Text("\(min(count, 9))\(count > 9 ? "+" : "")")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
        }
        .shadow(color: Color.errorCoral.opacity(0.3), radius: 2)
    }
}

// MARK: - Recording Dot View (Pulsing red indicator)

/// Classic red recording dot with pulsing animation
@available(macOS 14.0, *)
struct RecordingDotView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isPulsing = false

    private let dotSize: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Color(hex: "#FF0000"))  // Pure red for recording
            .frame(width: dotSize, height: dotSize)
            .scaleEffect(isPulsing ? 1.1 : 0.9)
            .shadow(color: Color.red.opacity(0.5), radius: 4)
            .onAppear {
                if !reduceMotion {
                    startPulsing()
                }
            }
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            isPulsing = true
        }
    }
}

// MARK: - Pill Recording View (180x40px - Dynamic Island style)

/// Expanded pill shown during recording
/// Contains: recording dot, waveform visualizer, timer, stop button
@available(macOS 26.0, *)
struct PillRecordingView: View {
    @ObservedObject var audio: Audio
    let onStop: () -> Void

    @State private var isStopHovered = false

    var body: some View {
        ZStack {
            // Frosted glass background with coral border tint
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.recordingCoral.opacity(0.4), lineWidth: 1.5)
                )
                .shadow(color: Color.recordingCoral.opacity(0.2), radius: 8)

            HStack(spacing: 12) {
                // Recording dot
                RecordingDotView()
                    .padding(.leading, 12)

                // Waveform visualizer (reuse existing, smaller size)
                WaveformMiniView(
                    levels: Array(audio.audioLevelHistory.suffix(8)),
                    systemLevels: Array(audio.systemAudioLevelHistory.suffix(8)),
                    barCount: 6,
                    maxHeight: 20
                )
                .frame(width: 50, height: 24)

                // Timer (SF Mono, 13px)
                Text(formatDuration(audio.recordingDuration))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.panelTextPrimary)
                    .monospacedDigit()

                Spacer()

                // Stop button (28x28px circle)
                Button(action: onStop) {
                    ZStack {
                        Circle()
                            .fill(isStopHovered ? Color.panelCharcoalSurface : Color.panelCharcoalElevated)
                            .frame(width: 28, height: 28)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.panelTextPrimary)
                            .frame(width: 10, height: 10)
                    }
                    .scaleEffect(isStopHovered ? 1.1 : 1.0)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    withAnimation(.pillMorph) {
                        isStopHovered = hovering
                    }
                }
                .padding(.trailing, 6)
                .accessibilityLabel("Stop recording")
            }
        }
        .frame(width: PillDimensions.recordingWidth, height: PillDimensions.recordingHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording in progress, \(formatDurationAccessible(audio.recordingDuration))")
        .accessibilityHint("Contains stop button")
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func formatDurationAccessible(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") \(seconds) second\(seconds == 1 ? "" : "s")"
        }
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }
}

// MARK: - Pill Processing View (180x40px - Status indicator)

/// Shown during transcription/processing
/// Displays status with icon and animated dots
@available(macOS 14.0, *)
struct PillProcessingView: View {
    let status: DisplayStatus

    var body: some View {
        ZStack {
            // Frosted glass background
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.processingPurple.opacity(0.3), lineWidth: 1)
                )

            HStack(spacing: 10) {
                // Status icon with spinning animation for processing states
                Image(systemName: status.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(statusColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: status.isProcessing)

                // Status text with animated dots
                HStack(spacing: 0) {
                    Text(status.statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.panelTextPrimary)

                    if status.isProcessing {
                        AnimatedDotsView()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(width: PillDimensions.recordingWidth, height: PillDimensions.recordingHeight)
        .accessibilityLabel(status.statusText)
    }

    private var statusColor: Color {
        switch status {
        case .preparing, .transcribing:
            return .statusProcessingMuted
        case .extractingActionItems:
            return .processingPurple
        case .saving:
            return .statusProcessingMuted
        case .completed, .transcriptSaved:
            return .statusSuccessMuted
        case .failed:
            return .statusErrorMuted
        default:
            return .panelTextSecondary
        }
    }
}

// MARK: - Pill Reviewing View (Bottom pill during review tray)

/// Shown at bottom of review tray
/// Green success tint with task count - anchors the expanded tray above
@available(macOS 14.0, *)
struct PillReviewingView: View {
    let itemCount: Int
    var onTap: (() -> Void)? = nil  // Optional tap handler for future expand/collapse

    @State private var isHovered = false
    @State private var pulseOpacity: Double = 0.4

    var body: some View {
        Button(action: { onTap?() }) {
            ZStack {
                // Subtle pulsing glow behind pill (draws attention)
                Capsule()
                    .fill(Color.statusSuccessMuted.opacity(pulseOpacity * 0.3))
                    .frame(width: PillDimensions.recordingWidth + 8, height: PillDimensions.recordingHeight + 4)
                    .blur(radius: 8)

                // Frosted glass with green success tint
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.statusSuccessMuted.opacity(0.5), lineWidth: 1.5)
                    )

                HStack(spacing: 8) {
                    // Checklist icon with badge indicator
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "checklist")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.statusSuccessMuted)

                        // Small count badge
                        Circle()
                            .fill(Color.statusSuccessMuted)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Text("\(min(itemCount, 9))")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                            )
                            .offset(x: 8, y: -6)
                    }

                    Text("\(itemCount) task\(itemCount == 1 ? "" : "s") to review")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.panelTextPrimary)

                    // Up arrow indicator showing tray is above
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.panelTextMuted)
                }
            }
            .frame(width: PillDimensions.recordingWidth, height: PillDimensions.recordingHeight)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .shadow(color: Color.statusSuccessMuted.opacity(0.2), radius: 8, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.pillMorph) {
                isHovered = hovering
            }
        }
        .onAppear {
            // Subtle pulse animation to draw attention
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.8
            }
        }
        .accessibilityLabel("\(itemCount) tasks ready to review")
        .accessibilityHint("Review tray is open above")
    }
}

// MARK: - Pill Success Celebration (Phase 6 Polish)

/// Expanding green glow ring with checkmark
/// Shows briefly when tasks are added successfully
@available(macOS 14.0, *)
struct PillSuccessCelebration: View {
    let taskCount: Int
    let isVisible: Bool

    @State private var ringScale: CGFloat = 0.8
    @State private var ringOpacity: Double = 0
    @State private var contentOpacity: Double = 0

    var body: some View {
        ZStack {
            // Expanding glow ring
            Circle()
                .stroke(Color.statusSuccessMuted.opacity(0.4), lineWidth: 3)
                .frame(width: 80, height: 80)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            // Inner content
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.statusSuccessMuted)

                Text("\(taskCount) added")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.panelTextPrimary)
            }
            .opacity(contentOpacity)
        }
        .onChange(of: isVisible) { _, visible in
            if visible {
                animate()
            } else {
                reset()
            }
        }
        .onAppear {
            if isVisible {
                animate()
            }
        }
    }

    private func animate() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
            ringScale = 1.5
            ringOpacity = 1
            contentOpacity = 1
        }

        // Fade out ring
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.5)) {
                ringOpacity = 0
            }
        }
    }

    private func reset() {
        ringScale = 0.8
        ringOpacity = 0
        contentOpacity = 0
    }
}

// MARK: - Pill Error View (Phase 6 Polish)

/// Coral-tinted pill with shake animation for errors
/// Shows recovery hint and auto-dismisses
@available(macOS 14.0, *)
struct PillErrorView: View {
    let message: String
    let hint: String?
    @Binding var isVisible: Bool

    @State private var shakeOffset: CGFloat = 0
    @State private var contentOpacity: Double = 0

    var body: some View {
        ZStack {
            // Error-tinted frosted glass
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.errorCoral.opacity(0.5), lineWidth: 1.5)
                )
                .shadow(color: Color.errorCoral.opacity(0.2), radius: 6)

            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.errorCoral)

                VStack(alignment: .leading, spacing: 2) {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.panelTextPrimary)
                        .lineLimit(1)

                    if let hint = hint {
                        Text(hint)
                            .font(.system(size: 10))
                            .foregroundColor(.panelTextSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Dismiss button
                Button(action: { isVisible = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.panelTextMuted)
                        .padding(4)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 12)
        }
        .frame(width: PillDimensions.recordingWidth + 40, height: PillDimensions.recordingHeight + 8)
        .offset(x: shakeOffset)
        .opacity(contentOpacity)
        .onChange(of: isVisible) { _, visible in
            if visible {
                animateIn()
            }
        }
        .onAppear {
            if isVisible {
                animateIn()
            }
        }
        .accessibilityLabel("Error: \(message)")
        .accessibilityHint(hint ?? "Tap X to dismiss")
    }

    private func animateIn() {
        // Fade in
        withAnimation(.easeOut(duration: 0.2)) {
            contentOpacity = 1
        }

        // Shake animation (5 cycles)
        let shakeSequence: [CGFloat] = [5, -5, 4, -4, 3, -3, 2, -2, 1, -1, 0]
        for (index, offset) in shakeSequence.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.05) {
                withAnimation(.linear(duration: 0.05)) {
                    shakeOffset = offset
                }
            }
        }

        // Auto-dismiss after 4 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation(.easeOut(duration: 0.3)) {
                contentOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isVisible = false
            }
        }
    }
}

// MARK: - Review Tray View (Expands upward for action item review)

/// Wrapper around ActionItemReviewView with frosted glass styling
/// Expands upward from the pill when reviewing action items
@available(macOS 26.0, *)
struct ReviewTrayView: View {
    @ObservedObject var taskManager: TranscriptionTaskManager

    @State private var isAppearing = false

    var body: some View {
        VStack(spacing: Spacing.sm) {
            // Frosted glass container for review UI
            ZStack {
                // Background with stronger visual presence
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.statusSuccessMuted.opacity(0.3), Color.white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.2), radius: 16, y: 6)
                    .shadow(color: Color.statusSuccessMuted.opacity(0.1), radius: 20, y: 2)

                // Action Item Review Content
                if taskManager.pendingReview != nil {
                    ActionItemReviewView(taskManager: taskManager)
                        .padding(Spacing.md)
                } else {
                    // Placeholder while loading
                    VStack(spacing: Spacing.sm) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading tasks...")
                            .font(.caption)
                            .foregroundColor(.panelTextSecondary)
                    }
                    .padding(Spacing.lg)
                }
            }
            .frame(width: PillDimensions.trayWidth)
            .frame(minHeight: 100, maxHeight: PillDimensions.trayMaxHeight)

            // Small connector indicator (visual connection to pill below)
            Triangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 12, height: 6)
                .rotationEffect(.degrees(180))
        }
        .scaleEffect(isAppearing ? 1 : 0.9)
        .opacity(isAppearing ? 1 : 0)
        .onAppear {
            withAnimation(.trayExpand) {
                isAppearing = true
            }
        }
        .onDisappear {
            isAppearing = false
        }
    }
}

// MARK: - Triangle Shape (for tray connector)

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - SwiftUI View

@available(macOS 26.0, *)
struct FloatingPanelView: View {
    @ObservedObject var taskManager: TranscriptionTaskManager
    @ObservedObject var audio: Audio
    @ObservedObject var dockingManager: EdgeDockingManager
    @ObservedObject var pillStateManager: PillStateManager

    @State private var showCompletionCheckmark = false
    @State private var checkmarkScale: CGFloat = 0.7
    @State private var isRecordButtonHovered = false
    @State private var isFileButtonHovered = false

    // Success celebration states (Peak-End Rule)
    @State private var showRecordingStoppedCelebration = false
    @State private var showTranscriptSavedCelebration = false
    @State private var showActionItemsCelebration = false
    @State private var actionItemsCount: Int = 0
    @State private var previousRecordingState = false

    // Attention prompt states
    @State private var showSilencePrompt = false
    @State private var silencePromptDismissed = false  // Prevents re-showing after dismiss
    private let silenceThresholdSeconds: TimeInterval = 120  // 2 minutes

    private let panelHeight: CGFloat = 110  // Increased to fit content (was 68)
    private let panelWidth: CGFloat = 200  // Reduced width
    private let baseNotificationHeight: CGFloat = 100  // Base space for celebrations
    private let reviewNotificationHeight: CGFloat = 280  // Expanded height for review UI
    private let totalWindowWidth: CGFloat = 320  // Wide enough for notifications
    private let maxWindowHeight: CGFloat = 390  // Max window size (controller uses this)

    // Dynamic notification height based on review state
    private var notificationHeight: CGFloat {
        taskManager.pendingReview != nil ? reviewNotificationHeight : baseNotificationHeight
    }

    // Dynamic total height for content area (matches controller's window)
    private var totalWindowHeight: CGFloat {
        maxWindowHeight
    }

    // Whether we have pending action items to review
    private var hasPendingReview: Bool {
        taskManager.pendingReview != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Spacer (pushes content to bottom)
            Spacer(minLength: 0)

            // MARK: - Review Tray (expands upward when reviewing)
            if pillStateManager.state == .reviewing {
                ReviewTrayView(taskManager: taskManager)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    ))
            }

            // MARK: - Celebration Overlays (float above pill)
            ZStack {
                Color.clear
                    .frame(height: 60)

                // Transcript saved celebration
                if showTranscriptSavedCelebration && pillStateManager.state != .reviewing {
                    CelebrationOverlay(
                        celebrationType: .transcriptSaved,
                        isVisible: showTranscriptSavedCelebration
                    )
                    .transition(.scale.combined(with: .opacity))
                }

                // Action items celebration
                if showActionItemsCelebration && pillStateManager.state != .reviewing {
                    CelebrationOverlay(
                        celebrationType: .actionItemsCreated(count: actionItemsCount),
                        isVisible: showActionItemsCelebration
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }

            // MARK: - Pill Content (centered, morphs between states)
            pillContent
                .animation(.pillMorph, value: pillStateManager.state)
                .padding(.bottom, 10)
        }
        .frame(width: pillStateManager.state == .reviewing ? PillDimensions.trayWidth + 40 : PillDimensions.recordingWidth + 40)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onChange(of: taskManager.justCompleted) { _, newValue in
            if newValue {
                triggerCompletionCheckmark()
            }
        }
        .onChange(of: audio.silenceDuration) { _, duration in
            // UX: Don't interrupt user flow - just show amber ring, don't force panel open
            if audio.isRecording && duration >= silenceThresholdSeconds && !silencePromptDismissed && !showSilencePrompt {
                showSilencePrompt = true
                // Removed: dockingManager.shouldExpand = true
                // User will see amber ring and can choose to expand if needed
            }
        }
        .onChange(of: audio.isRecording) { _, isRecording in
            if !isRecording {
                showSilencePrompt = false
                silencePromptDismissed = false

                // Trigger recording stopped celebration when recording ends
                if previousRecordingState {
                    triggerRecordingStoppedCelebration()
                }
            }
            previousRecordingState = isRecording
        }
        // Trigger celebrations based on displayStatus changes
        .onChange(of: taskManager.displayStatus) { _, newStatus in
            switch newStatus {
            case .transcriptSaved:
                triggerTranscriptSavedCelebration()
            case .completed(let count):
                triggerActionItemsCelebration(count: count)
            default:
                break
            }
        }
        // Lock panel open when review is active
        .onChange(of: taskManager.pendingReview) { _, newReview in
            if newReview != nil {
                // Expand and lock panel when review starts
                dockingManager.shouldExpand = true
                dockingManager.isLocked = true
            } else {
                // Unlock panel when review ends
                dockingManager.isLocked = false
            }
        }
    }

    // MARK: - Celebration Triggers

    private func triggerRecordingStoppedCelebration() {
        showRecordingStoppedCelebration = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showRecordingStoppedCelebration = false
        }
    }

    private func triggerTranscriptSavedCelebration() {
        showTranscriptSavedCelebration = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showTranscriptSavedCelebration = false
        }
    }

    private func triggerActionItemsCelebration(count: Int) {
        actionItemsCount = count
        showActionItemsCelebration = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            showActionItemsCelebration = false
        }
    }

    // MARK: - Pill Content (Dynamic Island-style state switching)

    /// Switches between pill views based on current state
    @ViewBuilder
    private var pillContent: some View {
        switch pillStateManager.state {
        case .idle:
            PillIdleView(
                onTap: { audio.start() },
                failedCount: 0  // TODO: Wire to FailedTranscriptionManager
            )
        case .recording:
            PillRecordingView(audio: audio) {
                audio.stop()
            }
        case .processing:
            PillProcessingView(status: taskManager.displayStatus)
        case .reviewing:
            PillReviewingView(itemCount: taskManager.pendingReview?.totalCount ?? 0)
        }
    }

    // MARK: - Full Panel Content (Laws of UX Warm Minimalism) - DEPRECATED

    private var fullPanelContent: some View {
        VStack(spacing: 10) {
            // Status Display Area (Laws of UX card style)
            ZStack {
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .fill(Color.surfaceCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                            .stroke(Color.accentBlue.opacity(0.1), lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    // Left side: Status display with priority logic
                    if audio.isRecording {
                        // Recording indicator dot with glow pulse
                        Circle()
                            .fill(Color.recordingCoral)
                            .frame(width: 8, height: 8)
                            .shadow(color: .recordingCoral.opacity(0.5), radius: 2)
                            .pulse(when: true, minScale: 0.9, maxScale: 1.1)

                        if showSilencePrompt {
                            // Silence warning during recording
                            Text("Silence: \(Int(audio.silenceDuration / 60))m")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.statusWarningMuted)
                        } else {
                            // Timer display (monospace for retro feel)
                            Text(formatDuration(audio.recordingDuration))
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.textOnCream)
                        }
                    } else {
                        // Status display with celebration overlays
                        ZStack {
                            LawsStatusTextView(status: taskManager.displayStatus)

                            // Recording stopped celebration (blue ring)
                            RecordingStoppedCelebration(isVisible: showRecordingStoppedCelebration)
                        }
                    }

                    Spacer()

                    // Right side: Mini waveform only when recording (shows both mic & system audio)
                    if audio.isRecording {
                        WaveformMiniView(
                            levels: Array(audio.audioLevelHistory.suffix(8)),
                            systemLevels: Array(audio.systemAudioLevelHistory.suffix(8)),
                            maxHeight: 20
                        )
                        .frame(height: 20)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 28)

            // Controls (Laws of UX style buttons)
            HStack(spacing: 10) {
                LawsButton(
                    iconName: audio.isRecording ? "stop.fill" : "record.circle",
                    label: audio.isRecording ? "Stop" : "Record",
                    color: audio.isRecording ? .textOnCreamSecondary : .recordingCoral,
                    isActive: audio.isRecording
                ) {
                    if audio.isRecording {
                        audio.stop()
                    } else {
                        audio.start()
                    }
                }

                LawsButton(
                    iconName: "folder.fill",
                    label: "Files",
                    color: .accentBlue,
                    isActive: false
                ) {
                    openTranscriptsFolder()
                }
            }
        }
        .padding(12)
    }

    // MARK: - Panel Background (Laws of UX Warm Minimalism)

    private var panelBackground: some View {
        ZStack {
            // Warm cream base with vibrancy
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)

            // Eggshell tint overlay
            Color.surfaceEggshell.opacity(0.85)

            // Recording state: Add red glow border
            if audio.isRecording {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .stroke(Color.recordingCoral.opacity(0.5), lineWidth: 2)
            }

            // Subtle border (Laws of UX style)
            RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                .stroke(Color.accentBlue.opacity(0.15), lineWidth: 1)
        }
        // Laws of UX shadow
        .shadow(
            color: CardStyle.shadowCard.color,
            radius: CardStyle.shadowCard.radius,
            x: CardStyle.shadowCard.x,
            y: CardStyle.shadowCard.y
        )
    }

    // MARK: - Error Overlay (Contextual with recovery actions)

    private var errorOverlay: some View {
        Group {
            if let errorMessage = audio.error {
                let contextualError = ContextualError.from(message: errorMessage)

                VStack {
                    Spacer()
                    ContextualErrorBanner(
                        error: contextualError,
                        onTap: errorTapAction(for: contextualError)
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
    }

    /// Returns the appropriate action for tapping on an error banner
    private func errorTapAction(for error: ContextualError) -> (() -> Void)? {
        switch error {
        case .transcriptionFailed:
            // Could trigger retry - for now, just open settings
            return {
                if let url = URL(string: "x-apple.systempreferences:") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .microphoneError, .permissionDenied:
            // Open System Settings > Privacy > Microphone
            return {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .invalidAPIKey:
            // Could open app settings - for now just dismiss
            return nil
        case .storageFull:
            // Open About This Mac > Storage
            return {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.storagemanagement") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .networkError:
            // Open Network preferences
            return {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.network") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .unknown:
            return nil
        }
    }

    // MARK: - Helper Functions

    private func openTranscriptsFolder() {
        let transcriptsFolder: URL
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            transcriptsFolder = URL(fileURLWithPath: customPath)
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            transcriptsFolder = documentsPath.appendingPathComponent("Transcripted")
        }
        try? FileManager.default.createDirectory(at: transcriptsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(transcriptsFolder)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func triggerCompletionCheckmark() {
        checkmarkScale = 0.0
        showCompletionCheckmark = true

        withAnimation(.spring(response: 0.7, dampingFraction: 0.5, blendDuration: 0)) {
            checkmarkScale = 0.9
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                showCompletionCheckmark = false
                checkmarkScale = 0.7
            }
        }
    }
}

// MARK: - Screw View
struct ScrewView: View {
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 6, height: 6)
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 4, weight: .black))
                    .foregroundColor(.black.opacity(0.7))
                    .rotationEffect(.degrees(45))
            )
            .shadow(color: .white.opacity(0.1), radius: 0, x: 0, y: 1)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: -0.5)
    }
}



// MARK: - Visual Effect



// MARK: - CGFloat Clamping Extension

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
import SwiftUI

// MARK: - Retro Colors

extension Color {
    static let retroDarkGray = Color(red: 0.15, green: 0.15, blue: 0.16)
    static let retroBlack = Color(red: 0.1, green: 0.1, blue: 0.1)
    static let retroSilver = Color(red: 0.8, green: 0.8, blue: 0.85)
    static let retroOrange = Color(red: 1.0, green: 0.35, blue: 0.0)
    static let retroGreen = Color(red: 0.2, green: 0.8, blue: 0.2)
    static let retroRed = Color(red: 0.9, green: 0.1, blue: 0.1)
    static let retroGold = Color(red: 0.8, green: 0.6, blue: 0.2)
}

// MARK: - Retro Button

struct RetroButton: View {
    let iconName: String
    let label: String?
    let color: Color
    let isActive: Bool
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    // Button Base (Shadow/Depth)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.5))
                        .offset(y: isPressed ? 1 : 3)
                    
                    // Button Top
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(white: 0.25),
                                    Color(white: 0.15)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .offset(y: isPressed ? 1 : 0)
                    
                    // Icon/Content
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isActive ? color : .gray)
                        .shadow(color: isActive ? color.opacity(0.6) : .clear, radius: 4)
                        .offset(y: isPressed ? 1 : 0)
                }
                .frame(width: 36, height: 32)
                
                if let label = label {
                    Text(label)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.gray)
                        .textCase(.uppercase)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}





// MARK: - Status Text View

/// Displays contextual status text in the display area when not recording
struct StatusTextView: View {
    let status: DisplayStatus

    var body: some View {
        HStack(spacing: 0) {
            Text(statusText)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.retroGreen)
                .shadow(color: .retroGreen.opacity(0.5), radius: 2)

            if showAnimatedDots {
                AnimatedDotsView()
            }
        }
    }

    private var statusText: String {
        // Use the computed statusText from DisplayStatus enum
        status.statusText
    }

    private var showAnimatedDots: Bool {
        status.isProcessing
    }
}

// MARK: - Animated Dots View

/// Animated "..." that cycles through 1, 2, 3 dots
struct AnimatedDotsView: View {
    @State private var dotCount = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(String(repeating: ".", count: dotCount + 1))
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.retroGreen)
            .shadow(color: .retroGreen.opacity(0.5), radius: 2)
            .frame(width: 24, alignment: .leading)
            .onReceive(timer) { _ in
                dotCount = (dotCount + 1) % 3
            }
    }
}

// MARK: - Marquee Text View

/// Scrolling text that animates left-to-right when text is too wide for container
@available(macOS 26.0, *)
struct MarqueeTextView: View {
    let text: String
    let font: Font
    let color: Color

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isAnimating = false

    private var needsScrolling: Bool {
        textWidth > containerWidth && containerWidth > 0
    }

    var body: some View {
        GeometryReader { geometry in
            Text(text)
                .font(font)
                .foregroundColor(color)
                .shadow(color: color.opacity(0.5), radius: 2)
                .fixedSize()
                .background(
                    GeometryReader { textGeometry in
                        Color.clear
                            .onAppear {
                                textWidth = textGeometry.size.width
                                containerWidth = geometry.size.width
                                startScrollingIfNeeded()
                            }
                            .onChange(of: text) { _, _ in
                                // Reset and recalculate when text changes
                                offset = 0
                                isAnimating = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    textWidth = textGeometry.size.width
                                    startScrollingIfNeeded()
                                }
                            }
                    }
                )
                .offset(x: offset)
        }
        .clipped()
    }

    private func startScrollingIfNeeded() {
        guard needsScrolling && !isAnimating else { return }
        isAnimating = true

        let scrollDistance = textWidth - containerWidth + 20  // Extra padding
        let duration = Double(scrollDistance) / 30.0  // ~30pt per second

        // Animate: pause at start → scroll left → pause at end → scroll right → repeat
        withAnimation(
            .linear(duration: duration)
            .delay(1.0)
            .repeatForever(autoreverses: true)
        ) {
            offset = -scrollDistance
        }
    }
}

// MARK: - LED Visualizer

struct LEDVisualizer: View {
    let levels: [Float]
    var systemLevels: [Float]? = nil  // Optional system audio levels
    var rowCount: Int = 8
    var colCount: Int = 10
    var segmentWidth: CGFloat = 4
    var segmentHeight: CGFloat = 2
    var spacing: CGFloat = 1

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<colCount, id: \.self) { index in
                VStack(spacing: spacing) {
                    ForEach(0..<rowCount, id: \.self) { barIndex in
                        let row = (rowCount - 1) - barIndex
                        let micActive = shouldLightUp(col: index, row: row, levels: levels)
                        let sysActive = shouldLightUp(col: index, row: row, levels: systemLevels)

                        ZStack {
                            // Background layer: System audio (outlined rectangles)
                            if systemLevels != nil && sysActive {
                                Rectangle()
                                    .stroke(colorFor(row: row).opacity(0.6), lineWidth: 1)
                                    .frame(width: segmentWidth, height: segmentHeight)
                            }

                            // Foreground layer: Mic audio (filled) or inactive
                            Rectangle()
                                .fill(micActive ? colorFor(row: row) : Color.gray.opacity(0.2))
                                .frame(width: segmentWidth, height: segmentHeight)
                        }
                    }
                }
            }
        }
        .padding(4)
        .background(Color.black)
        .cornerRadius(2)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
        )
    }

    private func shouldLightUp(col: Int, row: Int, levels: [Float]?) -> Bool {
        guard let levels = levels, col < levels.count else { return false }
        let level = levels[col] // 0.0 to 1.0
        let threshold = Float(row) / Float(rowCount)
        return level > threshold
    }

    private func colorFor(row: Int) -> Color {
        let progress = Double(row) / Double(rowCount)
        if progress >= 0.75 { return .retroRed }
        if progress >= 0.5 { return .retroGold }
        return .retroGreen
    }
}

// MARK: - Contextual Error Type (UX Law: Provide actionable guidance)

/// Error types with icons and recovery actions for better user guidance
enum ContextualError: Equatable {
    case microphoneError(message: String)
    case transcriptionFailed(message: String)
    case networkError(message: String)
    case storageFull(message: String)
    case invalidAPIKey(message: String)
    case permissionDenied(message: String)
    case unknown(message: String)

    /// Parse an error message and return the appropriate ContextualError type
    static func from(message: String) -> ContextualError {
        let lowercased = message.lowercased()

        if lowercased.contains("microphone") || lowercased.contains("audio input") || lowercased.contains("mic") {
            return .microphoneError(message: message)
        } else if lowercased.contains("speech") || lowercased.contains("transcri") || lowercased.contains("recognition") {
            return .transcriptionFailed(message: message)
        } else if lowercased.contains("network") || lowercased.contains("connection") || lowercased.contains("internet") || lowercased.contains("offline") {
            return .networkError(message: message)
        } else if lowercased.contains("disk") || lowercased.contains("storage") || lowercased.contains("space") || lowercased.contains("full") {
            return .storageFull(message: message)
        } else if lowercased.contains("api key") || lowercased.contains("apikey") || lowercased.contains("invalid key") || lowercased.contains("authentication") {
            return .invalidAPIKey(message: message)
        } else if lowercased.contains("permission") || lowercased.contains("denied") || lowercased.contains("access") {
            return .permissionDenied(message: message)
        } else {
            return .unknown(message: message)
        }
    }

    var icon: String {
        switch self {
        case .microphoneError: return "mic.slash.fill"
        case .transcriptionFailed: return "waveform.badge.exclamationmark"
        case .networkError: return "wifi.exclamationmark"
        case .storageFull: return "externaldrive.badge.xmark"
        case .invalidAPIKey: return "key.slash.fill"
        case .permissionDenied: return "lock.shield.fill"
        case .unknown: return "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .microphoneError: return "Microphone Error"
        case .transcriptionFailed: return "Transcription Failed"
        case .networkError: return "Connection Lost"
        case .storageFull: return "Storage Full"
        case .invalidAPIKey: return "Invalid API Key"
        case .permissionDenied: return "Permission Denied"
        case .unknown: return "Error"
        }
    }

    var recoveryHint: String {
        switch self {
        case .microphoneError: return "Check microphone in Settings"
        case .transcriptionFailed: return "Tap to retry"
        case .networkError: return "Check internet connection"
        case .storageFull: return "Free up disk space"
        case .invalidAPIKey: return "Update key in Settings"
        case .permissionDenied: return "Grant access in System Settings"
        case .unknown: return "Try again"
        }
    }

    var color: Color {
        switch self {
        case .microphoneError, .permissionDenied:
            return .statusWarningMuted  // Amber for permission issues
        case .networkError, .storageFull:
            return .statusWarningMuted  // Amber for recoverable issues
        case .transcriptionFailed, .invalidAPIKey, .unknown:
            return .statusErrorMuted    // Red for errors
        }
    }
}

// MARK: - Contextual Error Banner View

/// A more informative error banner with icon, title, and recovery action
@available(macOS 14.0, *)
struct ContextualErrorBanner: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let error: ContextualError
    let onTap: (() -> Void)?

    @State private var isVisible = false
    @State private var isShaking = false

    init(error: ContextualError, onTap: (() -> Void)? = nil) {
        self.error = error
        self.onTap = onTap
    }

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 10) {
                // Icon with background
                ZStack {
                    Circle()
                        .fill(error.color.opacity(0.15))
                        .frame(width: 32, height: 32)

                    Image(systemName: error.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(error.color)
                }

                // Text content
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.textOnCream)

                    Text(error.recoveryHint)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.textOnCreamMuted)
                }

                Spacer()

                // Chevron if tappable
                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.textOnCreamMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .fill(Color.surfaceCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                            .stroke(error.color.opacity(0.3), lineWidth: 1)
                    )
            )
            .shadow(
                color: error.color.opacity(0.15),
                radius: 8,
                y: 4
            )
        }
        .buttonStyle(PlainButtonStyle())
        .hoverScale(1.01)
        .shake(when: isShaking)
        .offset(y: isVisible ? 0 : 20)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isVisible = true
            }
            // Brief shake to draw attention
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !reduceMotion {
                    isShaking = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        isShaking = false
                    }
                }
            }
        }
    }
}

// MARK: - Success Celebration Overlay (Peak-End Rule: positive endings are remembered)

/// Overlay that shows celebration animations for success states
/// Uses Laws of UX aesthetic with warm, subtle animations
@available(macOS 14.0, *)
struct CelebrationOverlay: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let celebrationType: CelebrationType
    let isVisible: Bool

    enum CelebrationType: Equatable {
        case recordingStopped           // Blue pulse ring fade
        case transcriptSaved            // Green checkmark scale-in
        case actionItemsCreated(count: Int)  // Count badge with bounce
    }

    @State private var ringScale: CGFloat = 0.8
    @State private var ringOpacity: Double = 0.0
    @State private var checkScale: CGFloat = 0.5
    @State private var badgeBounce: CGFloat = 1.0

    var body: some View {
        ZStack {
            switch celebrationType {
            case .recordingStopped:
                recordingStoppedCelebration
            case .transcriptSaved:
                transcriptSavedCelebration
            case .actionItemsCreated(let count):
                actionItemsCelebration(count: count)
            }
        }
        .opacity(isVisible ? 1.0 : 0.0)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.3), value: isVisible)
        .onChange(of: isVisible) { _, newValue in
            if newValue {
                triggerCelebration()
            }
        }
    }

    // MARK: - Recording Stopped (Blue pulse ring)

    private var recordingStoppedCelebration: some View {
        Circle()
            .stroke(Color.accentBlue.opacity(ringOpacity), lineWidth: 3)
            .frame(width: 60, height: 60)
            .scaleEffect(ringScale)
    }

    // MARK: - Transcript Saved (Green checkmark)

    private var transcriptSavedCelebration: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color.statusSuccessMuted.opacity(0.15))
                .frame(width: 48, height: 48)
                .scaleEffect(checkScale)

            // Checkmark icon
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundColor(.statusSuccessMuted)
                .scaleEffect(checkScale)
        }
    }

    // MARK: - Action Items Created (Count badge with bounce)

    private func actionItemsCelebration(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.statusSuccessMuted)

            Text("\(count) task\(count == 1 ? "" : "s") added")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.textOnCream)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.surfaceCard)
                .overlay(
                    Capsule()
                        .stroke(Color.statusSuccessMuted.opacity(0.3), lineWidth: 1)
                )
        )
        .shadow(color: Color.statusSuccessMuted.opacity(0.2), radius: 8, y: 4)
        .scaleEffect(badgeBounce)
    }

    // MARK: - Trigger Animation

    private func triggerCelebration() {
        guard !reduceMotion else { return }

        switch celebrationType {
        case .recordingStopped:
            // Blue ring expands and fades out
            ringScale = 0.8
            ringOpacity = 0.8
            withAnimation(.easeOut(duration: 0.6)) {
                ringScale = 1.5
                ringOpacity = 0.0
            }

        case .transcriptSaved:
            // Green checkmark scales in with bounce
            checkScale = 0.5
            withAnimation(.lawsSuccess) {
                checkScale = 1.0
            }
            // Subtle bounce
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                    checkScale = 1.1
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                    checkScale = 1.0
                }
            }

        case .actionItemsCreated:
            // Badge bounces in
            badgeBounce = 0.7
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                badgeBounce = 1.0
            }
            // Extra bounce
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.15, dampingFraction: 0.4)) {
                    badgeBounce = 1.1
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.spring(response: 0.1, dampingFraction: 0.6)) {
                    badgeBounce = 1.0
                }
            }
        }
    }
}

// MARK: - Recording Stopped Celebration View

/// Simple celebration when recording stops (before transcription starts)
@available(macOS 14.0, *)
struct RecordingStoppedCelebration: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let isVisible: Bool

    @State private var ringScale: CGFloat = 0.6
    @State private var ringOpacity: Double = 0.0

    var body: some View {
        Circle()
            .stroke(Color.accentBlue.opacity(ringOpacity), lineWidth: 2)
            .frame(width: 50, height: 50)
            .scaleEffect(ringScale)
            .onChange(of: isVisible) { _, newValue in
                if newValue && !reduceMotion {
                    ringScale = 0.6
                    ringOpacity = 0.7
                    withAnimation(.easeOut(duration: 0.5)) {
                        ringScale = 1.3
                        ringOpacity = 0.0
                    }
                }
            }
    }
}

// MARK: - Laws of UX Button (Warm Minimalism)

struct LawsButton: View {
    let iconName: String
    let label: String
    let color: Color
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isActive ? color : color.opacity(0.8))

                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textOnCream)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .fill(isActive ? color.opacity(0.15) : Color.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .stroke(isActive ? color.opacity(0.4) : Color.accentBlue.opacity(0.1), lineWidth: 1)
            )
            .shadow(
                color: isHovered ? CardStyle.shadowHover.color : CardStyle.shadowSubtle.color,
                radius: isHovered ? CardStyle.shadowHover.radius : CardStyle.shadowSubtle.radius,
                x: 0,
                y: isHovered ? 2 : 1
            )
            .scaleEffect(isPressed ? 0.96 : (isHovered ? 1.02 : 1.0))
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.lawsCardHover) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.lawsTap) { isPressed = true }
                }
                .onEnded { _ in
                    withAnimation(.lawsTap) { isPressed = false }
                }
        )
    }
}

// MARK: - Laws of UX Status Text View

struct LawsStatusTextView: View {
    let status: DisplayStatus

    var body: some View {
        HStack(spacing: 6) {
            // Status icon
            Image(systemName: statusIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(statusColor)

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.textOnCream)

            if showAnimatedDots {
                AnimatedDotsView()
            }
        }
    }

    private var statusText: String {
        // Use the computed statusText from DisplayStatus enum
        status.statusText
    }

    private var statusIcon: String {
        // Use the computed icon from DisplayStatus enum
        status.icon
    }

    private var statusColor: Color {
        switch status {
        case .idle:
            return .accentBlue
        case .preparing, .transcribing, .extractingActionItems, .saving:
            return .statusProcessingMuted
        case .transcriptSaved, .completed:
            return .statusSuccessMuted
        case .pendingReview:
            return .statusWarningMuted
        case .failed:
            return .statusErrorMuted
        }
    }

    private var showAnimatedDots: Bool {
        status.isProcessing
    }
}
