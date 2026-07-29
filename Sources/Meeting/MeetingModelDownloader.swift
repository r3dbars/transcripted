// MeetingModelDownloader.swift
// Gates the meeting pipeline on the STT + diarization models being loaded.
// Delegates the actual download work to TranscriptedCore (DiarizationService
// initializes the offline PyAnnote + WeSpeaker path required by meeting
// transcripts) and the app's selected speech-to-text router.
// This file only coordinates the two calls and surfaces a single await point
// for the session controller.

import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class MeetingModelDownloader {

    private let stt: MeetingSTTAdapter
    private let diarization: DiarizationService

    init(stt: MeetingSTTAdapter, diarization: DiarizationService) {
        self.stt = stt
        self.diarization = diarization
    }

    /// Ensure STT and required offline diarization models are loaded before the
    /// first meeting recording starts. Safe to call multiple times - each
    /// underlying engine is idempotent after first successful load.
    func ensureModelsReady() async throws {
        try await ensureModelsReady(
            sttModel: stt.selectedModel,
            retainForNextJob: false
        )
    }

    func ensureModelsReady(
        sttModel: TranscriptionModelChoice,
        retainForNextJob: Bool = false
    ) async throws {
        // Fast path: both already loaded.
        if stt.isReady(for: sttModel) && diarization.isReady {
            await stt.prepare(
                model: sttModel,
                retainForNextJob: retainForNextJob
            )
            if retainForNextJob {
                guard stt.hasPreparedLease(for: sttModel) else {
                    throw NSError(domain: "MeetingModelDownloader", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "Speech model preparation was superseded."
                    ])
                }
            }
            return
        }

        let startedAt = Date()

        // Kick both initializers in parallel. Each is idempotent and each owns
        // its own progress reporting via @Published properties on the engines.
        do {
            async let sttReady: Void = stt.prepare(
                model: sttModel,
                retainForNextJob: retainForNextJob
            )
            async let diarReady: Void = diarization.initialize()
            _ = await (sttReady, diarReady)

            // After both returns, confirm they actually reached a usable state.
            let sttReadyForUse = retainForNextJob
                ? stt.hasPreparedLease(for: sttModel)
                : stt.isReady
            guard sttReadyForUse else {
                throw NSError(domain: "MeetingModelDownloader", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Selected speech model failed to load."
                ])
            }
            guard diarization.isReady else {
                let detail: String
                switch diarization.modelState {
                case .failed(let msg): detail = msg
                default: detail = "unknown state"
                }
                throw NSError(domain: "MeetingModelDownloader", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Diarization models failed to load: \(detail)"
                ])
            }

            AppLogger.pipeline.info("Meeting model warmup complete", [
                "elapsed_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ])
        } catch {
            AppLogger.pipeline.error("Meeting model warmup failed", [
                "elapsed_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
                "error": error.localizedDescription
            ])
            throw error
        }
    }
}
