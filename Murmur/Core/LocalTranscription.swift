import Foundation
import AVFoundation

// MARK: - LocalTranscriptionResult
// Mirrors MultichannelTranscriptionResult so downstream code stays unchanged.

@available(macOS 14.2, *)
struct LocalTranscriptionSessionResult {
    let utterances: [LocalUtterance]
    let duration: TimeInterval
    let processingTime: TimeInterval
    let nameMatches: [NameMatch]          // Inferred name↔speakerId mappings
    let unresolvedSpeakers: [String]      // Speaker IDs with no name yet

    /// All unique speaker IDs in the session
    var speakerIds: Set<String> {
        Set(utterances.map { $0.speakerId })
    }

    /// Format the full transcript as markdown (matches TranscriptSaver expectations)
    func toMarkdown(using db: VoiceProfileDatabase) -> String {
        var lines: [String] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "[mm:ss]"
        let epoch = Date(timeIntervalSince1970: 0)

        for u in utterances {
            let ts = formatter.string(from: epoch.addingTimeInterval(u.start))
            let speaker = u.displayName(using: db)
            lines.append("\(ts) **\(speaker)**: \(u.transcript)")
        }
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - LocalTranscription

/// Orchestrates the full local AI transcription pipeline:
///   Parakeet (STT) + Sortformer (diarization) + NameInferenceEngine + VoiceProfileDatabase
///
/// Usage:
///   let result = try await LocalTranscription.shared.transcribe(
///       micURL: micFile, systemURL: sysFile
///   )
///
/// This is a drop-in companion to Transcription.swift — uses the same
/// progress callback signature so TranscriptionTaskManager can switch
/// between Deepgram and Local with a single bool flag.
@available(macOS 14.2, *)
@MainActor
final class LocalTranscription: ObservableObject {

    static let shared = LocalTranscription()

    @Published var isProcessing: Bool = false
    @Published var error: String?
    @Published var processingStatus: String = ""
    @Published var serverReady: Bool = false

    private let voiceDB = VoiceProfileDatabase.shared

    private init() {
        Task { await checkServerStatus() }
    }

    // MARK: - Server lifecycle

    func checkServerStatus() async {
        let (_, ready) = await LocalTranscriptionService.serverStatus()
        serverReady = ready
    }

    func startServer() {
        do {
            try LocalTranscriptionService.startServer()
            // Poll until ready (models take ~30s to load)
            Task {
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                    let (_, ready) = await LocalTranscriptionService.serverStatus()
                    if ready {
                        await MainActor.run { self.serverReady = true }
                        print("✅ Local inference server ready")
                        return
                    }
                }
                print("⚠️ Local inference server didn't become ready in 60s")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Transcription

    /// Full pipeline: merge audio → transcribe → diarize → infer names → update profiles
    nonisolated func transcribe(
        micURL: URL,
        systemURL: URL,
        meetingTitle: String? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> LocalTranscriptionSessionResult {

        let t0 = Date()

        await MainActor.run {
            self.isProcessing = true
            self.error = nil
            self.processingStatus = "Preparing audio..."
        }

        onProgress?(0.0)

        // Step 1: Merge mic + system into stereo WAV
        await setStatus("Merging audio channels...")
        let stereoURL = try await AudioPreprocessor.prepareMergedStereoForCloud(
            micURL: micURL,
            systemURL: systemURL
        )
        defer { AudioPreprocessor.cleanup(tempURL: stereoURL) }

        onProgress?(0.10)

        // Step 2: Send to local inference server
        await setStatus("Transcribing with Parakeet...")
        let response = try await LocalTranscriptionService.transcribeStereo(
            stereoURL: stereoURL,
            onStatusUpdate: { status in
                Task { await self.setStatus(status) }
            }
        )

        onProgress?(0.75)

        // Step 3: Infer names from conversation patterns
        await setStatus("Identifying speakers...")
        let nameMatches = await NameInferenceEngine.inferNames(
            from: response.utterances,
            calendarEventTitle: meetingTitle
        )

        // Step 4: Apply high-confidence names to voice profile DB
        await MainActor.run {
            NameInferenceEngine.applyMatches(nameMatches, to: VoiceProfileDatabase.shared)

            // Also update call counts for all speakers seen in this session
            for speakerId in Set(response.utterances.map { $0.speakerId }) {
                VoiceProfileDatabase.shared.upsert(speakerId: speakerId)
            }
        }

        onProgress?(0.95)

        let unresolvedSpeakers = Set(response.utterances.map { $0.speakerId })
            .filter { VoiceProfileDatabase.shared.name(for: $0) == nil }
            .sorted()

        let processingTime = Date().timeIntervalSince(t0)

        await MainActor.run {
            self.isProcessing = false
            self.processingStatus = ""
        }

        onProgress?(1.0)

        print("✅ Local transcription complete:")
        print("   • Duration: \(String(format: "%.1f", response.duration))s")
        print("   • Processing: \(String(format: "%.1f", processingTime))s "
            + "(\(String(format: "%.0f", response.duration / processingTime))x real-time)")
        print("   • Speakers: \(response.speakerCount)")
        print("   • Names inferred: \(nameMatches.count)")
        print("   • Unresolved speakers: \(unresolvedSpeakers.count)")

        return LocalTranscriptionSessionResult(
            utterances: response.utterances,
            duration: response.duration,
            processingTime: processingTime,
            nameMatches: nameMatches,
            unresolvedSpeakers: unresolvedSpeakers
        )
    }

    private func setStatus(_ status: String) async {
        await MainActor.run { self.processingStatus = status }
    }
}

// MARK: - TranscriptionProvider

/// Settings-driven toggle between Deepgram (cloud) and Local (on-device).
enum TranscriptionProvider: String, CaseIterable {
    case deepgram = "deepgram"
    case local    = "local"

    var displayName: String {
        switch self {
        case .deepgram: return "Deepgram (Cloud)"
        case .local:    return "On-Device (Parakeet)"
        }
    }

    var requiresAPIKey: Bool {
        self == .deepgram
    }

    var privacyDescription: String {
        switch self {
        case .deepgram:
            return "Audio is sent to Deepgram's servers for transcription."
        case .local:
            return "Audio never leaves your Mac. Requires one-time model download (~2.5GB)."
        }
    }

    static var current: TranscriptionProvider {
        let raw = UserDefaults.standard.string(forKey: "transcriptionProvider") ?? "deepgram"
        return TranscriptionProvider(rawValue: raw) ?? .deepgram
    }

    static func setCurrent(_ provider: TranscriptionProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: "transcriptionProvider")
    }
}
