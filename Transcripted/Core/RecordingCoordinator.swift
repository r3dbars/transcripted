import Foundation
import AppKit

// MARK: - Recording Lifecycle & Orphaned File Cleanup

@available(macOS 26.0, *)
extension AppDelegate {

    @objc func toggleRecording() {
        guard let audio = audio else { return }
        if audio.isRecording {
            audio.stop()
        } else {
            audio.start()
        }
    }

    /// Handle recording completion - trigger transcription
    func handleRecordingComplete(micURL: URL?, systemURL: URL?) {
        guard let micURL = micURL else {
            AppLogger.app.error("No mic audio file available")
            return
        }

        AppLogger.app.info("Recording complete — starting transcription")

        // Capture recording health info before it gets reset (Phase 3: Post-hoc transparency)
        let healthInfo = audio?.createHealthInfo()
        if let health = healthInfo {
            AppLogger.app.info("Recording health", ["quality": health.captureQuality.rawValue, "gaps": "\(health.audioGaps)", "switches": "\(health.deviceSwitches)"])
        }

        // Get output folder from settings, with path safety validation
        var outputFolder: URL
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            let candidateURL = URL(fileURLWithPath: customPath)
            let validation = RecordingValidator.validateSavePath(candidateURL)
            if validation.isValid {
                outputFolder = candidateURL
            } else {
                AppLogger.app.warning("Custom save path rejected, falling back to default", ["path": customPath, "reason": validation.errorMessage ?? "unknown"])
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                outputFolder = documentsPath.appendingPathComponent("Transcripted")
            }
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            outputFolder = documentsPath.appendingPathComponent("Transcripted")
        }

        // Create output folder if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        } catch {
            AppLogger.pipeline.error("Failed to create output folder", ["error": error.localizedDescription, "path": outputFolder.path])
        }

        // Start transcription in background using task manager
        taskManager?.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: outputFolder,
            healthInfo: healthInfo
        )
    }

    /// Delete orphaned audio files (meeting_*_mic.wav, meeting_*_system.wav) that are not
    /// referenced by the failed transcription queue. These can persist after crashes when
    /// the app exits between recording and transcription completion.
    func cleanupOrphanedAudioFiles(failedManager: FailedTranscriptionManager) {
        let saveDir = TranscriptSaver.defaultSaveDirectory
        guard FileManager.default.fileExists(atPath: saveDir.path) else { return }

        // Collect all audio URLs referenced by the failed transcription queue
        var referencedPaths: Set<String> = []
        for failed in failedManager.failedTranscriptions {
            referencedPaths.insert(failed.micAudioURL.path)
            if let systemURL = failed.systemAudioURL {
                referencedPaths.insert(systemURL.path)
            }
        }

        // Scan for orphaned meeting audio files
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: saveDir,
            includingPropertiesForKeys: nil
        ) else { return }

        var deletedCount = 0
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            guard name.hasPrefix("meeting_"),
                  (name.hasSuffix("_mic.wav") || name.hasSuffix("_system.wav")),
                  !referencedPaths.contains(fileURL.path) else { continue }

            do {
                try FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
            } catch {
                AppLogger.app.warning("Failed to delete orphaned audio file", ["file": name, "error": error.localizedDescription])
            }
        }

        if deletedCount > 0 {
            AppLogger.app.info("Cleaned up orphaned audio files", ["count": "\(deletedCount)"])
        }
    }

    /// Pre-cache Qwen model so it's ready for first recording.
    /// Downloads model files if enabled but not yet cached, then frees memory.
    static func preCacheQwenIfNeeded() async {
        guard QwenService.isEnabled, !QwenService.isModelCached else { return }
        AppLogger.app.info("Pre-caching Qwen model in background")
        let qwen = QwenService()
        await qwen.loadModel()
        switch qwen.modelState {
        case .ready:
            qwen.unload()  // Free memory — just wanted to cache the files
            AppLogger.app.info("Qwen model pre-cached successfully")
        case .failed(let error):
            AppLogger.app.error("Qwen model pre-cache failed", ["error": error])
        default:
            AppLogger.app.warning("Qwen model pre-cache ended in unexpected state")
        }
    }
}
