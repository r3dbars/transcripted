import Foundation
import AVFoundation
import UserNotifications

// MARK: - Transcription Task Queue & Orchestration
// Extensions in: QwenLifecycleManager.swift, SpeakerNamingCoordinator.swift,
//                TranscriptionPipelineRunner.swift
// Types in: DisplayStatus.swift (DisplayStatus enum, TranscriptionTask struct)

@available(macOS 26.0, *)
@MainActor
class TranscriptionTaskManager: ObservableObject {
    @Published var activeCount: Int = 0
    @Published var justCompleted: Bool = false
    @Published var displayStatus: DisplayStatus = .idle
    @Published var backgroundTaskCount: Int = 0
    @Published var speakerNamingRequest: SpeakerNamingRequest? = nil
    @Published var lastSavedTranscriptURL: URL? = nil
    @Published var lastSavedTitle: String? = nil
    @Published var lastSavedDuration: String? = nil
    @Published var lastSavedSpeakerCount: Int? = nil

    var activeTasks: [UUID: Task<Void, Never>] = [:]
    let transcription = Transcription()

    /// Pre-loaded Qwen service — loaded when recording starts, consumed by pipeline
    var qwenService: QwenService?
    var qwenPreloadTask: Task<Void, Never>?
    var qwenTimeoutTask: Task<Void, Never>?

    let failedTranscriptionManager: FailedTranscriptionManager

    init(failedTranscriptionManager: FailedTranscriptionManager) {
        self.failedTranscriptionManager = failedTranscriptionManager
    }

    // MARK: - Task Lifecycle

    /// Start a new transcription task in the background
    func startTranscription(micURL: URL, systemURL: URL?, outputFolder: URL, healthInfo: RecordingHealthInfo? = nil) {

        // Cancel the pre-load timeout — the pipeline will handle Qwen cleanup itself
        qwenTimeoutTask?.cancel()
        qwenTimeoutTask = nil

        // Gate: reject recordings shorter than 2 seconds (they'll fail in Parakeet anyway)
        let minDuration: TimeInterval = 2.0
        if let micDuration = audioDuration(url: micURL), micDuration < minDuration {
            AppLogger.pipeline.info("Recording too short, skipping transcription", ["duration": String(format: "%.1fs", micDuration)])

            try? FileManager.default.removeItem(at: micURL)
            if let systemURL { try? FileManager.default.removeItem(at: systemURL) }

            cleanupQwen()

            self.displayStatus = .failed(message: "Recording too short")
            self.scheduleStatusReset(delay: 3)
            return
        }

        let task = TranscriptionTask(micURL: micURL, systemURL: systemURL, outputFolder: outputFolder, healthInfo: healthInfo)

        activeCount += 1
        backgroundTaskCount += 1
        displayStatus = .gettingReady

        AppLogger.pipeline.info("Starting transcription task", ["taskId": "\(task.id)", "activeCount": "\(activeCount)"])

        startQwenTimeout()

        let asyncTask = Task {
            do {
                await MainActor.run {
                    self.displayStatus = .transcribing(progress: 0.0)
                }

                let transcriptURL = try await self.transcribeWithSpeakerIdentification(
                    micURL: micURL,
                    systemURL: systemURL,
                    outputFolder: outputFolder,
                    taskId: task.id,
                    healthInfo: task.healthInfo
                )

                await MainActor.run {
                    self.populateSavedMetadata(from: transcriptURL)
                    self.displayStatus = .transcriptSaved
                    self.scheduleStatusReset(delay: 4)
                }

                await MainActor.run {
                    self.handleTaskCompletion(taskId: task.id)
                }

            } catch {
                AppLogger.pipeline.error("Transcription task failed", ["taskId": "\(task.id)", "error": "\(error.localizedDescription)"])

                await MainActor.run {
                    self.displayStatus = .failed(message: "Transcription failed")
                    self.failedTranscriptionManager.addFailedTranscription(
                        micAudioURL: micURL,
                        systemAudioURL: systemURL,
                        errorMessage: error.localizedDescription
                    )
                    self.sendFailureNotification(errorMessage: error.localizedDescription)
                    self.handleTaskCompletion(taskId: task.id)
                }
            }
        }

        activeTasks[task.id] = asyncTask
    }

