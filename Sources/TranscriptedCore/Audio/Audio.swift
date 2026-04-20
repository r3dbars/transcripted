import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import AppKit
import CoreAudio
import Combine

/// Status of system audio capture for UI feedback
/// Used to show warnings when device switching or audio loss occurs
public enum SystemAudioStatus: Equatable {
    case unknown        // Not recording
    case healthy        // Receiving audio data normally
    case reconnecting   // Device change detected, recovering (~200ms)
    case silent         // Prolonged silence (>10s) - might indicate capture issue
    case failed         // Recovery failed - system audio unavailable

    public var isWarning: Bool {
        switch self {
        case .silent, .failed: return true
        default: return false
        }
    }

    public var isRecovering: Bool {
        self == .reconnecting
    }

    public var displayText: String {
        switch self {
        case .unknown: return ""
        case .healthy: return ""
        case .reconnecting: return "Reconnecting..."
        case .silent: return "System audio silent"
        case .failed: return "System audio unavailable \u{2014} enable System Audio Recording for Transcripted in System Settings"
        }
    }
}

/// Main audio recording class that captures microphone and system audio
/// Note: This class does NOT use @MainActor because it manages AVAudioEngine
/// which requires synchronous access from audio tap callbacks on audio threads.
/// UI updates are dispatched to main thread explicitly.
/// The mutable audio-capture state is guarded by dedicated queues, locks, and
/// explicit main-thread dispatch where needed, so Dispatch callbacks can safely
/// hold weak references to this object.
public class Audio: ObservableObject, @unchecked Sendable {
    @Published public var isRecording: Bool = false
    @Published public private(set) var isMonitoring: Bool = false  // Lightweight level metering without file recording
    private var isStarting: Bool = false  // Prevents double-start during async setup
    @Published public var audioLevel: Float = 0.0
    @Published public var recordingDuration: TimeInterval = 0.0
    @Published public var audioLevelHistory: [Float] = Array(repeating: 0.0, count: 15)
    @Published public var systemAudioLevelHistory: [Float] = Array(repeating: 0.0, count: 15)
    @Published public var error: String?
    @Published public var systemAudioStatus: SystemAudioStatus = .unknown

    // Silence detection for "Still Recording?" prompt
    @Published public var silenceDuration: TimeInterval = 0.0  // How long we've been in silence
    @Published public var isSilent: Bool = false  // True when audio below threshold
    let silenceThreshold: Float = 0.02  // Audio level below this = silence
    var lastNonSilentTime: Date?

    // Audio file URLs - returned when recording stops
    @Published public var micAudioFileURL: URL?
    @Published public var systemAudioFileURL: URL?

    // Base mic URL set at recording start. If recovery creates additional mic WAV
    // segments, this remains the anchor used to name any merged output passed to
    // the pipeline on stop.
    var originalMicAudioFileURL: URL?
    private var _micSegments: [MicRecordingSegment] = []
    private let micSegmentsLock = NSLock()
    var micSegments: [MicRecordingSegment] {
        get { micSegmentsLock.lock(); defer { micSegmentsLock.unlock() }; return _micSegments }
        set { micSegmentsLock.lock(); defer { micSegmentsLock.unlock() }; _micSegments = newValue }
    }
    func appendMicSegment(_ segment: MicRecordingSegment) {
        micSegmentsLock.lock()
        defer { micSegmentsLock.unlock() }
        _micSegments.append(segment)
    }

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
    /// Thread-safe: mutated from main thread (wake handler) + background thread (device recovery)
    private var _recordingGaps: [AudioGap] = []
    private let recordingGapsLock = NSLock()
    var recordingGaps: [AudioGap] {
        get { recordingGapsLock.lock(); defer { recordingGapsLock.unlock() }; return _recordingGaps }
        set { recordingGapsLock.lock(); defer { recordingGapsLock.unlock() }; _recordingGaps = newValue }
    }
    func appendRecordingGap(_ gap: AudioGap) {
        recordingGapsLock.lock(); defer { recordingGapsLock.unlock() }
        _recordingGaps.append(gap)
    }

