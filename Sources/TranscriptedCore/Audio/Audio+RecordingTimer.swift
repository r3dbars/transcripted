import Foundation

extension Audio {

    // MARK: - Timer Management

    func startTimer() {
        timer?.invalidate()
        diskCheckCounter = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            DispatchQueue.main.async {
                self.recordingDuration = Date().timeIntervalSince(start)
            }

            // Live issue #500 attenuation detection. Always drain (even when
            // not recording) so an interval never spans ticks. Forcing
            // sawBuffer false while isMicRecovering resets the streak across
            // deliberate/automatic engine restarts. The cue fires directly
            // on main (this timer runs on the main run loop), matching where
            // stop() fires .recordingStopped.
            let interval = self.drainMicSignalIntervalDiagnostics()
            if self.isRecording,
               self.quietMicAttenuationDetector.consume(
                   rawPeak: interval.rawPeak,
                   processedPeak: interval.processedPeak,
                   appliedGain: interval.minAppliedGain,
                   agcMaxGain: interval.agcMaxGain,
                   sawBuffer: interval.sawBuffer && !self.isMicRecovering
               ) {
                let cueHandler = self.onCaptureLifecycleCue
                cueHandler?(.micAttenuatedByForeignVoiceProcessing)
            }

            // Periodic disk check during recording (~every 30s)
            self.diskCheckCounter += 1
            if self.diskCheckCounter >= 150 {
                self.diskCheckCounter = 0
                if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: self.paths.audioCaptures.path),
                   let freeSpace = attrs[FileAttributeKey.systemFreeSize] as? Int64 {
                    if freeSpace < 50_000_000 { // 50MB
                        AppLogger.audio.error("Disk space critically low during recording, stopping", ["freeSpace": "\(freeSpace / 1_000_000)MB"])
                        DispatchQueue.main.async {
                            self.error = "Recording stopped — disk space critically low (\(freeSpace / 1_000_000)MB free)"
                            self.stop()
                        }
                        return
                    } else if freeSpace < 100_000_000 { // 100MB
                        AppLogger.audio.warning("Disk space low during recording", ["freeSpace": "\(freeSpace / 1_000_000)MB"])
                    }
                }
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
        recordingDuration = 0.0
    }
}
