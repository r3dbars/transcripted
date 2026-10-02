import Foundation
import AVFoundation

// MARK: - Utilities: notifications, audio duration, and cleanup-path safety

extension TranscriptionTaskManager {
    // MARK: - Utilities

    /// Ask the embedder to request system notification permission. No-op if no notifier
    /// was supplied at init.
    public func requestNotificationPermission() {
        notifier?.requestNotificationPermission()
    }

    func audioDuration(url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = Double(file.length)
        let sampleRate = file.processingFormat.sampleRate
        guard AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate) else { return nil }
        return frames / sampleRate
    }

    func sendFailureNotification(errorMessage: String) {
        guard let notifier else {
            AppLogger.pipeline.debug("Skipping failure notification — no notifier configured")
            return
        }
        notifier.notifyTranscriptionFailed(errorMessage: errorMessage)
    }

    @discardableResult
    nonisolated func removeRecordingFile(_ url: URL, label: String) -> Bool {
        // Security: only delete scratch files inside Transcripted-managed cleanup roots.
        // `startImportedTranscription` accepts a URL from the caller, so without a containment
        // check a misuse or tampered in-memory request could unlink arbitrary user files.
        guard isSafeCleanupURL(url) else {
            AppLogger.pipeline.error("Refused to delete out-of-sandbox recording file", [
                "label": label,
                "file": url.lastPathComponent
            ])
            return false
        }

        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            if (error as NSError).code == NSFileNoSuchFileError {
                return true
            }
            AppLogger.pipeline.warning("Failed to remove recording file", [
                "label": label,
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
            return false
        }
    }

    @discardableResult
    nonisolated func removeImportedRecordingFile(
        _ url: URL,
        recoverySession: (any ImportedTranscriptionRecoverySession)?,
        label: String
    ) -> Bool {
        guard recoverySession?.prepareForScratchCleanup() != false else { return false }
        return removeRecordingFile(url, label: label)
    }

    func resolvedRetainedAudioDirectory() -> URL? {
        retainedAudioDirectoryProvider?() ?? retainedAudioDirectory
    }

    func resolvedTranscriptFormatOptions(hasMicAudio: Bool, hasSystemAudio: Bool = true) -> TranscriptFormatOptions {
        var audioSources: [TranscriptAudioSource] = []
        if hasMicAudio {
            audioSources.append(.microphone)
        }
        if hasSystemAudio {
            audioSources.append(.systemAudio)
        }
        return (transcriptFormatOptionsProvider?() ?? .default)
            .withAudioSources(audioSources)
    }

    @discardableResult
    nonisolated func removeManagedCleanupFile(_ url: URL?, label: String) -> Bool {
        guard let url else { return true }
        return removeRecordingFile(url, label: label)
    }

    nonisolated func isSafeCleanupURL(_ url: URL) -> Bool {
        let canonicalURL = Self.canonicalURL(url)
        return cleanupDirectories.contains { root in
            Self.isFile(canonicalURL, containedIn: root)
        }
    }

    nonisolated static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    nonisolated static func canonicalDirectoryURL(_ url: URL) -> URL {
        canonicalURL(url)
    }

    nonisolated static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    nonisolated static func isFile(_ fileURL: URL, containedIn directoryURL: URL) -> Bool {
        let filePath = canonicalURL(fileURL).path
        let directoryPath = canonicalDirectoryURL(directoryURL).path
        let normalizedDirectoryPath = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath.hasPrefix(normalizedDirectoryPath)
    }
}
