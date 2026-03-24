import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import AppKit
import CoreAudio
import Combine
import QuartzCore

/// Status of system audio capture for UI feedback
/// Used to show warnings when device switching or audio loss occurs
enum SystemAudioStatus: Equatable {
    case unknown        // Not recording
    case healthy        // Receiving audio data normally
    case reconnecting   // Device change detected, recovering (~200ms)
    case silent         // Prolonged silence (>10s) - might indicate capture issue
    case failed         // Recovery failed - system audio unavailable

    var isWarning: Bool {
        switch self {
        case .silent, .failed: return true
        default: return false
        }
    }

    var isRecovering: Bool {
        self == .reconnecting
    }

    var displayText: String {
        switch self {
        case .unknown: return ""
        case .healthy: return ""
        case .reconnecting: return "Reconnecting..."
        case .silent: return "System audio silent"
        case .failed: return "System audio unavailable"
        }
    }
}

/// Main audio recording class that captures microphone and system audio
/// Note: This class does NOT use @MainActor because it manages AVAudioEngine
/// which requires synchronous access from audio tap callbacks on audio threads.
/// UI updates are dispatched to main thread explicitly.
@available(macOS 26.0, *)
class Audio: ObservableObject {
    @Published var isRecording: Bool = false
    @Published private(set) var isMonitoring: Bool = false  // Lightweight level metering without file recording
    private var isStarting: Bool = false  // Prevents double-start during async setup
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0.0
    @Published var audioLevelHistory: [Float] = Array(repeating: 0.0, count: 15)
    @Published var systemAudioLevelHistory: [Float] = Array(repeating: 0.0, count: 15)
    @Published var error: String?
    @Published var systemAudioStatus: SystemAudioStatus = .unknown

    // Silence detection for "Still Recording?" prompt
    @Published var silenceDuration: TimeInterval = 0.0  // How long we've been in silence
    @Published var isSilent: Bool = false  // True when audio below threshold
    let silenceThreshold: Float = 0.02  // Audio level below this = silence
    var lastNonSilentTime: Date?

    // Audio file URLs - returned when recording stops
    @Published var micAudioFileURL: URL?
    @Published var systemAudioFileURL: URL?

    // Original mic URL set at recording start — never overwritten by device recovery.
    // Device recovery creates a new WAV segment and updates micAudioFileURL (the write target),
    // but the original file contains the bulk of the recording and is what the pipeline should use.
    var originalMicAudioFileURL: URL?

    // MARK: - Recording Health Tracking (Phase 1: Sleep/Wake + Gap Logging)

    /// Simple struct to track audio gaps (sleep/wake, device switches)
    struct AudioGap {
        let start: Date
        let duration: TimeInterval
        let reason: String

        var description: String {
            let durationStr = String(format: "%.1f", duration)
            return "\(reason): \(durationStr)s"
        }
    }

    /// Gaps detected during recording (sleep/wake, device switches)
    var recordingGaps: [AudioGap] = []

    /// Count of device switches during this recording
    var deviceSwitchCount: Int = 0

    /// Timestamp when system started sleeping (for gap calculation)
    var sleepTimestamp: Date?

    /// Create a snapshot of recording health info for transcript metadata
    /// Call this when stopping recording to capture health metrics
    func createHealthInfo() -> RecordingHealthInfo {
        // Cast the type-erased systemAudioCapture to get buffer stats
        let systemCapture = systemAudioCapture as? SystemAudioCapture
        return RecordingHealthInfo.from(audio: self, systemCapture: systemCapture)
    }

    var engine: AVAudioEngine?
    var inputNode: AVAudioInputNode?
    var startTime: Date?
    var timer: Timer?

    // Device change watchdog - thread-safe access via lock
    // Uses CACurrentMediaTime() (monotonic clock) to avoid false triggers after sleep/wake.
    // Matches SystemAudioCapture.swift which also uses CACurrentMediaTime().
    private var _lastBufferTime: CFTimeInterval = CACurrentMediaTime()
    private let lastBufferTimeLock = NSLock()
    var lastBufferTime: CFTimeInterval {
        get {
            lastBufferTimeLock.lock()
            defer { lastBufferTimeLock.unlock() }
            return _lastBufferTime
        }
        set {
            lastBufferTimeLock.lock()
            defer { lastBufferTimeLock.unlock() }
            _lastBufferTime = newValue
        }
    }
    var watchdogTimer: Timer?

