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
            let found = MeetingImportModels.diarizationModelsFromDirectory(url)
            if found.nemotron != nil || found.pyannote != nil {
                nemotron = found.nemotron ?? MeetingImportModels.bundledNemotronModels()
                pyannote = found.pyannote ?? MeetingImportModels.bundledDiarizationModels()
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

    struct Ready {
        let service: DiarizationService
        let selection: CLIDiarization.EngineSelection
    }

    static func readyService(
        backend: DiarizationBackend,
        modelsDir: String?,
        choice: String
    ) async throws -> Ready {
        setenv("TRANSCRIPTED_DISABLE_FILE_LOGGER", "1", 1)
        let service = await MainActor.run { make(backend: backend, modelsDir: modelsDir) }
        await service.initialize()
        let ready = await MainActor.run { service.isReady }
        guard ready else {
            throw ValidationError("Diarization models failed to load for \(backend.rawValue).")
        }
        let actual = await MainActor.run { service.activeBackend }
        do {
            let selection = try CLIDiarization.acceptLoadedEngine(
                requested: backend.rawValue,
                actual: actual.rawValue,
                choice: choice
            )
            return Ready(service: service, selection: selection)
        } catch {
            await MainActor.run { service.cleanup() }
            throw error
        }
    }

    static func segments(service: DiarizationService, audioURL: URL) async throws -> [SpeakerSegment] {
        let decoded = try await TranscribeMediaLoader.loadSamples(from: audioURL)
        return try await service.diarizeOffline(samples: decoded.samples, sampleRate: 16000)
    }

    static func rttmSegments(from segments: [SpeakerSegment]) -> [(speakerId: String, start: Double, end: Double)] {
        segments.map { (speakerId: String($0.speakerId), start: $0.startTime, end: $0.endTime) }
    }

    static func writeJSON(
        segments: [SpeakerSegment],
        audioPath: String,
        elapsed: TimeInterval,
        engine: String,
        timings: DiarizeTimingsOutput = .missing,
        to path: String?
    ) throws {
        let output = DiarizeFileOutput(
            audioFile: audioPath,
            segments: segments.map {
                DiarizeSegmentOutput(
                    speakerId: String($0.speakerId),
                    startSeconds: $0.startTime,
                    endSeconds: $0.endTime,
                    durationSeconds: $0.duration,
                    qualityScore: $0.qualityScore
                )
            },
            speakerCount: Set(segments.map(\.speakerId)).count,
            processingSeconds: elapsed,
            timings: timings,
            engine: engine
        )
        try DiarizeOutputBuilder.write(output, to: path)
    }
}
#endif
