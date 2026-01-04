import Foundation
import AppKit
import Combine

/// Intelligent meeting detection using multi-signal approach
/// Detects when user is in a video call based on:
/// - Bidirectional audio (both mic AND system audio have speech)
/// - Running meeting apps (Zoom, Teams, Meet, etc.)
/// Uses confidence scoring to minimize false positives
@available(macOS 26.0, *)
class MeetingDetector: ObservableObject {
    // MARK: - Published State
    @Published private(set) var isMeetingDetected = false
    @Published private(set) var confidence: Int = 0

    // MARK: - Dependencies
    private weak var audio: Audio?
    private var cancellables = Set<AnyCancellable>()
    private var detectionTimer: Timer?

    // MARK: - Detection State
    private var bidirectionalStartTime: Date?
    private var dismissedUntil: Date?

    // MARK: - Configuration
    /// Audio level threshold for speech detection (0.0-1.0)
    private let speechThreshold: Float = 0.02

    /// How long bidirectional audio must persist before triggering (seconds)
    /// DEBUG: Lowered from 30 to 5 for testing
    private let requiredBidirectionalDuration: TimeInterval = 5

    /// Minimum confidence score to show meeting prompt (0-100)
    /// DEBUG: Lowered from 70 to 40 for testing
    private let confidenceThreshold = 40

    /// Cooldown period after user dismisses prompt (30 seconds for testing)
    /// DEBUG: Lowered from 1800 to 30 for testing
    private let dismissCooldown: TimeInterval = 30

    // MARK: - Meeting App Bundle IDs
    /// Common video conferencing apps to detect
    private let meetingAppBundleIds: Set<String> = [
        // Zoom
        "us.zoom.xos",
        // Microsoft Teams (both versions)
        "com.microsoft.teams",
        "com.microsoft.teams2",
        // Slack (huddles)
        "com.tinyspeck.slackmacgap",
        // Apple FaceTime
        "com.apple.FaceTime",
        // Discord
        "com.hnc.Discord",
        // Cisco Webex
        "com.webex.meetingmanager",
        // GoToMeeting
        "com.logmein.GoToMeeting",
        // Skype
        "com.skype.skype"
    ]

    // MARK: - Initialization

    init(audio: Audio) {
        self.audio = audio
    }

    // MARK: - Detection Control

    /// Start monitoring for meetings
    func startDetection() {
        guard detectionTimer == nil else { return }

        print("🔍 Meeting detection started")

        // Run detection every 1 second
        detectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.runDetection()
        }
    }

    /// Stop monitoring for meetings
    func stopDetection() {
        detectionTimer?.invalidate()
        detectionTimer = nil
        resetState()
        print("🔍 Meeting detection stopped")
    }

    /// User dismissed the meeting prompt - respect cooldown
    func dismiss() {
        dismissedUntil = Date().addingTimeInterval(dismissCooldown)
        isMeetingDetected = false
        resetState()
        print("🔍 Meeting prompt dismissed, cooldown until \(dismissedUntil!)")
    }

    // MARK: - Detection Logic

    private func runDetection() {
        guard let audio = audio else { return }

        // Don't detect while already recording
        guard !audio.isRecording else {
            if isMeetingDetected {
                resetState()
            }
            return
        }

        // Respect dismiss cooldown
        if let dismissedUntil = dismissedUntil, Date() < dismissedUntil {
            return
        }

        // Get current audio levels
        let micLevel = audio.audioLevel
        let systemLevel = audio.systemAudioLevelHistory.last ?? 0.0

        // Check for bidirectional audio (strongest meeting indicator)
        let micHasSpeech = micLevel > speechThreshold
        let systemHasSpeech = systemLevel > speechThreshold
        let isBidirectional = micHasSpeech && systemHasSpeech

        if isBidirectional {
            // Start or continue tracking bidirectional audio
            if bidirectionalStartTime == nil {
                bidirectionalStartTime = Date()
                print("🔍 Bidirectional audio detected, starting timer...")
            }

            let duration = Date().timeIntervalSince(bidirectionalStartTime!)

            // Only trigger after sustained bidirectional audio
            if duration >= requiredBidirectionalDuration {
                calculateConfidence(bidirectionalDuration: duration)
            }
        } else {
            // Reset if bidirectional audio stops
            if bidirectionalStartTime != nil {
                print("🔍 Bidirectional audio stopped, resetting timer")
                bidirectionalStartTime = nil

                // Also reset confidence if we haven't triggered yet
                if !isMeetingDetected {
                    confidence = 0
                }
            }
        }
    }

    private func calculateConfidence(bidirectionalDuration: TimeInterval) {
        var score = 40 // Base score for bidirectional audio (REQUIRED)

        // Meeting app bonus (+25%)
        if isMeetingAppRunning() {
            score += 25
        }

        // Duration bonus (+15% for 2+ minutes of bidirectional audio)
        if bidirectionalDuration > 120 {
            score += 15
        }

        // Update published confidence
        if confidence != score {
            confidence = score
            print("🔍 Meeting confidence: \(score)%")
        }

        // Trigger meeting detection if threshold met
        if score >= confidenceThreshold && !isMeetingDetected {
            print("✅ Meeting detected! Confidence: \(score)%")
            isMeetingDetected = true
        }
    }

    /// Check if any known meeting apps are running
    private func isMeetingAppRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications

        for app in runningApps {
            guard let bundleId = app.bundleIdentifier else { continue }

            if meetingAppBundleIds.contains(bundleId) {
                return true
            }
        }

        return false
    }

    private func resetState() {
        bidirectionalStartTime = nil
        confidence = 0
        isMeetingDetected = false
    }
}
