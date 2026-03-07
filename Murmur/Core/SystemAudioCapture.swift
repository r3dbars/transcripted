import Foundation
import AudioToolbox
import AVFoundation

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

    private var processTapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapStreamDescription: AudioStreamBasicDescription?
    private var isPrepared: Bool = false

    /// Returns the audio format after prepare() has been called
    /// Use this to create your audio file BEFORE calling start()
    var audioFormat: AVAudioFormat? {
        guard var desc = tapStreamDescription else { return nil }
        return AVAudioFormat(streamDescription: &desc)
    }

    private let queue = DispatchQueue(label: "SystemAudioCapture", qos: .userInitiated)
    private var bufferCallback: ((AVAudioPCMBuffer) -> Void)?

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

    // MARK: - Proactive Device Change Listener
    // Detects output device changes IMMEDIATELY (not reactively via watchdog)
    // This is how OBS Studio, Mozilla Firefox, and professional audio apps handle device switching
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var lastDeviceChangeTime: Date?
    private let deviceChangeDebounce: TimeInterval = 0.3  // 300ms debounce - device changes fire multiple times

    // MARK: - Recovery Guard (prevents concurrent recovery attempts)
    private var _isRecovering: Bool = false
    private let recoveryLock = NSLock()
    private var isRecovering: Bool {
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
    private var _totalBuffers: Int = 0
    private var _buffersWithData: Int = 0
    private var _buffersDropped: Int = 0
    private let statsLock = NSLock()

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
    func prepare() throws {
        guard !isPrepared else {
            AppLogger.audioSystem.warning("Already prepared")
            return
        }

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

    /// Stops capturing system audio
    func stop() {
        guard isCapturing else { return }

        // Update UI immediately - don't block the main thread
        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = false
            self?.stopWatchdog()
        }

        // Move delay + cleanup to background queue to avoid blocking main thread
        // The 0.5s delay lets the audio pipeline settle before destroying devices
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Thread.sleep(forTimeInterval: 0.5)
            self?.cleanup()
        }
    }

    // MARK: - Private Methods

    private func setupSystemAudioTap() throws {
        // Get the default system output device
        let systemOutputID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readDeviceUID()

        // Get all audio processes to tap system-wide audio
        let allProcesses = try AudioObjectID.readProcessList()

        // Create tap description for system-wide audio (tap all processes)
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: allProcesses)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        var tapID: AudioObjectID = .unknown
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard err == noErr else {
            throw "Failed to create system audio tap: \(err)"
        }

        self.processTapID = tapID

        // Create aggregate device with the tap
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcripted-SystemTap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        // Read the tap's audio format
        self.tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()

        // Create aggregate device
        aggregateDeviceID = .unknown
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID)
        guard err == noErr else {
            throw "Failed to create aggregate device: \(err)"
        }

        // CRITICAL: The tap format may report a different sample rate than the aggregate
        // device actually operates at. Read the device's nominal rate and correct the format.
        // Without this, the WAV file header has the wrong rate and audio plays back at the wrong speed.
        let deviceNominalRate = try aggregateDeviceID.readNominalSampleRate()
        if deviceNominalRate > 0 && deviceNominalRate != tapStreamDescription!.mSampleRate {
            AppLogger.audioSystem.warning("Tap format rate (\(Int(tapStreamDescription!.mSampleRate))Hz) differs from device nominal rate (\(Int(deviceNominalRate))Hz) — correcting")
            tapStreamDescription!.mSampleRate = deviceNominalRate
        }
        AppLogger.audioSystem.info("Aggregate device nominal sample rate", ["rate": "\(Int(deviceNominalRate))"])
    }

    private func startAudioDevice() throws {
        guard var streamDescription = tapStreamDescription else {
            throw "Tap stream description not available"
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw "Failed to create AVAudioFormat from tap description"
        }

        // Track callback count for debugging (thread-safe via atomic-like access)
        var callbackCount = 0

        // Create I/O proc to receive audio buffers
        var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self = self, let bufferCallback = self.bufferCallback else {
                AppLogger.audioSystem.warning("I/O Proc: self or bufferCallback is nil")
                return
            }

            callbackCount += 1
            if callbackCount <= 3 {
                AppLogger.audioSystem.debug("I/O Proc callback", ["count": "\(callbackCount)"])
            }

            do {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                    AppLogger.audioSystem.error("I/O Proc: Failed to create PCM buffer")
                    throw "Failed to create PCM buffer"
                }

                // Track total buffers received
                self.incrementStats(hasData: false)

                // CRITICAL FIX: Check for zero-frame buffers BEFORE updating watchdog
                // Zero-frame buffers were defeating the watchdog by updating lastBufferTime
                // even though no actual audio was being captured (device switch scenario)
                let frameLength = buffer.frameLength
                if frameLength == 0 {
                    // Log throttled: first 10, then every 100th
                    if callbackCount <= 10 || callbackCount % 100 == 0 {
                        AppLogger.audioSystem.warning("Zero-frame buffer", ["callbackCount": "\(callbackCount)"])
                    }
                    self.incrementDropped()
                    // Do NOT update lastBufferTime - let watchdog detect silence
                    return
                }

                if callbackCount <= 3 {
                    AppLogger.audioSystem.debug("Buffer created", ["frames": "\(frameLength)"])
                }

                // Only update watchdog timestamp for buffers with actual data
                self.lastBufferTime = Date()
                self.markBufferHasData()

                // Send buffer to callback
                bufferCallback(buffer)
            } catch {
                AppLogger.audioSystem.error("I/O Proc error", ["error": "\(error)"])
            }
        }

        guard err == noErr else {
            throw "Failed to create device I/O proc: \(err)"
        }

        // Start the audio device
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            throw "Failed to start audio device: \(err)"
        }
    }

    private func cleanup() {
        AppLogger.audioSystem.info("Cleaning up system audio capture")

        // Log buffer statistics before cleanup
        logStats()

        // Cleanup order is important to minimize CoreAudio internal warnings:
        // 0. Stop the device change listener first
        // 1. Stop the device (stops I/O callbacks)
        // 2. Destroy the I/O proc (releases callback reference)
        // 3. Destroy the aggregate device (releases sub-devices)
        // 4. Destroy the process tap last (it depends on nothing else)
        //
        // Note: Some CoreAudio warnings like "AudioObjectRemovePropertyListener: no object"
        // may still appear during cleanup - these are internal framework race conditions
        // that don't affect functionality.

        // Step 0: Stop device change listener
        stopDeviceChangeListener()

        // Step 1 & 2: Stop device and destroy I/O proc
        if aggregateDeviceID.isValid {
            _ = AudioDeviceStop(aggregateDeviceID, deviceProcID)

            if let deviceProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                self.deviceProcID = nil
            }
        }

        // Step 3: Destroy aggregate device
        if aggregateDeviceID.isValid {
            let result = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if result == noErr {
                AppLogger.audioSystem.info("Aggregate device destroyed")
            }
            // Don't log warnings for cleanup failures - they're expected race conditions
            aggregateDeviceID = .unknown
        }

        // Step 4: Destroy the process tap last
        if processTapID.isValid {
            let result = AudioHardwareDestroyProcessTap(processTapID)
            if result == noErr {
                AppLogger.audioSystem.info("Process tap destroyed")
            }
            // Don't log warnings for cleanup failures - they're expected race conditions
            processTapID = .unknown
        }

        bufferCallback = nil
        isPrepared = false
        resetStats()
        AppLogger.audioSystem.info("System audio cleanup complete")
    }

    private func startWatchdog() {
        lastBufferTime = Date()
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isCapturing else { return }

            let timeSinceLastBuffer = Date().timeIntervalSince(self.lastBufferTime)

            if timeSinceLastBuffer > 3.0 {
                // System audio stopped → output device likely changed
                AppLogger.audioSystem.warning("Output device disconnected or changed, attempting recovery")
                // Dispatch to self.queue — recovery uses Thread.sleep for HAL settle time
                self.queue.async {
                    self.recoverFromOutputChange()
                }
            }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: - Proactive Device Change Listener Methods

    /// Starts listening for default output device changes
    /// This is the PROACTIVE approach used by OBS Studio, Mozilla Firefox, and professional audio apps
    /// Instead of waiting for silence (reactive), we detect device changes immediately
    private func startDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        deviceChangeListenerBlock = { [weak self] _, _ in
            self?.handleDeviceChangeNotification()
        }

        guard let block = deviceChangeListenerBlock else { return }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )

        if status != noErr {
            AppLogger.audioSystem.warning("Failed to add device change listener", ["status": "\(status)"])
        } else {
            AppLogger.audioSystem.info("Device change listener registered")
        }
    }

    /// Called when default output device changes
    /// Uses 300ms debounce because macOS fires MULTIPLE notifications for a single device change
    private func handleDeviceChangeNotification() {
        // Debounce: device changes fire multiple times rapidly
        let now = Date()
        if let lastChange = lastDeviceChangeTime,
           now.timeIntervalSince(lastChange) < deviceChangeDebounce {
            return  // Ignore rapid-fire duplicate notifications
        }
        lastDeviceChangeTime = now

        AppLogger.audioSystem.info("Output device changed, proactively reconfiguring tap")

        // Trigger recovery immediately (don't wait for watchdog to detect silence)
        // This minimizes audio gap from ~3s (watchdog) to ~200ms (proactive)
        recoverFromOutputChange()
    }

    /// Removes the device change listener during cleanup
    private func stopDeviceChangeListener() {
        guard let block = deviceChangeListenerBlock else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )

        if status == noErr {
            AppLogger.audioSystem.info("Device change listener removed")
        }
        deviceChangeListenerBlock = nil
    }

    // MARK: - Buffer Statistics Methods (thread-safe)

    /// Increments total buffer count, optionally marking it as having data
    private func incrementStats(hasData: Bool) {
        statsLock.lock()
        _totalBuffers += 1
        if hasData { _buffersWithData += 1 }
        statsLock.unlock()
    }

    /// Increments dropped buffer count
    private func incrementDropped() {
        statsLock.lock()
        _buffersDropped += 1
        statsLock.unlock()
    }

    /// Marks the current buffer as having valid data
    private func markBufferHasData() {
        statsLock.lock()
        _buffersWithData += 1
        statsLock.unlock()
    }

    /// Logs buffer statistics summary (call during cleanup)
    private func logStats() {
        statsLock.lock()
        let total = _totalBuffers
        let withData = _buffersWithData
        let dropped = _buffersDropped
        statsLock.unlock()

        guard total > 0 else { return }

        let successRate = Double(withData) / Double(total) * 100
        AppLogger.audioSystem.info("Buffer stats", ["total": "\(total)", "withData": "\(withData)", "successRate": String(format: "%.1f%%", successRate), "dropped": "\(dropped)"])

        // Warn if significant buffer loss detected
        if withData < total / 2 {
            AppLogger.audioSystem.warning("More than 50% of system audio buffers were empty - device issues likely occurred")
        }
    }

    /// Resets buffer statistics (call when starting new session)
    private func resetStats() {
        statsLock.lock()
        _totalBuffers = 0
        _buffersWithData = 0
        _buffersDropped = 0
        statsLock.unlock()
    }

    private func recoverFromOutputChange() {
        // CRITICAL: Prevent concurrent recovery attempts
        // Multiple device changes can fire rapidly, and Thread.sleep blocks
        // Without this guard, concurrent recoveries cause deadlock (spinning beach ball)
        guard !isRecovering else {
            AppLogger.audioSystem.warning("Recovery already in progress, skipping duplicate request")
            return
        }
        isRecovering = true
        defer { isRecovering = false }

        AppLogger.audioSystem.info("Recovering from system audio output change")

        // Store current callback - we'll need it after cleanup
        guard let callback = self.bufferCallback else {
            AppLogger.audioSystem.error("No buffer callback available for recovery")
            return
        }

        // Step 1: Full cleanup of old tap/aggregate device
        // Order matters: log stats, cleanup devices (preserve listener for future changes)
        logStats()
        cleanupDevicesOnly()
        resetStats()

        // Step 2: HAL settle time - CRITICAL
        // The aggregate device is not ready immediately after the CoreAudio API call returns
        // Mozilla cubeb-coreaudio-rs and Apple developer forums recommend 100ms delay
        // Without this, the new tap may fail or produce garbage data
        Thread.sleep(forTimeInterval: 0.15)  // 150ms (slightly longer for stability)

        // Step 3: Recreate tap targeting the new default output device
        do {
            try setupSystemAudioTap()
            try startAudioDevice()

            // Restore callback and reset watchdog
            self.bufferCallback = callback
            lastBufferTime = Date()

            AppLogger.audioSystem.info("Device recovery complete", ["estimatedGap": "~250ms"])

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.errorMessage = "Switched to new output device"

                // Clear status message after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self = self else { return }
                    if self.errorMessage == "Switched to new output device" {
                        self.errorMessage = nil
                    }
                }
            }
        } catch {
            AppLogger.audioSystem.error("Failed to recover from output change", ["error": error.localizedDescription])
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.errorMessage = "System audio unavailable"
                self.isCapturing = false
                self.stopWatchdog()
            }
        }
    }

    /// Cleanup only the audio devices, preserving the device change listener
    /// Used during recovery to minimize teardown/rebuild time
    private func cleanupDevicesOnly() {
        // Step 1 & 2: Stop device and destroy I/O proc
        if aggregateDeviceID.isValid {
            _ = AudioDeviceStop(aggregateDeviceID, deviceProcID)

            if let deviceProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                self.deviceProcID = nil
            }
        }

        // Step 3: Destroy aggregate device
        if aggregateDeviceID.isValid {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }

        // Step 4: Destroy the process tap
        if processTapID.isValid {
            _ = AudioHardwareDestroyProcessTap(processTapID)
            processTapID = .unknown
        }

        // Keep bufferCallback - we need it for recovery
        isPrepared = false
    }

    deinit {
        stopWatchdog()
        cleanup()
    }
}
