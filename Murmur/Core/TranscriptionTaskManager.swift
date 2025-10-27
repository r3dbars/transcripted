import Foundation
import Speech

struct TranscriptionTask: Identifiable {
    let id: UUID
    let micURL: URL
    let systemURL: URL?
    let outputFolder: URL
    let startTime: Date

    init(micURL: URL, systemURL: URL?, outputFolder: URL) {
        self.id = UUID()
        self.micURL = micURL
        self.systemURL = systemURL
        self.outputFolder = outputFolder
        self.startTime = Date()
    }
}

@available(macOS 26.0, *)
class TranscriptionTaskManager: ObservableObject {
    @Published var activeCount: Int = 0
    @Published var justCompleted: Bool = false

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private let transcription = Transcription()

    /// Start a new transcription task in the background
    func startTranscription(micURL: URL, systemURL: URL?, outputFolder: URL) {
        let task = TranscriptionTask(micURL: micURL, systemURL: systemURL, outputFolder: outputFolder)

        // Increment active count immediately
        DispatchQueue.main.async {
            self.activeCount += 1
        }

        print("📝 Starting transcription task \(task.id) (active: \(activeCount))")

        // Create async task
        let asyncTask = Task {
            do {
                let transcriptURL = try await transcription.transcribeMeetingFiles(
                    micURL: micURL,
                    systemURL: systemURL,
                    outputFolder: outputFolder
                )

                print("✅ Transcription task \(task.id) complete: \(transcriptURL.lastPathComponent)")

                await MainActor.run {
                    self.handleTaskCompletion(taskId: task.id)
                }

            } catch {
                print("❌ Transcription task \(task.id) failed: \(error.localizedDescription)")

                await MainActor.run {
                    self.handleTaskCompletion(taskId: task.id)
                }
            }
        }

        activeTasks[task.id] = asyncTask
    }

    private func handleTaskCompletion(taskId: UUID) {
        // Remove from active tasks
        activeTasks.removeValue(forKey: taskId)
        activeCount -= 1

        print("✓ Task \(taskId) cleaned up (remaining: \(activeCount))")

        // Show completion checkmark if this was the last task
        if activeCount == 0 {
            justCompleted = true

            // Reset flag after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.justCompleted = false
            }
        }
    }

    /// Cancel all active transcription tasks
    func cancelAll() {
        for (taskId, task) in activeTasks {
            task.cancel()
            print("🚫 Cancelled task \(taskId)")
        }
        activeTasks.removeAll()
        activeCount = 0
    }
}