    /// Count of device switches during this recording
    /// Thread-safe: reset on main thread, incremented on background recovery thread
    private var _deviceSwitchCount: Int = 0
    private let deviceSwitchCountLock = NSLock()
    var deviceSwitchCount: Int {
        get { deviceSwitchCountLock.lock(); defer { deviceSwitchCountLock.unlock() }; return _deviceSwitchCount }
        set { deviceSwitchCountLock.lock(); defer { deviceSwitchCountLock.unlock() }; _deviceSwitchCount = newValue }
    }

    /// Timestamp when system started sleeping (for gap calculation)
    var sleepTimestamp: Date?

    /// Create a snapshot of recording health info for transcript metadata
    /// Call this when stopping recording to capture health metrics.
    /// `systemAudioCapture` stays type-erased here; the `RecordingHealthInfo`
    /// factory downcasts under `#available(macOS 14.2, *)` internally.
    public func createHealthInfo() -> RecordingHealthInfo {
        return RecordingHealthInfo.from(audio: self, systemCapture: systemAudioCapture)
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
    private var _recoveryAttemptCount: Int = 0
    private let recoveryAttemptCountLock = NSLock()
    var recoveryAttemptCount: Int {
        get {
            recoveryAttemptCountLock.lock()
            defer { recoveryAttemptCountLock.unlock() }
            return _recoveryAttemptCount
        }
        set {
            recoveryAttemptCountLock.lock()
            defer { recoveryAttemptCountLock.unlock() }
            _recoveryAttemptCount = newValue
        }
    }
    // Recording session generation - increments on each start/stop so delayed
    // recovery work from an old session cannot restart a newer one.
    private var _recordingSessionGeneration: UInt64 = 0
    private let recordingSessionGenerationLock = NSLock()
    var recordingSessionGeneration: UInt64 {
        get {
            recordingSessionGenerationLock.lock()
            defer { recordingSessionGenerationLock.unlock() }
            return _recordingSessionGeneration
        }
        set {
            recordingSessionGenerationLock.lock()
            defer { recordingSessionGenerationLock.unlock() }
            _recordingSessionGeneration = newValue
        }
    }
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
    var systemAudioCapture: (any SystemAudioCaptureEngine & Sendable)?

    // Audio file recording
    var systemAudioFile: AVAudioFile?
    var micAudioFile: AVAudioFile?
    let systemAudioFileQueue = DispatchQueue(label: "SystemAudioFileWrite", qos: .utility)
    let micAudioFileQueue = DispatchQueue(label: "MicAudioFileWrite", qos: .utility)

    // Audio format conversion (multi-channel to mono)
    // Thread-safe: written during init + device recovery, read during mic buffer handling
    private var _monoOutputFormat: AVAudioFormat?
    private var _inputChannelCount: AVAudioChannelCount = 1
    private let formatLock = NSLock()
    var monoOutputFormat: AVAudioFormat? {
        get { formatLock.lock(); defer { formatLock.unlock() }; return _monoOutputFormat }
        set { formatLock.lock(); defer { formatLock.unlock() }; _monoOutputFormat = newValue }
    }
    var inputChannelCount: AVAudioChannelCount {
        get { formatLock.lock(); defer { formatLock.unlock() }; return _inputChannelCount }
        set { formatLock.lock(); defer { formatLock.unlock() }; _inputChannelCount = newValue }
    }

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

    // Disk space check counter — checked every 150 timer ticks (~30s at 0.2s interval)
    var diskCheckCounter: Int = 0

    // Callback for when recording completes
    public var onRecordingComplete: ((URL?, URL?) -> Void)?

    // Callback for when recording starts (used for pre-loading models)
    public var onRecordingStart: (() -> Void)?

    // MARK: - Live PCM buffer hooks (host app live-preview integration)
    //
    // These callbacks let an embedder tap the raw PCM buffers as they arrive
    // from CoreAudio, in parallel with the WAV file writes. Used by the app to
    // drive live dual-channel transcription preview via FluidAudio's
    // StreamingEouAsrManager without a second audio engine.
    //
    // Threading: fired on the audio thread (same thread as the tap callback).
    // Consumers MUST NOT do I/O, locks, or allocations on this thread — copy
    // the buffer and dispatch to a worker queue. Matching the convention of
    // `onRecordingComplete`, optional reads are unsynchronized: set the hook
    // once before `start()` and do not reassign during recording.
    //
    // Mic buffers arrive in the hardware's native format (possibly multi-
    // channel at 44.1/48/96 kHz). System buffers arrive in the aggregate-
    // device format (typically stereo at 48 kHz). Callers are responsible
    // for any downmix/resample they need.
    //
    // Copy semantics:
    //   onMicPCMBuffer  — raw reference from the CoreAudio tap; caller MUST copy before async dispatch.
    //   onSystemPCMBuffer — already deep-copied (bufferListNoCopy semantics); safe to retain as-is.
    public var onMicPCMBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onSystemPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Filesystem layout used for writing raw mic/system WAV captures.
    /// Embedders can redirect captures by passing a custom `CoreStoragePaths` at init.
    let paths: CoreStoragePaths

    public init(paths: CoreStoragePaths = .default) {
        self.paths = paths
    }

    func ensureCaptureInfrastructureConfigured() {
        guard systemAudioCapture == nil else { return }

        // Initialize system audio capture using the macOS 26+ audio-only
        // ScreenCaptureKit path. This keeps meeting audio on the narrower
        // "System Audio Recording" permission tier and avoids restart-required
        // Screen Recording flows.
        let capture = SCKAudioCapture()
        systemAudioCapture = capture
        systemAudioCancellable = capture.errorMessagePublisher
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
                    self.appendRecordingGap(gap)
                    AppLogger.audio.info("Recorded sleep/wake gap", ["gap": gap.description])
                }
                self.sleepTimestamp = nil

                // Proactively trigger mic recovery instead of waiting for the 3-5s watchdog delay
                let sessionGeneration = self.recordingSessionGeneration
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self, self.isRecording else { return }
                    self.recoverFromDeviceChange(sessionGeneration: sessionGeneration)
                }
            }
        }
    }

    @discardableResult
    func ensureEngineInitialized() throws -> (AVAudioEngine, AVAudioInputNode) {
        // Delay AVAudioEngine/input-node access until monitoring or recording
        // actually begins. Launch-time warmup can construct Audio long before
        // the user has explicitly asked to record anything.
        if engine == nil {
            engine = AVAudioEngine()
        }

        if inputNode == nil, let engine {
            inputNode = engine.inputNode
            AppLogger.audioMic.info("Using system default microphone")
        }

        guard let engine, let inputNode else {
            throw NSError(
                domain: "Audio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"]
            )
        }

        return (engine, inputNode)
    }

    func prepareForNewRecordingStart() {
        error = nil
        isMicRecovering = false
        systemBufferCount = 0  // Reset debug counter (lock-protected)
        resetSilenceTracking()  // Start fresh silence tracking
        systemAudioStatus = .healthy  // Assume healthy until we hear otherwise
        systemAudioSilenceStart = nil  // Reset system audio silence tracking
        recordingSessionGeneration &+= 1

        // Reset capture artifacts so a previous session cannot make a new start
        // look ready before the fresh mic/system files exist.
        originalMicAudioFileURL = nil
        micAudioFileURL = nil
        systemAudioFileURL = nil

        // Reset health tracking for new recording session
        recordingGaps = []
        deviceSwitchCount = 0
        recoveryAttemptCount = 0
        sleepTimestamp = nil
        lastRecoveryTime = nil
        consecutiveMicWriteErrors = 0
        consecutiveSystemWriteErrors = 0
        systemAudioFailed = false
        micSegments = []
    }

    // MARK: - Start Recording

    public func start() {
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

        // Gate duplicate start requests while the permission prompt is open or
        // the async recorder setup is still being scheduled.
        isStarting = true

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
                        // Permission denied — already on main via the outer dispatch
                        self.error = "Microphone permission required. Go to System Settings \u{2192} Privacy & Security \u{2192} Microphone and enable Transcripted, then try again."
                        self.isStarting = false
                    }
                }
            }
            return
        } else if microphoneStatus == .denied {
            // Permission explicitly denied
            DispatchQueue.main.async {
                self.error = "Microphone access denied. Go to System Settings \u{2192} Privacy & Security \u{2192} Microphone and enable Transcripted."
                self.isStarting = false
            }
            return
        }
        prepareForNewRecordingStart()

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
                    self.error = "Recording failed to start: \(error.localizedDescription). Try quitting and reopening Transcripted."
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
        prepareForNewRecordingStart()

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
                    self.error = "Recording failed to start: \(error.localizedDescription). Try quitting and reopening Transcripted."
                    self.isRecording = false
                    self.isStarting = false
                    self.stop()
                }
            }
        }
    }

    // MARK: - Stop Recording

    public func stop() {
        recordingSessionGeneration &+= 1
        if let engine, let inputNode {
            AppLogger.audio.info("Stopping audio capture")

            // Stop audio engine FIRST (prevents new buffers from arriving)
            if engine.isRunning {
                inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }

        // Stop system audio capture
        systemAudioCapture?.stop()

        // Use the original mic URL (set at recording start), not the potentially-overwritten
        // recovery URL. Device recovery creates a new WAV segment but the original file
        // contains the bulk of the recording.
        let primaryMicURL = originalMicAudioFileURL ?? micAudioFileURL
        let micSegments = self.micSegments
        let finalSystemURL = systemAudioFileURL

        // Update UI immediately - don't wait for file cleanup
        // This makes the app feel instant
        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
            self.systemAudioStatus = .unknown  // Reset status when not recording
            self.stopTimer()
            self.stopWatchdog()
            self.isMicRecovering = false
            NSSound(named: "Pop")?.play()
        }

        // Close audio files asynchronously - use DispatchGroup to coordinate
        // This does NOT block the main thread
        let cleanupGroup = DispatchGroup()

        cleanupGroup.enter()
        micAudioFileQueue.async { [weak self] in
            if let self, self.micAudioFile != nil {
                self.micAudioFile = nil
                AppLogger.audioMic.info("Audio file closed", ["file": primaryMicURL?.lastPathComponent ?? self.micAudioFileURL?.lastPathComponent ?? "unknown"])
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
        cleanupGroup.notify(queue: .global(qos: .utility)) { [weak self] in
            guard let self else { return }
            let finalMicURL = self.finalizeMicRecording(primaryURL: primaryMicURL, segments: micSegments)
            DispatchQueue.main.async {
                self.originalMicAudioFileURL = nil
                self.micSegments = []
                self.micAudioFileURL = finalMicURL
                self.onRecordingComplete?(finalMicURL, finalSystemURL)
            }
        }
    }

    // MARK: - Audio Level Monitoring (no file recording)

    /// Start lightweight level metering for mic + system audio without recording to files.
    /// Used by MeetingDetector to detect bidirectional speech before full recording starts.
    /// Automatically stops when `start()` is called for full recording.
    public func startMonitoring() {
        guard !isMonitoring, !isRecording, !isStarting else { return }
        ensureCaptureInfrastructureConfigured()

        let engine: AVAudioEngine
        let inputNode: AVAudioInputNode
        do {
            (engine, inputNode) = try ensureEngineInitialized()
        } catch {
            AppLogger.audio.warning("Failed to initialize monitoring engine", ["error": error.localizedDescription])
            return
        }

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
        if let capture = systemAudioCapture {
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
    public func stopMonitoring() {
        guard isMonitoring else { return }

        AppLogger.audio.info("Stopping audio level monitoring")

        if let engine = engine, let inputNode = inputNode {
            if engine.isRunning {
                inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }

        systemAudioCapture?.stopSync()  // Synchronous — avoids race where delayed cleanup destroys the next recording's tap

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
        timer?.invalidate()
        watchdogTimer?.invalidate()
        systemAudioCancellable?.cancel()
        systemAudioCapture?.stopSync()

        if let engine, let inputNode, engine.isRunning {
            inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}

// MARK: - AudioCaptureEngine conformance
// Empty extension — protocol signatures match Audio's existing public API exactly.
// Added as part of Step 8 protocol wiring (merge-plan §5.1).

extension Audio: AudioCaptureEngine {}
