import Foundation
import AudioToolbox
import AVFoundation
import QuartzCore  // CACurrentMediaTime — real-time-safe monotonic clock

// MARK: - Buffer Statistics, Device Change Listener & Recovery

/// Extension handling buffer statistics tracking, device change notifications, and recovery logic.
/// Runs on audio threads — NOT @MainActor.
@available(macOS 14.2, *)
extension SystemAudioCapture {

    // MARK: - Watchdog Timer

    func startWatchdog() {
        lastBufferTime = CACurrentMediaTime()
        hasReceivedFirstBuffer = false
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isCapturing else { return }

            // Don't trigger recovery before we've received any buffers —
            // CoreAudio tap startup can take 100-200ms on some devices
            guard self.hasReceivedFirstBuffer else { return }

            let timeSinceLastBuffer = CACurrentMediaTime() - self.lastBufferTime

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

    func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: - Proactive Device Change Listener Methods

    /// Starts listening for default output device changes
    /// This is the PROACTIVE approach used by OBS Studio, Mozilla Firefox, and professional audio apps
    /// Instead of waiting for silence (reactive), we detect device changes immediately
    func startDeviceChangeListener() {
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
        let now = CACurrentMediaTime()
        if let lastChange = lastDeviceChangeTime,
           (now - lastChange) < deviceChangeDebounce {
            return  // Ignore rapid-fire duplicate notifications
        }
        lastDeviceChangeTime = now

        AppLogger.audioSystem.info("Output device changed, proactively reconfiguring tap")

        // Trigger recovery immediately (don't wait for watchdog to detect silence)
        // This minimizes audio gap from ~3s (watchdog) to ~200ms (proactive)
        recoverFromOutputChange()
    }

    /// Removes the device change listener during cleanup
    func stopDeviceChangeListener() {
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
    func incrementStats(hasData: Bool) {
        statsLock.lock()
        _totalBuffers += 1
        if hasData { _buffersWithData += 1 }
        statsLock.unlock()
    }

    /// Increments dropped buffer count
    func incrementDropped() {
        statsLock.lock()
        _buffersDropped += 1
        statsLock.unlock()
    }

    /// Marks the current buffer as having valid data
    func markBufferHasData() {
        statsLock.lock()
        _buffersWithData += 1
        statsLock.unlock()
    }

    /// Logs buffer statistics summary (call during cleanup)
    func logStats() {
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
    func resetStats() {
        statsLock.lock()
        _totalBuffers = 0
        _buffersWithData = 0
        _buffersDropped = 0
        statsLock.unlock()
        hasReceivedFirstBuffer = false
    }

    // MARK: - Device Recovery

    func recoverFromOutputChange() {
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
            lastBufferTime = CACurrentMediaTime()

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
}
