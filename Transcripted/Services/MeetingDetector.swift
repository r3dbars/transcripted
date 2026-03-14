// MeetingDetector.swift
// Watches for meeting apps + bidirectional audio, then auto-starts/stops recording.
//
// Detection logic:
//   1. NSWorkspace notifications track when a known meeting app launches or quits.
//   2. When a meeting app is detected, Audio.startMonitoring() activates lightweight
//      mic + system audio level metering (no file recording).
//   3. A 1-second poll checks Audio.audioLevel (mic) + systemAudioLevelHistory (system).
//   4. Sustained bidirectional speech (both channels above threshold) for ≥5s with a meeting
//      app running → fire onMeetingStart. Audio.start() stops monitoring and begins recording.
//   5. Bidirectional audio drops for ≥15s → fire onMeetingEnd, re-start monitoring.
//   6. Meeting app quits while recording → onMeetingEnd fires immediately.
//
// All of this respects the UserDefaults "autoRecordMeetings" toggle. When disabled the
// detector still tracks state (published props update) but callbacks never fire — so the
// settings UI can show live status without triggering recordings.

import Foundation
import AppKit
import Combine

@available(macOS 26.0, *)
@MainActor
class MeetingDetector: ObservableObject {

    // MARK: - Published State

    /// Display name of the meeting app currently detected (e.g. "Zoom"), or nil when idle.
    @Published private(set) var activeMeetingApp: String? = nil

    /// True while the detector is actively polling (meeting app is running).
    @Published private(set) var isDetecting: Bool = false

    // MARK: - Callbacks

    /// Fires when a meeting with sustained bidirectional audio is detected.
    /// Only called when `autoRecordMeetings` is enabled and app is not already recording.
    var onMeetingStart: ((String) -> Void)?

    /// Fires when the meeting ends (audio drops out or meeting app quits).
    /// Only called when `autoRecordMeetings` is enabled and we triggered the start.
    var onMeetingEnd: (() -> Void)?

    // MARK: - Dependencies

    private weak var audio: Audio?

    // MARK: - Configuration

    /// Mic / system audio level below which we consider the channel silent.
    private let speechThreshold: Float = 0.02

    /// Bidirectional speech must persist this long before triggering auto-start.
    private let requiredBidirectionalDuration: TimeInterval = 5

    /// Bidirectional audio must be absent this long before triggering auto-stop.
    private let silenceGracePeriod: TimeInterval = 15

    // MARK: - Internal State

    private var pollingTimer: Timer?
    private var bidirectionalStartTime: Date?
    private var silenceStartTime: Date?

    /// True only when *we* triggered the recording (so we know when to call onMeetingEnd).
    private var didTriggerRecording: Bool = false

    private var workspaceObservers: [Any] = []

    // MARK: - Known Meeting Apps (bundle ID → display name)

    private let meetingApps: [String: String] = [
        "us.zoom.xos":                "Zoom",
        "com.microsoft.teams2":       "Microsoft Teams",
        "com.microsoft.teams":        "Microsoft Teams",
        "com.webex.meetingmanager":   "Webex",
        "com.cisco.webex.meetings":   "Webex",
        "com.apple.FaceTime":         "FaceTime",
        "com.loom.desktop":           "Loom",
    ]

    // MARK: - Initialization

    init(audio: Audio) {
        self.audio = audio
    }

    // MARK: - Lifecycle

    /// Begin watching for meeting apps and audio signals.
    func start() {
        guard workspaceObservers.isEmpty else { return }
        AppLogger.app.info("MeetingDetector started")

        let nc = NSWorkspace.shared.notificationCenter

        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier,
                  let displayName = self?.meetingApps[bundleId]
            else { return }
            Task { @MainActor in
                self?.handleMeetingAppLaunched(displayName: displayName)
            }
        }

