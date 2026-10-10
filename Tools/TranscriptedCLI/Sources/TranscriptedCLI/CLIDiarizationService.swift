import ArgumentParser
import Foundation

#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
import TranscriptedCore

/// Runs the app's `DiarizationService` for `diarize` / `batch` so those
/// commands share Nemotron (and its 10 s slices) with `import-audio`.
enum CLIDiarizationService {
    @MainActor
    static func make(backend: DiarizationBackend, modelsDir: String?) -> DiarizationService {
        var pyannote: URL?
        var nemotron: URL?
        if let modelsDir {
            let url = URL(fileURLWithPath: modelsDir, isDirectory: true)
            if MeetingImportModels.completeNemotronModels(at: url) {
                nemotron = url
                pyannote = MeetingImportModels.bundledDiarizationModels()
            } else if let root = MeetingImportModels.fluidAudioRoot(for: url) {
                pyannote = root
                nemotron = MeetingImportModels.bundledNemotronModels()
            } else {
                pyannote = url
                nemotron = MeetingImportModels.bundledNemotronModels()
            }
        } else {
            pyannote = MeetingImportModels.bundledDiarizationModels()
            nemotron = MeetingImportModels.bundledNemotronModels()
        }
        return DiarizationService(
            bundleProvider: MeetingImportDiarization.bundleProvider(pyannote: pyannote, nemotron: nemotron),
            backend: backend
        )
    }

    static func readyService(backend: DiarizationBackend, modelsDir: String?) async throws -> DiarizationService {
        setenv("TRANSCRIPTED_DISABLE_FILE_LOGGER", "1", 1)
        let service = await MainActor.run { make(backend: backend, modelsDir: modelsDir) }
        await service.initialize()
        let ready = await MainActor.run { service.isReady }
        guard ready else {
            throw ValidationError("Diarization models failed to load for \(backend.rawValue).")
        }
        return service
    }

    static func segments(service: DiarizationService, audioURL: URL) async throws -> [SpeakerSegment] {
        let decoded = try await TranscribeMediaLoader.loadSamples(from: audioURL)
        return try await service.diarizeOffline(samples: decoded.samples, sampleRate: 16000)
    }

    static func rttmSegments(from segments: [SpeakerSegment]) -> [(speakerId: String, start: Double, end: Double)] {
        segments.map { (speakerId: String($0.speakerId), start: $0.startTime, end: $0.endTime) }
    }

    static func writeJSON(segments: [SpeakerSegment], audioPath: String, elapsed: TimeInterval, to path: String?) throws {
        struct JSONOutput: Encodable {
            let audioFile: String
            let segments: [SegmentOutput]
            let speakerCount: Int
            let processingSeconds: Double
        }
        struct SegmentOutput: Encodable {
            let speakerId: String
            let startSeconds: Double
            let endSeconds: Double
            let durationSeconds: Double
            let qualityScore: Float
        }
        let output = JSONOutput(
            audioFile: audioPath,
            segments: segments.map {
                SegmentOutput(
                    speakerId: String($0.speakerId),
                    startSeconds: $0.startTime,
                    endSeconds: $0.endTime,
                    durationSeconds: $0.duration,
                    qualityScore: $0.qualityScore
                )
            },
            speakerCount: Set(segments.map(\.speakerId)).count,
            processingSeconds: elapsed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output)
        if let path {
            try data.write(to: URL(fileURLWithPath: path))
        } else {
            print(String(data: data, encoding: .utf8)!)
        }
    }
}
#endif