    /// Retry a failed transcription by its ID
    func retryFailedTranscription(failedId: UUID) async -> Bool {
        guard let failed = failedTranscriptionManager.failedTranscriptions.first(where: { $0.id == failedId }) else {
            AppLogger.pipeline.error("Failed transcription not found", ["failedId": "\(failedId)"])
            return false
        }

        guard failed.isRetryable else {
            AppLogger.pipeline.info("Skipping retry — failure is permanent", ["failedId": "\(failedId)", "error": failed.errorMessage])
            return false
        }

        guard failed.audioFilesExist() else {
            AppLogger.pipeline.error("Audio files no longer exist for failed transcription", ["failedId": "\(failedId)"])
            await MainActor.run {
                failedTranscriptionManager.removeFailedTranscription(id: failedId)
            }
            return false
        }

        AppLogger.pipeline.info("Retrying failed transcription", ["failedId": "\(failedId)"])

        await MainActor.run {
            failedTranscriptionManager.incrementRetryCount(id: failedId)
            self.activeCount += 1
            self.backgroundTaskCount += 1
            self.displayStatus = .gettingReady
        }

        do {
            let transcriptURL = try await transcribeWithSpeakerIdentification(
                micURL: failed.micAudioURL,
                systemURL: failed.systemAudioURL,
                outputFolder: TranscriptSaver.defaultSaveDirectory,
                taskId: failedId,
                healthInfo: nil
            )

            AppLogger.pipeline.info("Retry successful", ["file": transcriptURL.lastPathComponent])

            await MainActor.run {
                failedTranscriptionManager.removeFailedTranscription(id: failedId)
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                self.populateSavedMetadata(from: transcriptURL)
                self.displayStatus = .transcriptSaved
                self.scheduleStatusReset(delay: 4)
            }

            return true

        } catch {
            AppLogger.pipeline.error("Retry failed", ["error": "\(error.localizedDescription)"])
            await MainActor.run {
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                self.displayStatus = .failed(message: "Retry failed")
                self.scheduleStatusReset(delay: 8)
            }
            return false
        }
    }

    // MARK: - Task Completion & Cleanup

    func handleTaskCompletion(taskId: UUID) {
        activeTasks.removeValue(forKey: taskId)
        activeCount -= 1
        backgroundTaskCount = max(0, backgroundTaskCount - 1)

        AppLogger.pipeline.info("Task cleaned up", ["taskId": "\(taskId)", "remaining": "\(activeCount)", "backgroundTasks": "\(backgroundTaskCount)"])

        if activeCount == 0 {
            justCompleted = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.justCompleted = false
            }
        }
    }

    func cancelAll() {
        for (taskId, task) in activeTasks {
            task.cancel()
            AppLogger.pipeline.info("Cancelled task", ["taskId": "\(taskId)"])
        }
        activeTasks.removeAll()
        activeCount = 0
        backgroundTaskCount = 0
        displayStatus = .idle
    }

    /// Populate saved transcript metadata from the file's YAML frontmatter.
    /// Reads only the first 2 KB to avoid blocking the main thread on large transcript files.
    func populateSavedMetadata(from url: URL) {
        lastSavedTranscriptURL = url
        let name = url.deletingPathExtension().lastPathComponent
        lastSavedTitle = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        let headerData = handle.readData(ofLength: 2048)
        try? handle.close()
        guard let raw = String(data: headerData, encoding: .utf8),
              raw.hasPrefix("---"),
              let endRange = raw.range(of: "\n---\n", range: raw.index(raw.startIndex, offsetBy: 3)..<raw.endIndex)
        else { return }
        let yaml = String(raw[raw.index(raw.startIndex, offsetBy: 4)..<endRange.lowerBound])
        var speakers = 0
        for line in yaml.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "duration": lastSavedDuration = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "mic_speakers", "system_speakers": speakers += Int(parts[1]) ?? 0
            default: break
            }
        }
        lastSavedSpeakerCount = speakers
    }

    func scheduleStatusReset(delay: TimeInterval = 3) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            // Don't reset if speaker naming is in progress —
            // SpeakerNamingCoordinator will re-publish .transcriptSaved when done
            guard self.speakerNamingRequest == nil else { return }
            switch self.displayStatus {
            case .transcriptSaved, .failed:
                self.displayStatus = .idle
            default:
                break
            }
        }
    }

    // MARK: - Utilities

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                AppLogger.app.info("Notification permission granted")
            } else if let error = error {
                AppLogger.app.warning("Notification permission error", ["error": "\(error.localizedDescription)"])
            }
        }
    }

    func audioDuration(url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = Double(file.length)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return frames / sampleRate
    }

    func sendFailureNotification(errorMessage: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.pipeline.debug("Skipping failure notification — not authorized")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Transcription Failed"
            content.body = "Recording saved. Tap to retry."
            content.sound = .default
            content.categoryIdentifier = "TRANSCRIPTION_FAILURE"
            content.userInfo = ["errorMessage": errorMessage]

            let request = UNNotificationRequest(
                identifier: "transcription-failure-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    AppLogger.app.warning("Failed to send notification", ["error": "\(error.localizedDescription)"])
                }
            }
        }
    }
}