    // Mic recovery guard (prevents concurrent recovery attempts)
    // Thread-safe: accessed from watchdog (main) and recovery (background) threads
    private var _isMicRecovering: Bool = false
    private let micRecoveryLock = NSLock()
    var isMicRecovering: Bool {
        get {
            micRecoveryLock.lock()
            defer { micRecoveryLock.unlock() }
            return _isMicRecovering
        }
        set {
            micRecoveryLock.lock()
            defer { micRecoveryLock.unlock() }
            _isMicRecovering = newValue
        }
    }
    var lastRecoveryTime: Date?
    let maxRecoveryAttempts = 5
    let recoveryCooldown: TimeInterval = 5.0  // Min seconds between recovery attempts

    // Write error tracking — stop writing after repeated failures
    // Thread-safe: accessed from audio file queues (background) and reset from start() (main thread)
    private var _consecutiveMicWriteErrors: Int = 0
    private var _consecutiveSystemWriteErrors: Int = 0
    private let writeErrorLock = NSLock()
    var consecutiveMicWriteErrors: Int {
        get { writeErrorLock.lock(); defer { writeErrorLock.unlock() }; return _consecutiveMicWriteErrors }
        set { writeErrorLock.lock(); defer { writeErrorLock.unlock() }; _consecutiveMicWriteErrors = newValue }
    }
    var consecutiveSystemWriteErrors: Int {
        get { writeErrorLock.lock(); defer { writeErrorLock.unlock() }; return _consecutiveSystemWriteErrors }
        set { writeErrorLock.lock(); defer { writeErrorLock.unlock() }; _consecutiveSystemWriteErrors = newValue }
    }
    let maxConsecutiveWriteErrors = 10

    // Persistent flag: system audio capture failed, recording mic only
    @Published var systemAudioFailed: Bool = false

    // System audio capture
    var systemAudioCapture: Any? // SystemAudioCapture (macOS 14.2+)

    // Audio file recording
    var systemAudioFile: AVAudioFile?
    var micAudioFile: AVAudioFile?
    let systemAudioFileQueue = DispatchQueue(label: "SystemAudioFileWrite", qos: .utility)
    let micAudioFileQueue = DispatchQueue(label: "MicAudioFileWrite", qos: .utility)

    // Audio format conversion (multi-channel to mono)
    var monoOutputFormat: AVAudioFormat?
    var inputChannelCount: AVAudioChannelCount = 1

    // Throttle system audio visualizer updates (skip every other callback)
    // Protected by systemLevelLock — accessed from I/O callback thread
    var systemLevelUpdateCounter: Int = 0
    let systemLevelLock = NSLock()

    // Debug: Track system audio buffer count
    // Protected by systemBufferCountLock — accessed from I/O callback dispatch and main thread
    private var _systemBufferCount: Int = 0
    private let systemBufferCountLock = NSLock()
    var systemBufferCount: Int {
        get {
            systemBufferCountLock.lock()
            defer { systemBufferCountLock.unlock() }
            return _systemBufferCount
        }
        set {
            systemBufferCountLock.lock()
            defer { systemBufferCountLock.unlock() }
            _systemBufferCount = newValue
        }
    }

    // System audio status observation
    private var systemAudioCancellable: AnyCancellable?
    // Protected by systemSilenceLock — written from callback thread, reset on main thread
    private var _systemAudioSilenceStart: Date?
    private let systemSilenceLock = NSLock()
    var systemAudioSilenceStart: Date? {
        get {
            systemSilenceLock.lock()
            defer { systemSilenceLock.unlock() }
            return _systemAudioSilenceStart
        }
        set {
            systemSilenceLock.lock()
            defer { systemSilenceLock.unlock() }
            _systemAudioSilenceStart = newValue
        }
    }
    let systemAudioSilenceThreshold: TimeInterval = 10  // 10s of silence = warning

    // Sleep/wake notification observers (stored for cleanup in deinit)
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // Callback for when recording completes
    var onRecordingComplete: ((URL?, URL?) -> Void)?

    // Callback for when recording starts (used for pre-loading models)
    var onRecordingStart: (() -> Void)?

    init() {
        setup()
    }

