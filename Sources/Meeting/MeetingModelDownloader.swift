// MeetingModelDownloader.swift
// Gates the meeting pipeline on the STT + diarization models being loaded.
// Delegates the actual download work to TranscriptedCore (DiarizationService
// initializes PyAnnote + WeSpeaker + Sortformer) and Draft (ParakeetEngine
// loads Parakeet TDT V3). This file only coordinates the two calls and
// surfaces a single await point for the session controller.

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

    /// Ensure both STT and diarization models are loaded before the first meeting
    /// recording starts. Safe to call multiple times - each underlying engine is
    /// idempotent after first successful load.
    ///
    /// Network reachability is checked first so we can short-circuit with a clear
    /// error on offline machines instead of dying inside FluidAudio's retry loop.
    func ensureModelsReady() async throws {
        // Fast path: both already loaded.
        if stt.isReady && diarization.modelState == .ready {
            return
        }

        let startedAt = Date()

        // Kick both initializers in parallel. Each is idempotent and each owns
        // its own progress reporting via @Published properties on the engines.
        do {
            async let sttReady: Void = stt.initialize()
            async let diarReady: Void = diarization.initialize()
            _ = await (sttReady, diarReady)

            // After both returns, confirm they actually reached a usable state.
            guard stt.isReady else {
                throw NSError(domain: "MeetingModelDownloader", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Parakeet STT failed to load."
                ])
            }
            guard diarization.modelState == .ready else {
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
