// MeetingSTTAdapter.swift
// Thin conformer that lets Transcripted's ParakeetEngine plug into TranscriptedCore's
// SpeechToTextEngine protocol for the Meeting pipeline. Owned by Lane B per
// merge-plan.md §3.2 — STTRouter wraps recording lifecycle and has no raw-samples
// entry point, so we bypass it and adapt ParakeetEngine directly.
//
// The protocol is `@MainActor` + `ObservableObject`, which forces us to be a
// `class` (structs cannot conform to ObservableObject). `final` because there
// is no subclass design here.

import Combine
import FluidAudio
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class MeetingSTTAdapter: ObservableObject, SpeechToTextEngine {

    /// The app-owned Parakeet engine instance. Shared with STTRouter — there is
    /// only one AsrManager per process, and both the drafting flow and the meeting
    /// pipeline route through it. Caller is responsible for keeping this alive.
    private let engine: ParakeetEngine

    init(engine: ParakeetEngine) {
        self.engine = engine
    }

    // MARK: - SpeechToTextEngine

    var isReady: Bool {
        engine.isModelLoaded
    }

    /// Delegate to ParakeetEngine's existing async model loader. Safe to call
    /// multiple times — ParakeetEngine.initialize() is idempotent.
    func initialize() async {
        await engine.initialize()
    }

    /// Core's pipeline resamples to 16kHz upstream, so we forward the samples
    /// directly to ParakeetEngine.transcribeSamples (which does NOT resample).
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        try await engine.transcribeSamples(samples, source: source)
    }

    /// No-op for the adapter: ParakeetEngine.cleanup() is owned by TranscriptedAppState's
    /// shutdown path. Tearing down the CoreML models here would break the drafting
    /// flow that still holds a reference to `engine`.
    func cleanup() {
        // Intentionally empty. See docstring.
    }
}
