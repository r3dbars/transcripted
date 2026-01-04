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

    init() {}

    /// Prepares the system audio tap without starting capture
    /// Call this first, then use audioFormat to create your file, then call start()
    /// This separation prevents disk I/O from blocking the audio callback thread
    func prepare() throws {
        guard !isPrepared else {
            print("⚠️ SystemAudioCapture: Already prepared")
            return
        }

        print("🔊 Setting up system audio tap...")
        try setupSystemAudioTap()
        isPrepared = true
        print("🔊 System audio tap created successfully, format: \(audioFormat?.sampleRate ?? 0)Hz, \(audioFormat?.channelCount ?? 0)ch")
    }

    /// Starts capturing system audio and calls the callback with each buffer
    /// If prepare() wasn't called, this will call it automatically
    func start(bufferCallback: @escaping (AVAudioPCMBuffer) -> Void) throws {
        print("🔊 SystemAudioCapture.start() called")
        guard !isCapturing else {
            print("⚠️ SystemAudioCapture: Already capturing, ignoring")
            return
        }

        self.bufferCallback = bufferCallback
        errorMessage = nil

        do {
            // Setup tap if not already prepared
            if !isPrepared {
                print("🔊 Preparing tap in start()...")
                try prepare()
            }

            print("🔊 Starting audio device...")
            try startAudioDevice()
            print("🔊 Audio device started successfully")

            DispatchQueue.main.async {
                self.isCapturing = true
                self.startWatchdog()
            }
            print("🔊 SystemAudioCapture: Now capturing!")
        } catch {
            let errMsg = "Failed to start system audio capture: \(error.localizedDescription)"
            print("❌ SystemAudioCapture ERROR: \(errMsg)")
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
                print("⚠️ I/O Proc: self or bufferCallback is nil")
                return
            }

            callbackCount += 1
            if callbackCount <= 3 {
                print("🔊 I/O Proc callback #\(callbackCount)")
            }

            do {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                    print("❌ I/O Proc: Failed to create PCM buffer")
                    throw "Failed to create PCM buffer"
                }

                if callbackCount <= 3 {
                    print("🔊 Buffer created: \(buffer.frameLength) frames")
                }

                // Update watchdog timestamp
                self.lastBufferTime = Date()

                // Send buffer to callback
                bufferCallback(buffer)
            } catch {
                print("❌ I/O Proc error: \(error)")
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
        print("🧹 Cleaning up system audio capture...")

        // Cleanup order is important to minimize CoreAudio internal warnings:
        // 1. Stop the device first (stops I/O callbacks)
        // 2. Destroy the I/O proc (releases callback reference)
        // 3. Destroy the aggregate device (releases sub-devices)
        // 4. Destroy the process tap last (it depends on nothing else)
        //
        // Note: Some CoreAudio warnings like "AudioObjectRemovePropertyListener: no object"
        // may still appear during cleanup - these are internal framework race conditions
        // that don't affect functionality.

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
                print("✓ Aggregate device destroyed")
            }
            // Don't log warnings for cleanup failures - they're expected race conditions
            aggregateDeviceID = .unknown
        }

        // Step 4: Destroy the process tap last
        if processTapID.isValid {
            let result = AudioHardwareDestroyProcessTap(processTapID)
            if result == noErr {
                print("✓ Process tap destroyed")
            }
            // Don't log warnings for cleanup failures - they're expected race conditions
            processTapID = .unknown
        }

        bufferCallback = nil
        isPrepared = false
        print("✓ System audio cleanup complete")
    }

    private func startWatchdog() {
        lastBufferTime = Date()
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isCapturing else { return }

            let timeSinceLastBuffer = Date().timeIntervalSince(self.lastBufferTime)

            if timeSinceLastBuffer > 3.0 {
                // System audio stopped → output device likely changed
                print("⚠️ System audio output device disconnected or changed, attempting recovery...")
                self.recoverFromOutputChange()
            }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func recoverFromOutputChange() {
        print("🔄 Recovering from system audio output change...")

        // Store current callback
        guard let callback = self.bufferCallback else {
            print("❌ No buffer callback available for recovery")
            return
        }

        // Cleanup old devices
        cleanup()

        // Attempt to recreate tap with new default output
        do {
            try setupSystemAudioTap()
            try startAudioDevice()

            lastBufferTime = Date() // Reset watchdog
            print("✅ System audio device recovery complete, capturing continues")

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.errorMessage = "Switched to default output"

                // Clear error after 3 seconds (use weak self to prevent retain)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self = self else { return }
                    if self.errorMessage == "Switched to default output" {
                        self.errorMessage = nil
                    }
                }
            }
        } catch {
            print("❌ Failed to recover from output change: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.errorMessage = "System audio unavailable"
                self.isCapturing = false
                self.stopWatchdog()
            }
        }
    }

    deinit {
        stopWatchdog()
        cleanup()
    }
}
