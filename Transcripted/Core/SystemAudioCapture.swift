import Foundation
import AudioToolbox
import AVFoundation
import QuartzCore  // CACurrentMediaTime — real-time-safe monotonic clock

/// Captures system-wide audio output using CoreAudio process taps (macOS 14.2+)
///
/// Note: This class does NOT use @MainActor because it manages CoreAudio devices
/// that require synchronous access from both main and audio threads.
/// UI updates are dispatched to main thread explicitly.
///
/// ## Expected Console Warnings
/// During setup and teardown, CoreAudio may emit internal framework messages such as:
/// - `HALC_ShellObject::SetPropertyData: call to the proxy failed` - Normal during aggregate device creation
/// - `throwing -10877` - Internal format negotiation (kAudioUnitErr_InvalidElement)
/// - `AudioObjectRemovePropertyListener: no object with given ID` - Cleanup race condition (harmless)
/// These are internal CoreAudio logs that cannot be suppressed from user code and don't affect functionality.
@available(macOS 14.2, *)
class SystemAudioCapture: ObservableObject {
    @Published var isCapturing: Bool = false
    @Published var errorMessage: String?

    var processTapID: AudioObjectID = .unknown
    var aggregateDeviceID: AudioObjectID = .unknown
    var deviceProcID: AudioDeviceIOProcID?
    var tapStreamDescription: AudioStreamBasicDescription?
    var isPrepared: Bool = false

    /// Returns the audio format after prepare() has been called
    /// Use this to create your audio file BEFORE calling start()
    var audioFormat: AVAudioFormat? {
        guard var desc = tapStreamDescription else { return nil }
        return AVAudioFormat(streamDescription: &desc)
    }

    let queue = DispatchQueue(label: "SystemAudioCapture", qos: .userInitiated)
    var bufferCallback: ((AVAudioPCMBuffer) -> Void)?

    // Device change watchdog - thread-safe access via lock
    // Uses CACurrentMediaTime() (monotonic, allocation-free) instead of Date()
    // to avoid memory allocation on CoreAudio real-time threads.
    private var _lastBufferTime: CFTimeInterval = CACurrentMediaTime()
    private var _hasReceivedFirstBuffer: Bool = false
    private let lastBufferTimeLock = NSLock()
    var hasReceivedFirstBuffer: Bool {
        get {
            lastBufferTimeLock.lock()
            defer { lastBufferTimeLock.unlock() }
            return _hasReceivedFirstBuffer
        }
        set {
            lastBufferTimeLock.lock()
            defer { lastBufferTimeLock.unlock() }
            _hasReceivedFirstBuffer = newValue
        }
    }
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

    // MARK: - Proactive Device Change Listener
    // Detects output device changes IMMEDIATELY (not reactively via watchdog)
    // This is how OBS Studio, Mozilla Firefox, and professional audio apps handle device switching
    var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    var lastDeviceChangeTime: CFTimeInterval?
    let deviceChangeDebounce: TimeInterval = 0.3  // 300ms debounce - device changes fire multiple times

    // MARK: - Generation Counter (prevents stale delayed cleanup from destroying new sessions)
    // Incremented each time prepare() creates a new tap session.
    // The delayed cleanup in stop() captures the generation at schedule time and skips
    // if it no longer matches — meaning a new session has started in the interim.
    private var _generation: UInt64 = 0
    private let generationLock = NSLock()

    // MARK: - Recovery Guard (prevents concurrent recovery attempts)
    private var _isRecovering: Bool = false
    private let recoveryLock = NSLock()
    var isRecovering: Bool {
        get {
            recoveryLock.lock()
            defer { recoveryLock.unlock() }
            return _isRecovering
        }
        set {
            recoveryLock.lock()
            defer { recoveryLock.unlock() }
            _isRecovering = newValue
        }
    }

    // MARK: - Buffer Statistics (thread-safe)
    var _totalBuffers: Int = 0
    var _buffersWithData: Int = 0
    var _buffersDropped: Int = 0
    let statsLock = NSLock()

    /// Public getter for buffer success rate (Phase 3: Transcript Metadata)
    /// Returns 1.0 if no buffers received yet (assume success until proven otherwise)
    var bufferSuccessRate: Double {
        statsLock.lock()
        defer { statsLock.unlock() }
        guard _totalBuffers > 0 else { return 1.0 }
        return Double(_buffersWithData) / Double(_totalBuffers)
    }

