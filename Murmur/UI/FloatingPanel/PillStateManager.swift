import SwiftUI
import Combine
import AppKit

// MARK: - Sound Feedback

/// Lightweight sound manager for UI state feedback
/// Uses macOS system sounds for unobtrusive audio cues
enum PillSounds {
    /// Soft click for recording start
    static func playRecordingStart() {
        playSystemSound("Pop")
    }

    /// Subtle confirmation for recording stop
    static func playRecordingStop() {
        playSystemSound("Tink")
    }

    /// Soft completion sound
    static func playComplete() {
        playSystemSound("Glass")
    }

    /// Subtle alert for errors
    static func playError() {
        playSystemSound("Basso")
    }

    private static func playSystemSound(_ name: String) {
        // Check if sounds are enabled (respect user preference)
        guard UserDefaults.standard.bool(forKey: "enableUISounds") != false else { return }

        // Play from system sounds directory
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.volume = 0.3  // Keep it subtle (30% volume)
            sound.play()
        }
    }
}

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
@available(macOS 26.0, *)
@MainActor
class PillStateManager: ObservableObject {
    @Published var state: PillState = .idle
    @Published var isLocked = false  // Prevents state changes during review

    /// Flag to prevent rapid state changes during animations
    @Published private(set) var isTransitioning = false

    /// PHASE 4 FIX: Use unified timing from DesignTokens to prevent animation/cooldown mismatch
    private let transitionCooldown: TimeInterval = PillAnimationTiming.cooldownDuration

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

        // Play state-appropriate sound feedback
        playTransitionSound(from: previousState, to: newState)

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

    // MARK: - Sound Feedback

    /// Play appropriate sound based on state transition
    private func playTransitionSound(from previousState: PillState, to newState: PillState) {
        switch (previousState, newState) {
        case (_, .recording):
            // Starting recording - soft pop
            PillSounds.playRecordingStart()
        case (.recording, .processing):
            // Stopped recording, starting transcription - subtle tink
            PillSounds.playRecordingStop()
        case (.processing, .reviewing):
            // Transcription complete, showing action items - glass chime
            PillSounds.playComplete()
        case (_, .idle) where previousState == .reviewing:
            // Finished reviewing - subtle completion
            PillSounds.playComplete()
        default:
            // No sound for other transitions (keeps it unobtrusive)
            break
        }
    }
}
