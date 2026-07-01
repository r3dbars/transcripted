import XCTest
import Foundation
@testable import TranscriptedCore

/// End-to-end: run the REAL `DiarizationService` (PyAnnote + WeSpeaker + VBx via
/// FluidAudio) on a real 16 kHz wav with an ERes2Net `SpeakerSegmentEmbedder`
/// injected, and prove every segment's embedding comes back as a 192-dim ERes2Net
/// vector (not the diarizer's 256-dim WeSpeaker), then that the SpeakerDatabase
/// matcher consumes them. This is the production code path, not a stub.
///
/// Gated on a caller-provided wav + cached models so it never runs in CI:
///   TRANSCRIPTED_E2E_WAV=/path/to/16k.wav \
///   TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
///   swift test --filter ERes2NetDiarizationE2ETests
@available(macOS 14.0, *)
final class ERes2NetDiarizationE2ETests: XCTestCase {

    func testDiarizeReembedsWithERes2Net() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let wavPath = env["TRANSCRIPTED_E2E_WAV"],
              FileManager.default.fileExists(atPath: wavPath) else {
            throw XCTSkip("set TRANSCRIPTED_E2E_WAV to a 16kHz wav to run this e2e")
        }
        guard let modelURL = stagedModelURL(),
              let embedder = ERes2NetEmbedder(modelURL: modelURL) else {
            throw XCTSkip("ERes2Net model not staged in FluidAudio Models cache")
        }

        let service = await MainActor.run { DiarizationService(segmentEmbedder: embedder) }
        await service.initialize()
        let ready = await MainActor.run { service.isReady }
        guard ready else {
            let state = await MainActor.run { service.modelState }
            throw XCTSkip("offline diarizer models unavailable: \(state)")
        }

        let segments = try await service.diarizeOffline(audioURL: URL(fileURLWithPath: wavPath))
        XCTAssertFalse(segments.isEmpty, "diarization produced no segments")

        // Every produced embedding must be 192-dim ERes2Net.
        let dims = Set(segments.compactMap { $0.embedding?.count })
        XCTAssertEqual(dims, [192], "expected only 192-d ERes2Net embeddings, got \(dims)")

        // Feed them through a throwaway SpeakerDatabase to confirm the identity
        // stack accepts the new dimension and produces persistent speakers.
        let tmpDB = SpeakerDatabase(path: NSTemporaryDirectory() + "e2e_eres2net_\(UUID().uuidString).sqlite")
        var perSpeaker: [Int: [[Float]]] = [:]
        for seg in segments {
            guard let e = seg.embedding, seg.duration >= 1.0, seg.qualityScore >= 0.3 else { continue }
            perSpeaker[seg.speakerId, default: []].append(e)
        }
        var created = 0
        for (_, embs) in perSpeaker {
            let mean = Transcription.computeMeanEmbedding(embs)
            if Transcription.matchAgainstProfiles(mean, profiles: tmpDB.allSpeakers(), threshold: 0.70) == nil {
                _ = tmpDB.addOrUpdateSpeaker(embedding: mean, existingId: nil)
                created += 1
            }
        }

        let speakers = Set(segments.map { $0.speakerId }).count
        print("[e2e] segments=\(segments.count) diarizer-speakers=\(speakers) "
              + "embeddingDims=\(dims) dbProfiles=\(tmpDB.allSpeakers().count) newlyCreated=\(created)")
        XCTAssertGreaterThan(tmpDB.allSpeakers().count, 0)
    }

    private func stagedModelURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = appSupport.appendingPathComponent("FluidAudio/Models/eres2net-embedding/Model.mlmodelc")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
