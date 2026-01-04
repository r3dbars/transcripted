import Foundation
import AppKit
import AVFoundation
import Combine

// MARK: - Activity Buffer

/// Circular buffer for tracking audio activity samples over a sliding window
private struct ActivityBuffer {
    private var samples: [Bool]  // true = activity detected (mic OR system)
    private var index: Int = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.samples = Array(repeating: false, count: capacity)
    }

    /// Add a sample (true if either mic or system has speech)
    mutating func addSample(hasActivity: Bool) {
        samples[index] = hasActivity
        index = (index + 1) % capacity
    }

    /// Calculate what percentage of the window has activity (0.0-1.0)
    func activityDensity() -> Double {
        let activeCount = samples.filter { $0 }.count
        return Double(activeCount) / Double(capacity)
    }

    /// Clear all samples
    mutating func clear() {
        samples = Array(repeating: false, count: capacity)
        index = 0
    }
}

/// Two-stage meeting detection:
/// 1. Lightweight polling to detect if a meeting app (Zoom, Teams, etc.) is running
/// 2. When meeting app detected, start passive audio monitoring
/// 3. Dual detection: Activity Window (60% of 10s) OR Listen-Only (30s system audio)
@available(macOS 26.0, *)
class MeetingDetector: ObservableObject {
    // MARK: - Published State
    @Published private(set) var isMeetingDetected = false
    @Published private(set) var isMeetingAppRunning = false

    // MARK: - Dependencies
    private weak var audio: Audio?

    // MARK: - Timers
    private var appPollingTimer: Timer?
    private var audioCheckTimer: Timer?

    // MARK: - Passive Audio Monitor
    private var passiveEngine: AVAudioEngine?
    private var passiveSystemCapture: SystemAudioCapture?
    private var currentMicLevel: Float = 0.0
    private var currentSystemLevel: Float = 0.0

    // MARK: - Detection State
    private var activityBuffer: ActivityBuffer?
    private var systemOnlyStartTime: Date?  // For listen-only fallback detection
    private var dismissedUntil: Date?
    private var isPassiveMonitorRunning = false
    private var wasDismissedExplicitly = false  // Track if user clicked dismiss vs auto-cooldown

    // MARK: - Configuration
    /// Audio level threshold for speech detection (0.0-1.0)
    private let speechThreshold: Float = 0.03

    /// Activity window duration (seconds)
    private let activityWindowDuration: TimeInterval = 10.0

    /// Activity density threshold (0.0-1.0) - trigger if this % of window has activity
    private let activityDensityThreshold: Double = 0.60

    /// Listen-only duration before triggering (seconds of system audio without mic)
    private let listenOnlyDuration: TimeInterval = 30.0

    /// Normal cooldown period (seconds)
    private let normalCooldown: TimeInterval = 60

    /// Cooldown after explicit user dismiss (15 minutes)
    private let dismissCooldown: TimeInterval = 900

    /// How often to check for meeting apps (seconds)
    private let appPollingInterval: TimeInterval = 3.0

    /// How often to sample audio levels (seconds)
    private let audioSampleInterval: TimeInterval = 0.5

    // MARK: - Meeting App Bundle IDs
    /// Video conferencing apps to detect (Zoom, Teams, Webex, GoToMeeting, Skype)
    private let meetingAppBundleIds: Set<String> = [
        // Zoom
        "us.zoom.xos",
        // Microsoft Teams (both versions)
        "com.microsoft.teams",
        "com.microsoft.teams2",
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

    deinit {
        stopDetection()
    }

    // MARK: - Detection Control

    /// Start monitoring for meetings (lightweight app polling)
    func startDetection() {
        guard appPollingTimer == nil else { return }

        print("🔍 Meeting detection started (polling for meeting apps)")

        // Stage 1: Poll for meeting apps every few seconds
        appPollingTimer = Timer.scheduledTimer(withTimeInterval: appPollingInterval, repeats: true) { [weak self] _ in
            self?.checkForMeetingApps()
        }

        // Run immediately
        checkForMeetingApps()
    }

    /// Stop all monitoring
    func stopDetection() {
        appPollingTimer?.invalidate()
        appPollingTimer = nil
        stopPassiveAudioMonitor()
        resetState()
        print("🔍 Meeting detection stopped")
    }

    /// User dismissed the meeting prompt - respect cooldown
    /// Uses 15-minute cooldown for explicit dismissals, 60-second for auto-resets
    func dismiss(explicit: Bool = true) {
        let cooldown = explicit ? dismissCooldown : normalCooldown
        dismissedUntil = Date().addingTimeInterval(cooldown)
        isMeetingDetected = false
        wasDismissedExplicitly = explicit
        activityBuffer?.clear()
        systemOnlyStartTime = nil
        print("🔍 Meeting prompt dismissed (explicit: \(explicit)), cooldown for \(Int(cooldown))s")
    }

    // MARK: - Stage 1: Meeting App Detection

    private func checkForMeetingApps() {
        guard let audio = audio else { return }

        // Don't detect while already recording
        guard !audio.isRecording else {
            if isPassiveMonitorRunning {
                stopPassiveAudioMonitor()
            }
            return
        }

        let wasRunning = isMeetingAppRunning
        isMeetingAppRunning = detectMeetingApp()

        if isMeetingAppRunning && !wasRunning {
            // Meeting app just opened - start passive audio monitoring
            print("🔍 Meeting app detected, starting audio monitor")
            startPassiveAudioMonitor()
        } else if !isMeetingAppRunning && wasRunning {
            // Meeting app closed - stop monitoring
            print("🔍 Meeting app closed, stopping audio monitor")
            stopPassiveAudioMonitor()
        }
    }

    private func detectMeetingApp() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications

        for app in runningApps {
            guard let bundleId = app.bundleIdentifier else { continue }

            if meetingAppBundleIds.contains(bundleId) {
                return true
            }
        }

        return false
    }

