import Foundation
@preconcurrency import AVFoundation
import AppKit
import CoreAudio
import Combine

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
    private let silenceThreshold: Float = 0.02  // Audio level below this = silence
    private var lastNonSilentTime: Date?

    // Audio file URLs - returned when recording stops
    @Published var micAudioFileURL: URL?
    @Published var systemAudioFileURL: URL?

    // Original mic URL set at recording start — never overwritten by device recovery.
    // Device recovery creates a new WAV segment and updates micAudioFileURL (the write target),
    // but the original file contains the bulk of the recording and is what the pipeline should use.
    private var originalMicAudioFileURL: URL?

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
    private(set) var recordingGaps: [AudioGap] = []

    /// Count of device switches during this recording
    private(set) var deviceSwitchCount: Int = 0

    /// Timestamp when system started sleeping (for gap calculation)
    private var sleepTimestamp: Date?

    /// Create a snapshot of recording health info for transcript metadata
    /// Call this when stopping recording to capture health metrics
    func createHealthInfo() -> RecordingHealthInfo {
        // Cast the type-erased systemAudioCapture to get buffer stats
        let systemCapture = systemAudioCapture as? SystemAudioCapture
        return RecordingHealthInfo.from(audio: self, systemCapture: systemCapture)
    }

    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var startTime: Date?
    private var timer: Timer?

    // Device change watchdog - thread-safe access via lock
    private var _lastBufferTime: Date = Date()
    private let lastBufferTimeLock = NSLock()
    private var lastBufferTime: Date {
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
    private var watchdogTimer: Timer?

    // Mic recovery guard (prevents concurrent recovery attempts)
    // Thread-safe: accessed from watchdog (main) and recovery (background) threads
    private var _isMicRecovering: Bool = false
    private let micRecoveryLock = NSLock()
    private var isMicRecovering: Bool {
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
    private var lastRecoveryTime: Date?
    private let maxRecoveryAttempts = 5
    private let recoveryCooldown: TimeInterval = 5.0  // Min seconds between recovery attempts

    // Write error tracking — stop writing after repeated failures
    private var consecutiveMicWriteErrors: Int = 0
    private var consecutiveSystemWriteErrors: Int = 0
    private let maxConsecutiveWriteErrors = 10

    // System audio capture
    private var systemAudioCapture: Any? // SystemAudioCapture (macOS 14.2+)

    // Audio file recording
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    private let systemAudioFileQueue = DispatchQueue(label: "SystemAudioFileWrite", qos: .utility)
    private let micAudioFileQueue = DispatchQueue(label: "MicAudioFileWrite", qos: .utility)

    // Audio format conversion (multi-channel to mono)
    private var monoOutputFormat: AVAudioFormat?
    private var inputChannelCount: AVAudioChannelCount = 1

    // Throttle system audio visualizer updates (skip every other callback)
    private var systemLevelUpdateCounter: Int = 0

    // Debug: Track system audio buffer count
    private var systemBufferCount: Int = 0

    // System audio status observation
    private var systemAudioCancellable: AnyCancellable?
    private var systemAudioSilenceStart: Date?
    private let systemAudioSilenceThreshold: TimeInterval = 10  // 10s of silence = warning

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

    /// Updates systemAudioStatus based on SystemAudioCapture's error messages
    private func updateSystemAudioStatus(fromError errorMessage: String?) {
        guard isRecording else {
            systemAudioStatus = .unknown
            return
        }

        if let message = errorMessage {
            if message.contains("Switched to") {
                // Brief reconnecting state, then back to healthy
                systemAudioStatus = .reconnecting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.isRecording else { return }
                    if self.systemAudioStatus == .reconnecting {
                        self.systemAudioStatus = .healthy
                    }
                }
            } else if message.contains("unavailable") || message.contains("failed") {
                systemAudioStatus = .failed
            }
        } else {
            // No error - status is healthy (if we're recording)
            if systemAudioStatus != .silent {
                systemAudioStatus = .healthy
            }
        }
    }

    func start() {
        guard !isRecording, !isStarting else {
            AppLogger.audio.warning("Already recording or starting, ignoring duplicate start request")
            return
        }

        // Pre-flight validation checks
        let validationResult = RecordingValidator.validateRecordingConditions()
        guard validationResult.isValid else {
            AppLogger.audio.error("Pre-flight check failed", ["error": validationResult.errorMessage ?? "Unknown error"])
            error = validationResult.errorMessage
            return
        }

        // Set isStarting to prevent double-start during async setup
        isStarting = true
        error = nil
        systemBufferCount = 0  // Reset debug counter
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

    private func startAudioCapture() async throws {
        guard let engine = engine, let inputNode = inputNode else {
            throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"])
        }

        // Use system default microphone (whatever macOS has configured)
        // CRITICAL: Must use inputFormat(forBus: 1) to get ACTUAL hardware format
        // outputFormat(forBus: 0) returns the converter format, not hardware format
        let hardwareFormat = inputNode.inputFormat(forBus: 1)
        AppLogger.audioMic.info("Hardware format", ["sampleRate": "\(hardwareFormat.sampleRate)", "channels": "\(hardwareFormat.channelCount)"])

        guard hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0 else {
            throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid input format"])
        }

        // Use the HARDWARE format for the tap (critical for Bluetooth devices)
        let recordingFormat = hardwareFormat

        // Start system audio capture
        // CRITICAL: Create audio file BEFORE starting I/O proc to avoid CPU overload
        // Creating files in the audio callback causes HALC_ProxyIOContext::IOWorkLoop overload
        if let capture = systemAudioCapture as? SystemAudioCapture {
            AppLogger.audioSystem.info("System audio capture object exists, setting up")
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
            let fileURL = documentsPath.appendingPathComponent("meeting_\(timestamp)_system.wav")
            AppLogger.audioSystem.info("System audio file URL", ["file": fileURL.lastPathComponent])

            DispatchQueue.main.async {
                self.systemAudioFileURL = fileURL
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let strongSelf = self else {
                    AppLogger.audioSystem.error("System audio setup: self is nil")
                    return
                }

                AppLogger.audioSystem.info("Starting system audio capture on background thread")

                do {
                    // Step 1: Prepare the tap (creates aggregate device, gets format)
                    // This does NOT start the I/O proc yet
                    try capture.prepare()

                    // Step 2: Get the actual format from the tap
                    guard let tapFormat = capture.audioFormat else {
                        throw NSError(domain: "Audio", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to get tap format"])
                    }
                    AppLogger.audioSystem.debug("System audio format (reported)", ["sampleRate": "\(Int(tapFormat.sampleRate))", "channels": "\(tapFormat.channelCount)", "interleaved": "\(tapFormat.isInterleaved)"])

                    // CRITICAL: CoreAudio process taps report 96kHz but actual audio data is 48kHz
                    // See MEMORY.md: "System audio: 48kHz stereo (tap claims 96kHz but actual rate is 48kHz)"
                    // Using the reported rate causes files to be half the expected duration
                    let actualSampleRate: Double = 48000.0
                    AppLogger.audioSystem.debug("System audio format (actual)", ["actualRate": "\(Int(actualSampleRate))", "reportedRate": "\(Int(tapFormat.sampleRate))"])

                    // Step 3: Create audio file BEFORE starting I/O proc (critical!)
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: actualSampleRate,  // Use actual 48kHz, not reported 96kHz
                        AVNumberOfChannelsKey: Int(tapFormat.channelCount),
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: !tapFormat.isInterleaved
                    ]

                    strongSelf.systemAudioFile = try AVAudioFile(
                        forWriting: fileURL,
                        settings: settings,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: tapFormat.isInterleaved
                    )
                    AppLogger.audioSystem.info("System audio file created before I/O proc", ["sampleRate": "\(Int(actualSampleRate))", "channels": "\(tapFormat.channelCount)"])

                    // Step 4: Now start the I/O proc with a lightweight callback
                    // The file already exists, so callback only needs to copy+write
                    try capture.start { [weak self] systemBuffer in
                        guard let self = self else { return }

                        self.systemBufferCount += 1
                        let currentBufferCount = self.systemBufferCount

                        // Calculate system audio level synchronously (fast, no I/O)
                        self.calculateSystemLevel(buffer: systemBuffer)

                        // CRITICAL: Copy buffer before async dispatch
                        // System audio uses bufferListNoCopy - memory is only valid during callback
                        guard let bufferCopy = self.deepCopyBuffer(systemBuffer) else {
                            if currentBufferCount <= 3 {
                                AppLogger.audioSystem.warning("Failed to copy system audio buffer", ["bufferNumber": "\(currentBufferCount)"])
                            }
                            return
                        }

                        // Debug: Log format details on first few buffers
                        if currentBufferCount <= 3 {
                            let fmt = bufferCopy.format
                            AppLogger.audioSystem.debug("System buffer", ["number": "\(currentBufferCount)", "sampleRate": "\(Int(fmt.sampleRate))", "channels": "\(fmt.channelCount)", "frames": "\(bufferCopy.frameLength)"])
                        }

                        // Dispatch file write to background queue (non-blocking)
                        // File already exists, so this is just a write operation
                        self.systemAudioFileQueue.async { [weak self] in
                            guard let self = self,
                                  self.consecutiveSystemWriteErrors < self.maxConsecutiveWriteErrors,
                                  let audioFile = self.systemAudioFile else { return }
                            do {
                                try audioFile.write(from: bufferCopy)
                                self.consecutiveSystemWriteErrors = 0
                            } catch {
                                self.consecutiveSystemWriteErrors += 1
                                if self.consecutiveSystemWriteErrors <= 3 || self.consecutiveSystemWriteErrors == self.maxConsecutiveWriteErrors {
                                    AppLogger.audioSystem.error("System audio write failed", ["bufferNumber": "\(currentBufferCount)", "error": error.localizedDescription, "consecutive": "\(self.consecutiveSystemWriteErrors)"])
                                }
                                if self.consecutiveSystemWriteErrors >= self.maxConsecutiveWriteErrors {
                                    AppLogger.audioSystem.error("Too many consecutive system write errors, stopping system writes")
                                }
                            }
                        }
                    }
                    AppLogger.audioSystem.info("System audio capture started")

                } catch {
                    AppLogger.audioSystem.warning("System audio failed", ["error": error.localizedDescription])
                    DispatchQueue.main.async {
                        strongSelf.error = "System audio unavailable - recording mic only"
                    }
                }
            }
        }

        // Create mic audio file - ALWAYS save as mono for Speech framework compatibility
        do {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
            let fileURL = documentsPath.appendingPathComponent("meeting_\(timestamp)_mic.wav")

            self.originalMicAudioFileURL = fileURL
            DispatchQueue.main.async {
                self.micAudioFileURL = fileURL
            }

            // Always create mono output format at the hardware sample rate
            guard let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: recordingFormat.sampleRate,
                channels: 1,
                interleaved: true
            ) else {
                throw NSError(domain: "Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create mono format"])
            }
            self.monoOutputFormat = monoFormat

            // Track channel count for manual downmix
            self.inputChannelCount = recordingFormat.channelCount
            if recordingFormat.channelCount > 1 {
                AppLogger.audioMic.debug("Will manually downmix to mono", ["channels": "\(recordingFormat.channelCount)"])
            }

            // Save as mono WAV file
            micAudioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: monoFormat.settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
            AppLogger.audioMic.info("Saving as mono", ["sampleRate": "\(recordingFormat.sampleRate)"])
        } catch {
            throw NSError(domain: "Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create mic audio file: \(error.localizedDescription)"])
        }

        // Remove any existing tap (safety check)
        inputNode.removeTap(onBus: 0)

        // Install tap on microphone
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let strongSelf = self else { return }

            // Update watchdog timestamp
            strongSelf.lastBufferTime = Date()

            // Calculate audio level for visualizer (use original buffer)
            strongSelf.calculateLevel(buffer: buffer)

            // Convert to mono if needed, then write to file
            strongSelf.micAudioFileQueue.async {
                guard strongSelf.consecutiveMicWriteErrors < strongSelf.maxConsecutiveWriteErrors,
                      let audioFile = strongSelf.micAudioFile,
                      let monoFormat = strongSelf.monoOutputFormat else { return }

                do {
                    if strongSelf.inputChannelCount > 1 {
                        // Manual downmix: average all channels to mono
                        guard let monoBuffer = strongSelf.manualDownmix(buffer: buffer, to: monoFormat) else {
                            AppLogger.audioMic.error("Failed to downmix buffer")
                            return
                        }
                        try audioFile.write(from: monoBuffer)
                    } else {
                        // Already mono, write directly
                        try audioFile.write(from: buffer)
                    }
                    strongSelf.consecutiveMicWriteErrors = 0
                } catch {
                    strongSelf.consecutiveMicWriteErrors += 1
                    if strongSelf.consecutiveMicWriteErrors <= 3 || strongSelf.consecutiveMicWriteErrors == strongSelf.maxConsecutiveWriteErrors {
                        AppLogger.audioMic.error("Write failed", ["error": error.localizedDescription, "consecutive": "\(strongSelf.consecutiveMicWriteErrors)"])
                    }
                    if strongSelf.consecutiveMicWriteErrors >= strongSelf.maxConsecutiveWriteErrors {
                        AppLogger.audioMic.error("Too many consecutive write errors, stopping mic writes")
                    }
                }
            }
        }

        try engine.start()

        await MainActor.run {
            // isRecording already set in start()
            self.startTime = Date()
            self.recordingDuration = 0.0
            self.startTimer()
            self.startWatchdog()
            NSSound(named: "Tink")?.play()
        }
    }

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

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            DispatchQueue.main.async {
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        recordingDuration = 0.0
    }

    private func startWatchdog() {
        lastBufferTime = Date()
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }

            let timeSinceLastBuffer = Date().timeIntervalSince(self.lastBufferTime)

            if timeSinceLastBuffer > 3.0 {
                // Enforce cooldown — don't attempt recovery more often than every 5s
                if let lastRecovery = self.lastRecoveryTime,
                   Date().timeIntervalSince(lastRecovery) < self.recoveryCooldown {
                    return  // Too soon, skip this tick
                }

                // Give up after too many failed recoveries
                if self.deviceSwitchCount >= self.maxRecoveryAttempts {
                    AppLogger.audioMic.error("Max recovery attempts reached, stopping recording", [
                        "attempts": "\(self.deviceSwitchCount)"
                    ])
                    DispatchQueue.main.async {
                        self.error = "Audio device unavailable — recording stopped"
                        self.stop()
                    }
                    return
                }

                // Audio stopped → device likely changed
                AppLogger.audioMic.warning("Audio device disconnected or changed, switching to default")
                // Dispatch to background — recovery uses Thread.sleep for HAL settle time
                DispatchQueue.global(qos: .userInitiated).async {
                    self.recoverFromDeviceChange()
                }
            }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func recoverFromDeviceChange() {
        // CRITICAL: Prevent concurrent recovery attempts
        // AVAudioEngine notifications can fire multiple times during rapid device changes
        guard !isMicRecovering else {
            AppLogger.audioMic.warning("Recovery already in progress, skipping duplicate request")
            return
        }
        isMicRecovering = true
        defer { isMicRecovering = false }
        lastRecoveryTime = Date()

        guard let engine = engine, let inputNode = inputNode else { return }

        // Track device switch for health monitoring
        let switchStart = Date()
        deviceSwitchCount += 1
        AppLogger.audioMic.debug("Recovering from device change", ["switchNumber": "\(deviceSwitchCount)", "maxAttempts": "\(maxRecoveryAttempts)"])

        // Stop engine (but keep recording flag true)
        inputNode.removeTap(onBus: 0)
        engine.stop()

        // Reset to system default (ignore UserDefaults preference during recovery)
        engine.reset()
        self.inputNode = engine.inputNode

        // Get new device format
        guard let newInputNode = self.inputNode else {
            AppLogger.audioMic.error("Failed to get input node after reset")
            return
        }

        // HAL settle time - wait for audio hardware to stabilize after device change
        // Same approach as SystemAudioCapture recovery
        Thread.sleep(forTimeInterval: 0.1)  // 100ms

        // Get ACTUAL hardware format (not converter format)
        let recordingFormat = newInputNode.inputFormat(forBus: 1)
        let oldChannelCount = self.inputChannelCount
        AppLogger.audioMic.info("Switched to default device", ["sampleRate": "\(recordingFormat.sampleRate)", "channels": "\(recordingFormat.channelCount)"])

        // ALWAYS update channel count for proper downmix handling
        // This was a bug: if only channel count changed (not sample rate), downmix wouldn't work
        self.inputChannelCount = recordingFormat.channelCount
        if recordingFormat.channelCount > 1 && oldChannelCount != recordingFormat.channelCount {
            AppLogger.audioMic.debug("Recovery: will manually downmix to mono", ["channels": "\(recordingFormat.channelCount)"])
        }

        // Check if we need to create a new file due to format change
        // Must check BOTH sample rate AND channel count changes
        let sampleRateChanged = micAudioFile.map { recordingFormat.sampleRate != $0.processingFormat.sampleRate } ?? false
        let channelCountChanged = oldChannelCount != recordingFormat.channelCount

        if sampleRateChanged || channelCountChanged {
            let changeReason = sampleRateChanged ? "Sample rate" : "Channel count"
            AppLogger.audioMic.warning("Format changed, closing old file and creating new segment", ["reason": changeReason])
            micAudioFile = nil

            // Create new file segment as mono
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
            let fileURL = documentsPath.appendingPathComponent("meeting_\(timestamp)_mic_recovery.wav")

            do {
                // Always create mono format at new sample rate
                guard let monoFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: recordingFormat.sampleRate,
                    channels: 1,
                    interleaved: true
                ) else {
                    AppLogger.audioMic.error("Failed to create mono format for recovery")
                    return
                }
                self.monoOutputFormat = monoFormat

                micAudioFile = try AVAudioFile(
                    forWriting: fileURL,
                    settings: monoFormat.settings,
                    commonFormat: monoFormat.commonFormat,
                    interleaved: monoFormat.isInterleaved
                )
                AppLogger.audioMic.info("Created recovery audio file", ["file": fileURL.lastPathComponent])

                // Update file URL reference
                DispatchQueue.main.async {
                    self.micAudioFileURL = fileURL
                }
            } catch {
                AppLogger.audioMic.error("Failed to create recovery audio file", ["error": error.localizedDescription])
                return
            }
        }

        // Reinstall tap
        newInputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Update watchdog timestamp
            self.lastBufferTime = Date()

            // Calculate audio level for visualizer
            self.calculateLevel(buffer: buffer)

            // Convert to mono if needed, then write to file
            // Note: Use weak self in nested async to prevent retain cycle
            self.micAudioFileQueue.async { [weak self] in
                guard let self = self,
                      self.consecutiveMicWriteErrors < self.maxConsecutiveWriteErrors,
                      let audioFile = self.micAudioFile,
                      let monoFormat = self.monoOutputFormat else { return }

                do {
                    if self.inputChannelCount > 1 {
                        // Manual downmix: average all channels to mono
                        guard let monoBuffer = self.manualDownmix(buffer: buffer, to: monoFormat) else {
                            AppLogger.audioMic.error("Failed to downmix buffer")
                            return
                        }
                        try audioFile.write(from: monoBuffer)
                    } else {
                        // Already mono, write directly
                        try audioFile.write(from: buffer)
                    }
                    self.consecutiveMicWriteErrors = 0
                } catch {
                    self.consecutiveMicWriteErrors += 1
                    if self.consecutiveMicWriteErrors <= 3 || self.consecutiveMicWriteErrors == self.maxConsecutiveWriteErrors {
                        AppLogger.audioMic.error("Write failed", ["error": error.localizedDescription, "consecutive": "\(self.consecutiveMicWriteErrors)"])
                    }
                    if self.consecutiveMicWriteErrors >= self.maxConsecutiveWriteErrors {
                        AppLogger.audioMic.error("Too many consecutive write errors, stopping mic writes")
                    }
                }
            }
        }

        // Restart engine
        do {
            try engine.start()
            lastBufferTime = Date() // Reset watchdog

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.error = "Switched to default mic"

                // Clear error after 3 seconds (use weak self to prevent retain)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self = self else { return }
                    if self.error == "Switched to default mic" {
                        self.error = nil
                    }
                }
            }

            // Record the device switch gap
            let gap = AudioGap(
                start: switchStart,
                duration: Date().timeIntervalSince(switchStart),
                reason: "Device switch"
            )
            recordingGaps.append(gap)
            AppLogger.audioMic.info("Device recovery complete, recording continues", ["gap": gap.description])
        } catch {
            AppLogger.audioMic.error("Failed to restart engine", ["error": error.localizedDescription])
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.error = "Failed to recover from device change"
                self.stop()
            }
        }
    }

    /// Manually downmix multi-channel audio to mono by averaging all channels
    private func manualDownmix(buffer: AVAudioPCMBuffer, to monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = buffer.frameLength
        let channelCount = Int(buffer.format.channelCount)

        guard channelCount > 0, frameCount > 0 else { return nil }

        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
            return nil
        }
        monoBuffer.frameLength = frameCount

        guard let monoData = monoBuffer.floatChannelData?[0] else { return nil }

        // Check if buffer is interleaved or non-interleaved
        if buffer.format.isInterleaved {
            // Interleaved: samples are [L0, R0, C0, S0, L1, R1, C1, S1, ...]
            guard let interleavedData = buffer.floatChannelData?[0] else { return nil }

            for frame in 0..<Int(frameCount) {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += interleavedData[frame * channelCount + channel]
                }
                monoData[frame] = sum / Float(channelCount)
            }
        } else {
            // Non-interleaved: each channel is a separate array
            guard let channelData = buffer.floatChannelData else { return nil }

            for frame in 0..<Int(frameCount) {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channelData[channel][frame]
                }
                monoData[frame] = sum / Float(channelCount)
            }
        }

        return monoBuffer
    }

    /// Deep copy an AVAudioPCMBuffer to ensure data safety across async dispatch
    /// Required because system audio buffers use bufferListNoCopy and don't own their memory
    private func deepCopyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        // Copy audio data based on format (interleaved vs non-interleaved)
        if buffer.format.isInterleaved {
            // Interleaved: single contiguous buffer
            if let srcData = buffer.floatChannelData?[0],
               let dstData = copy.floatChannelData?[0] {
                let bytesToCopy = Int(buffer.frameLength) * Int(buffer.format.channelCount) * MemoryLayout<Float>.size
                memcpy(dstData, srcData, bytesToCopy)
            }
        } else {
            // Non-interleaved: separate buffer per channel
            if let srcChannels = buffer.floatChannelData,
               let dstChannels = copy.floatChannelData {
                let bytesPerChannel = Int(buffer.frameLength) * MemoryLayout<Float>.size
                for channel in 0..<Int(buffer.format.channelCount) {
                    memcpy(dstChannels[channel], srcChannels[channel], bytesPerChannel)
                }
            }
        }

        return copy
    }

    private func calculateLevel(buffer: AVAudioPCMBuffer) {
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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.audioLevel = level
            self.audioLevelHistory.removeFirst()
            self.audioLevelHistory.append(level)

            // Silence detection - track how long we've been below threshold
            self.updateSilenceTracking(currentLevel: level)
        }
    }

    /// Updates silence tracking based on current audio level
    private func updateSilenceTracking(currentLevel: Float) {
        let now = Date()

        if currentLevel > silenceThreshold {
            // Audio detected - reset silence tracking
            lastNonSilentTime = now
            isSilent = false
            silenceDuration = 0
        } else {
            // Below threshold - we're in silence
            isSilent = true
            if let lastActive = lastNonSilentTime {
                silenceDuration = now.timeIntervalSince(lastActive)
            } else {
                // First time detecting silence, start tracking
                lastNonSilentTime = now
                silenceDuration = 0
            }
        }
    }

    /// Reset silence tracking (call when recording starts)
    func resetSilenceTracking() {
        lastNonSilentTime = Date()
        silenceDuration = 0
        isSilent = false
    }

    private func calculateSystemLevel(buffer: AVAudioPCMBuffer) {
        // Throttle updates: only update every 4th callback (~2x faster than mic instead of ~8x)
        systemLevelUpdateCounter += 1
        guard systemLevelUpdateCounter >= 4 else { return }
        systemLevelUpdateCounter = 0

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

        // Track system audio silence for warning indicator
        updateSystemAudioSilenceTracking(peakLevel: level)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.systemAudioLevelHistory.removeFirst()
            self.systemAudioLevelHistory.append(level)
        }
    }

    /// Tracks prolonged silence in system audio for warning display
    private func updateSystemAudioSilenceTracking(peakLevel: Float) {
        let silenceThreshold: Float = 0.001  // Very low threshold for silence

        if peakLevel < silenceThreshold {
            // System audio is silent
            if systemAudioSilenceStart == nil {
                systemAudioSilenceStart = Date()
            }

            let silenceDuration = Date().timeIntervalSince(systemAudioSilenceStart!)
            if silenceDuration > systemAudioSilenceThreshold {
                // Prolonged silence - show warning (but only if not already in a worse state)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.systemAudioStatus == .healthy {
                        self.systemAudioStatus = .silent
                        AppLogger.audioSystem.warning("System audio silent", ["duration": "\(Int(silenceDuration))s"])
                    }
                }
            }
        } else {
            // Audio present - reset silence tracking
            systemAudioSilenceStart = nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Only reset to healthy if we were in silent state (not failed/reconnecting)
                if self.systemAudioStatus == .silent {
                    self.systemAudioStatus = .healthy
                }
            }
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