        let quitObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier,
                  self?.meetingApps[bundleId] != nil
            else { return }
            Task { @MainActor in
                self?.handleMeetingAppQuit()
            }
        }

        workspaceObservers = [launchObs, quitObs]

        // Catch meeting apps that were already running when the detector started.
        checkForAlreadyRunningMeetingApps()
    }

    /// Stop all detection. Safe to call multiple times.
    func stop() {
        stopPolling()
        audio?.stopMonitoring()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        resetDetectionState()
        isDetecting = false
        activeMeetingApp = nil
        AppLogger.app.info("MeetingDetector stopped")
    }

    // MARK: - App Launch / Quit Handlers

    private func handleMeetingAppLaunched(displayName: String) {
        guard activeMeetingApp == nil else { return } // already tracking one
        AppLogger.app.info("Meeting app launched", ["app": displayName])
        activeMeetingApp = displayName
        isDetecting = true
        audio?.startMonitoring()
        startPolling()
    }

    private func handleMeetingAppQuit() {
        AppLogger.app.info("Meeting app quit", ["app": activeMeetingApp ?? "unknown"])
        stopPolling()
        audio?.stopMonitoring()

        if didTriggerRecording {
            AppLogger.app.info("MeetingDetector: app quit — firing onMeetingEnd")
            if UserDefaults.standard.bool(forKey: "autoRecordMeetings") {
                onMeetingEnd?()
            }
        }

        resetDetectionState()
        isDetecting = false
        activeMeetingApp = nil
    }

    private func checkForAlreadyRunningMeetingApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleId = app.bundleIdentifier,
                  let displayName = meetingApps[bundleId]
            else { continue }
            AppLogger.app.info("MeetingDetector: meeting app already running", ["app": displayName])
            handleMeetingAppLaunched(displayName: displayName)
            return
        }
    }

    // MARK: - Audio Level Polling

    private func startPolling() {
        guard pollingTimer == nil else { return }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func tick() {
        guard let audio = audio else { return }

        // Don't interfere with manually started recordings.
        if audio.isRecording && !didTriggerRecording { return }

        // --- Auto-stop path ---
        if didTriggerRecording && audio.isRecording {
            let micLevel = audio.audioLevel
            let systemLevel = audio.systemAudioLevelHistory.last ?? 0.0
            let hasAudio = micLevel > speechThreshold || systemLevel > speechThreshold

            if hasAudio {
                silenceStartTime = nil
            } else {
                if silenceStartTime == nil { silenceStartTime = Date() }
                let silenceDuration = Date().timeIntervalSince(silenceStartTime!)
                if silenceDuration >= silenceGracePeriod {
                    AppLogger.app.info("MeetingDetector: silence grace period elapsed — stopping")
                    if UserDefaults.standard.bool(forKey: "autoRecordMeetings") {
                        onMeetingEnd?()
                    }
                    resetDetectionState()
                    // Re-start monitoring so detector can re-arm if conversation resumes
                    audio.startMonitoring()
                }
            }
            return
        }

        // --- Auto-start path ---
        let micLevel = audio.audioLevel
        let systemLevel = audio.systemAudioLevelHistory.last ?? 0.0
        let isBidirectional = micLevel > speechThreshold && systemLevel > speechThreshold

        if isBidirectional {
            if bidirectionalStartTime == nil {
                bidirectionalStartTime = Date()
                AppLogger.app.debug("MeetingDetector: bidirectional audio started")
            }
            let duration = Date().timeIntervalSince(bidirectionalStartTime!)
            if duration >= requiredBidirectionalDuration {
                let appName = activeMeetingApp ?? "Meeting"
                AppLogger.app.info("MeetingDetector: sustained bidirectional audio — auto-starting", [
                    "app": appName, "duration": "\(Int(duration))s"
                ])
                didTriggerRecording = true
                bidirectionalStartTime = nil
                if UserDefaults.standard.bool(forKey: "autoRecordMeetings") {
                    onMeetingStart?(appName)
                }
            }
        } else {
            if bidirectionalStartTime != nil {
                AppLogger.app.debug("MeetingDetector: bidirectional audio dropped, resetting")
            }
            bidirectionalStartTime = nil
        }
    }

    // MARK: - Helpers

    private func resetDetectionState() {
        bidirectionalStartTime = nil
        silenceStartTime = nil
        didTriggerRecording = false
    }
}