    /// Public getter for total buffers received
    var totalBuffers: Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _totalBuffers
    }

    /// Public getter for buffers with actual audio data
    var buffersWithData: Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _buffersWithData
    }

    init() {}

    /// Prepares the system audio tap without starting capture
    /// Call this first, then use audioFormat to create your file, then call start()
    /// This separation prevents disk I/O from blocking the audio callback thread
    ///
    /// If called while already prepared (e.g. monitoring -> recording transition),
    /// tears down old resources first and creates a fresh tap. The generation counter
    /// is incremented to invalidate any pending delayed cleanup from a prior stop().
    func prepare() throws {
        if isPrepared {
            AppLogger.audioSystem.info("Re-preparing: tearing down old tap before creating fresh one")
            cleanupDevicesOnly()
            stopDeviceChangeListener()
        }

        // Increment generation — any pending delayed cleanup from a prior stop()
        // will see a stale generation and skip itself
        generationLock.lock()
        _generation &+= 1
        generationLock.unlock()

        AppLogger.audioSystem.info("Setting up system audio tap")
        try setupSystemAudioTap()
        isPrepared = true

        // Start proactive device change listener (critical for bulletproof device switching)
        startDeviceChangeListener()

        AppLogger.audioSystem.info("System audio tap created", ["sampleRate": "\(audioFormat?.sampleRate ?? 0)", "channels": "\(audioFormat?.channelCount ?? 0)"])
    }

    /// Starts capturing system audio and calls the callback with each buffer
    /// If prepare() wasn't called, this will call it automatically
    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {
        AppLogger.audioSystem.info("Start called")
        guard !isCapturing else {
            AppLogger.audioSystem.warning("Already capturing, ignoring")
            return
        }

        self.bufferCallback = bufferCallback
        errorMessage = nil

        do {
            // Setup tap if not already prepared
            if !isPrepared {
                AppLogger.audioSystem.info("Preparing tap in start()")
                try prepare()
            }

            AppLogger.audioSystem.info("Starting audio device")
            try startAudioDevice()
            AppLogger.audioSystem.info("Audio device started")

            DispatchQueue.main.async {
                self.isCapturing = true
                self.startWatchdog()
            }
            AppLogger.audioSystem.info("Now capturing")
        } catch {
            let errMsg = "Failed to start system audio capture: \(error.localizedDescription)"
            AppLogger.audioSystem.error("Start failed", ["error": errMsg])
            errorMessage = errMsg
            throw error
        }
    }

    /// Stops capturing system audio with a 0.5s delayed cleanup
    /// The delay lets the CoreAudio pipeline settle before destroying devices.
    /// If a new session starts before the delay fires (e.g. monitoring -> recording),
    /// the generation counter will cause the stale cleanup to be skipped.
    func stop() {
        guard isCapturing else { return }

        // Update UI immediately - don't block the main thread
        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = false
            self?.stopWatchdog()
        }

        // Capture current generation before scheduling delayed cleanup
        generationLock.lock()
        let capturedGeneration = _generation
        generationLock.unlock()

        // Move delay + cleanup to background queue to avoid blocking main thread
        // The 0.5s delay lets the audio pipeline settle before destroying devices
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Thread.sleep(forTimeInterval: 0.5)
            guard let self = self else { return }

            // Check if a new session started while we were waiting
            self.generationLock.lock()
            let currentGeneration = self._generation
            self.generationLock.unlock()

            if capturedGeneration != currentGeneration {
                AppLogger.audioSystem.info("Skipping delayed cleanup — new session started (generation \(capturedGeneration) → \(currentGeneration))")
                return
            }

            self.cleanup()
        }
    }

    /// Stops capturing immediately with synchronous cleanup (no 0.5s delay)
    /// Use when the caller will re-prepare the same instance right away
    /// (e.g. monitoring -> recording transition) to avoid the race where
    /// delayed cleanup destroys the newly created tap.
    func stopSync() {
        guard isCapturing else { return }

        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = false
            self?.stopWatchdog()
        }

        cleanup()
    }

    deinit {
        stopWatchdog()
        cleanup()
    }
}