    // MARK: - Stage 2: Passive Audio Monitoring

    private func startPassiveAudioMonitor() {
        guard !isPassiveMonitorRunning else { return }
        isPassiveMonitorRunning = true

        // Initialize activity buffer (capacity = window duration / sample interval)
        let bufferCapacity = Int(activityWindowDuration / audioSampleInterval)
        activityBuffer = ActivityBuffer(capacity: bufferCapacity)

        // Start mic monitoring
        startMicMonitor()

        // Start system audio monitoring
        startSystemAudioMonitor()

        // Start checking for audio activity
        audioCheckTimer = Timer.scheduledTimer(withTimeInterval: audioSampleInterval, repeats: true) { [weak self] _ in
            self?.checkActivityWindow()
        }
    }

    private func stopPassiveAudioMonitor() {
        guard isPassiveMonitorRunning else { return }
        isPassiveMonitorRunning = false

        // Stop timers
        audioCheckTimer?.invalidate()
        audioCheckTimer = nil

        // Stop mic engine
        if let engine = passiveEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            passiveEngine = nil
        }

        // Stop system audio capture
        passiveSystemCapture?.stop()
        passiveSystemCapture = nil

        // Reset levels and detection state
        currentMicLevel = 0.0
        currentSystemLevel = 0.0
        activityBuffer?.clear()
        activityBuffer = nil
        systemOnlyStartTime = nil

        print("🔍 Passive audio monitor stopped")
    }

    private func startMicMonitor() {
        passiveEngine = AVAudioEngine()
        guard let engine = passiveEngine else { return }

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            print("⚠️ Invalid mic format for passive monitoring")
            return
        }

        // Install lightweight tap just for level detection
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Calculate RMS level
            guard let data = buffer.floatChannelData else { return }
            let channelData = data.pointee
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            var sum: Float = 0
            for i in 0..<frameLength {
                let sample = channelData[i]
                sum += sample * sample
            }

            let rms = sqrt(sum / Float(frameLength))
            let power = 20 * log10(max(rms, 0.00001))
            let level = max(0.0, min(1.0, (power + 60) / 60))

            self.currentMicLevel = level
        }

        do {
            try engine.start()
            print("🎤 Passive mic monitor started")
        } catch {
            print("⚠️ Failed to start passive mic monitor: \(error.localizedDescription)")
        }
    }

    private func startSystemAudioMonitor() {
        passiveSystemCapture = SystemAudioCapture()

        guard let capture = passiveSystemCapture else { return }

        do {
            try capture.start { [weak self] buffer in
                guard let self = self else { return }

                // Calculate RMS level from system audio
                guard let data = buffer.floatChannelData else { return }
                let channelData = data.pointee
                let frameLength = Int(buffer.frameLength)
                guard frameLength > 0 else { return }

                var sum: Float = 0
                for i in 0..<frameLength {
                    let sample = channelData[i]
                    sum += sample * sample
                }

                let rms = sqrt(sum / Float(frameLength))
                let power = 20 * log10(max(rms, 0.00001))
                let level = max(0.0, min(1.0, (power + 60) / 60))

                self.currentSystemLevel = level
            }
            print("🔊 Passive system audio monitor started")
        } catch {
            print("⚠️ Failed to start passive system audio: \(error.localizedDescription)")
        }
    }

    // MARK: - Activity Window Detection

    private func checkActivityWindow() {
        guard let audio = audio else { return }

        // Don't check while recording
        guard !audio.isRecording else { return }

        // Respect cooldown
        if let dismissedUntil = dismissedUntil, Date() < dismissedUntil {
            return
        }

        // Already detected, waiting for user action
        guard !isMeetingDetected else { return }

        // Sample current audio levels
        let micHasSpeech = currentMicLevel > speechThreshold
        let systemHasSpeech = currentSystemLevel > speechThreshold
        let hasActivity = micHasSpeech || systemHasSpeech

        // Add sample to activity buffer
        activityBuffer?.addSample(hasActivity: hasActivity)

        // Primary detection: Activity Window (60%+ of window has activity)
        if let density = activityBuffer?.activityDensity(), density >= activityDensityThreshold {
            print("✅ Meeting detected! Activity density: \(String(format: "%.0f", density * 100))%")
            isMeetingDetected = true
            wasDismissedExplicitly = false
            return
        }

        // Fallback detection: Listen-Only (system audio for 30+ seconds without mic)
        if systemHasSpeech && !micHasSpeech {
            if systemOnlyStartTime == nil {
                systemOnlyStartTime = Date()
                print("🔍 System audio only detected, starting listen-only timer")
            } else {
                let duration = Date().timeIntervalSince(systemOnlyStartTime!)
                if duration >= listenOnlyDuration {
                    print("✅ Meeting detected! Listen-only for \(String(format: "%.0f", duration))s")
                    isMeetingDetected = true
                    wasDismissedExplicitly = false
                }
            }
        } else if micHasSpeech {
            // User spoke, reset listen-only timer (they're actively participating)
            systemOnlyStartTime = nil
        }
        // Note: If neither has speech, keep systemOnlyStartTime as-is (brief silence in meeting)
    }

    private func resetState() {
        isMeetingAppRunning = false
        isMeetingDetected = false
        activityBuffer?.clear()
        activityBuffer = nil
        systemOnlyStartTime = nil
        currentMicLevel = 0.0
        currentSystemLevel = 0.0
        wasDismissedExplicitly = false
    }
}
