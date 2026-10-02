// ExternalEngineTranscription.swift
// Whisper and Apple Speech transcribe samples Parakeet recorded, under a
// recorded-transcription lease. The lease is released when the run ends,
// and only after a thrown model error has been classified, so the
// classification still sees the take as owned.

import Foundation

enum ExternalEngineTranscription {
    /// Runs `model` while `lease` is held. Success goes to `accept`; a thrown
    /// error goes to `classify`. `release` runs last, on every path.
    static func run<Lease>(
        lease: Lease,
        release: (Lease) -> Void,
        model: () async throws -> String,
        accept: (String) -> String?,
        classify: (Error) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async -> String? {
        defer { release(lease) }
        do {
            let text = try await model()
            return accept(text)
        } catch {
            classify(error)
            return nil
        }
    }
}
