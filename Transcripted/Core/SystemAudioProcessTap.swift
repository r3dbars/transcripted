import Foundation
import AudioToolbox
import AVFoundation

// MARK: - CoreAudio Process Tap Setup

/// Extension handling CoreAudio process tap creation, aggregate device setup, and format negotiation.
/// Runs on audio threads — NOT @MainActor.
@available(macOS 14.2, *)
extension SystemAudioCapture {

    // MARK: - Tap Setup

    func setupSystemAudioTap() throws {
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
        // Security: avoid force-unwrap — a nil crash here is a denial-of-service.
        // tapStreamDescription was assigned via `try` above, but guard defensively in case
        // code flow ever changes and nil reaches this point.
        if var currentDesc = tapStreamDescription, deviceNominalRate > 0, deviceNominalRate != currentDesc.mSampleRate {
            AppLogger.audioSystem.warning("Tap format rate (\(Int(currentDesc.mSampleRate))Hz) differs from device nominal rate (\(Int(deviceNominalRate))Hz) — correcting")
            currentDesc.mSampleRate = deviceNominalRate
            tapStreamDescription = currentDesc
        }
        AppLogger.audioSystem.info("Aggregate device nominal sample rate", ["rate": "\(Int(deviceNominalRate))"])
    }

    // MARK: - Audio Device I/O

    func startAudioDevice() throws {
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
                // CACurrentMediaTime() is allocation-free and safe for real-time threads
                self.lastBufferTime = CACurrentMediaTime()
                if !self.hasReceivedFirstBuffer {
                    self.hasReceivedFirstBuffer = true
                }
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

    // MARK: - Cleanup

    func cleanup() {
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

    /// Cleanup only the audio devices, preserving the device change listener
    /// Used during recovery to minimize teardown/rebuild time
    func cleanupDevicesOnly() {
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
}