    private func setup() {
        engine = AVAudioEngine()
        inputNode = engine?.inputNode

        AppLogger.audioMic.info("Using system default microphone")

        // Request microphone permission
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    self.error = "Microphone permission denied"
                }
            }
        }

        // Initialize system audio capture (macOS 14.2+)
        let capture = SystemAudioCapture()
        systemAudioCapture = capture

        // Observe SystemAudioCapture's errorMessage to update status
        // This allows the UI to react to device changes and failures
        systemAudioCancellable = capture.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorMessage in
                self?.updateSystemAudioStatus(fromError: errorMessage)
            }

        // MARK: - Sleep/Wake Observers (Phase 1: Invisible Reliability)
        // Handle macOS sleep/wake to prevent AVAudioEngine crashes and log gaps

        sleepObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            AppLogger.audio.info("System sleeping during recording - preparing for gap")
            self.sleepTimestamp = Date()
        }

        wakeObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            AppLogger.audio.info("System waking - waiting for HAL stabilization")

            // Wait 500ms for audio subsystem to stabilize before continuing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.isRecording else { return }

                // Record the gap
                if let sleepStart = self.sleepTimestamp {
                    let gap = AudioGap(
                        start: sleepStart,
                        duration: Date().timeIntervalSince(sleepStart),
                        reason: "Sleep/wake"
                    )
                    self.recordingGaps.append(gap)
                    AppLogger.audio.info("Recorded sleep/wake gap", ["gap": gap.description])
                }
                self.sleepTimestamp = nil

                // Proactively trigger mic recovery instead of waiting for the 3-5s watchdog delay
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self, self.isRecording else { return }
                    self.recoverFromDeviceChange()
                }
            }
        }
    }

    // MARK: - Start Recording

    func start() {
        guard !isRecording, !isStarting else {
            AppLogger.audio.warning("Already recording or starting, ignoring duplicate start request")
            return
        }

        // Stop monitoring if active — full recording takes over the engine and taps
        if isMonitoring {
            stopMonitoring()
        }

        // Pre-flight validation checks
        let validationResult = RecordingValidator.validateRecordingConditions()
        guard validationResult.isValid else {
            AppLogger.audio.error("Pre-flight check failed", ["error": validationResult.errorMessage ?? "Unknown error"])
            error = validationResult.errorMessage
            return
        }

        // Check microphone permission and request if not determined
        // This allows users who skipped permission during onboarding to grant it at record time
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        // Permission granted, proceed with start
                        self.startAudioCaptureAsync()
                    } else {
                        // Permission denied
                        DispatchQueue.main.async {
                            self.error = "Microphone access is required to record. Please grant permission in System Settings."
                            self.isStarting = false
                        }
                    }
                }
            }
            return
        } else if microphoneStatus == .denied {
            // Permission explicitly denied
            DispatchQueue.main.async {
                self.error = "Microphone access denied. Please grant permission in System Settings."
                self.isStarting = false
            }
            return
        }

        // Set isStarting to prevent double-start during async setup
        isStarting = true
        error = nil
        systemBufferCount = 0  // Reset debug counter (lock-protected)
        resetSilenceTracking()  // Start fresh silence tracking
        systemAudioStatus = .healthy  // Assume healthy until we hear otherwise
        systemAudioSilenceStart = nil  // Reset system audio silence tracking

        // Reset health tracking for new recording session
        recordingGaps = []
        deviceSwitchCount = 0
        sleepTimestamp = nil
        lastRecoveryTime = nil
        consecutiveMicWriteErrors = 0
        consecutiveSystemWriteErrors = 0
        systemAudioFailed = false

        AppLogger.audio.info("Starting audio capture")

        onRecordingStart?()

        Task {
            do {
                try await startAudioCapture()
                await MainActor.run {
                    self.isRecording = true
                    self.isStarting = false
                }
            } catch {
                await MainActor.run {
                    self.error = "Failed to start recording: \(error.localizedDescription)"
                    self.isRecording = false
                    self.isStarting = false
                    self.stop()
                }
            }
        }
    }

    /// Helper method to start audio capture asynchronously
    /// Used when permission is already granted or after permission request completes
    private func startAudioCaptureAsync() {
        // Set isStarting to prevent double-start during async setup
        isStarting = true
        error = nil
        systemBufferCount = 0  // Reset debug counter (lock-protected)
        resetSilenceTracking()  // Start fresh silence tracking
        systemAudioStatus = .healthy  // Assume healthy until we hear otherwise
        systemAudioSilenceStart = nil  // Reset system audio silence tracking

        // Reset health tracking for new recording session
        recordingGaps = []
        deviceSwitchCount = 0
        sleepTimestamp = nil
        lastRecoveryTime = nil
        consecutiveMicWriteErrors = 0
        consecutiveSystemWriteErrors = 0
        systemAudioFailed = false

        AppLogger.audio.info("Starting audio capture")

        onRecordingStart?()

        Task {
            do {
                try await startAudioCapture()
                await MainActor.run {
                    self.isRecording = true
                    self.isStarting = false
                }
            } catch {
                await MainActor.run {
                    self.error = "Failed to start recording: \(error.localizedDescription)"
                    self.isRecording = false
                    self.isStarting = false
                    self.stop()
                }
            }
        }
    }

    // MARK: - Stop Recording

    func stop() {
        guard let engine = engine, let inputNode = inputNode else {
            // Ensure flag reset even on guard failure
            isRecording = false
            return
        }

        AppLogger.audio.info("Stopping audio capture")

        // Stop audio engine FIRST (prevents new buffers from arriving)
        if engine.isRunning {
            inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        // Stop system audio capture
        if let capture = systemAudioCapture as? SystemAudioCapture {
            capture.stop()
        }

        // Use the original mic URL (set at recording start), not the potentially-overwritten
        // recovery URL. Device recovery creates a new WAV segment but the original file
        // contains the bulk of the recording.
        let finalMicURL = originalMicAudioFileURL ?? micAudioFileURL
        let finalSystemURL = systemAudioFileURL

        // Update UI immediately - don't wait for file cleanup
        // This makes the app feel instant
        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
            self.systemAudioStatus = .unknown  // Reset status when not recording
            self.stopTimer()
            self.stopWatchdog()
            NSSound(named: "Pop")?.play()
        }

        // Close audio files asynchronously - use DispatchGroup to coordinate
        // This does NOT block the main thread
        let cleanupGroup = DispatchGroup()

        cleanupGroup.enter()
        micAudioFileQueue.async { [weak self] in
            if self?.micAudioFile != nil {
                self?.micAudioFile = nil
                AppLogger.audioMic.info("Audio file closed", ["file": finalMicURL?.lastPathComponent ?? "unknown"])
            }
            cleanupGroup.leave()
        }

        cleanupGroup.enter()
        systemAudioFileQueue.async { [weak self] in
            if self?.systemAudioFile != nil {
                self?.systemAudioFile = nil
                AppLogger.audioSystem.info("Audio file closed", ["file": finalSystemURL?.lastPathComponent ?? "unknown"])
            }
            cleanupGroup.leave()
        }

        // Notify completion AFTER files are closed (but don't block main thread waiting)
        cleanupGroup.notify(queue: .main) { [weak self] in
            self?.originalMicAudioFileURL = nil
            self?.onRecordingComplete?(finalMicURL, finalSystemURL)
        }
    }

    // MARK: - Audio Level Monitoring (no file recording)

    /// Start lightweight level metering for mic + system audio without recording to files.
    /// Used by MeetingDetector to detect bidirectional speech before full recording starts.
    /// Automatically stops when `start()` is called for full recording.
    func startMonitoring() {
        guard !isMonitoring, !isRecording, !isStarting else { return }
        guard let engine = engine, let inputNode = inputNode else { return }

        AppLogger.audio.info("Starting audio level monitoring")

        let hardwareFormat = inputNode.inputFormat(forBus: 1)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            AppLogger.audio.warning("Cannot start monitoring — invalid input format")
            return
        }

        // Install mic tap for level metering only (no file writing)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.calculateLevel(buffer: buffer)
        }

        do {
            try engine.start()
        } catch {
            AppLogger.audio.warning("Failed to start monitoring engine", ["error": error.localizedDescription])
            inputNode.removeTap(onBus: 0)
            return
        }

        // Start system audio capture for level metering only (no file writing)
        if let capture = systemAudioCapture as? SystemAudioCapture {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try capture.prepare()
                    try capture.start { [weak self] systemBuffer in
                        self?.calculateSystemLevel(buffer: systemBuffer)
                    }
                    AppLogger.audioSystem.info("System audio monitoring started")
                } catch {
                    AppLogger.audioSystem.warning("System audio monitoring unavailable", ["error": error.localizedDescription])
                    // Mic monitoring still works — system audio is optional
                }
            }
        }

        DispatchQueue.main.async {
            self.isMonitoring = true
        }
    }

    /// Stop level metering. Called automatically before `start()` begins full recording.
    func stopMonitoring() {
        guard isMonitoring else { return }

        AppLogger.audio.info("Stopping audio level monitoring")

        if let engine = engine, let inputNode = inputNode {
            if engine.isRunning {
                inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }

        if let capture = systemAudioCapture as? SystemAudioCapture {
            capture.stopSync()  // Synchronous — avoids race where delayed cleanup destroys the next recording's tap
        }

        DispatchQueue.main.async {
            self.isMonitoring = false
            self.audioLevel = 0.0
            self.audioLevelHistory = Array(repeating: 0.0, count: 15)
            self.systemAudioLevelHistory = Array(repeating: 0.0, count: 15)
        }
    }

    deinit {
        // Remove sleep/wake observers to prevent leaks
        if let observer = sleepObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stop()
    }
}
