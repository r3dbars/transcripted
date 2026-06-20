// SpeakerSegmentEmbedder.swift
// A host-injected seam for replacing the diarizer's native speaker embedding.
//
// FluidAudio's offline diarizer emits a 256-dim WeSpeaker embedding per segment.
// That vector drives both "who spoke when" (inside FluidAudio) and the app-side
// speaker *identity* stack — same-voice consolidation and cross-call matching
// against the persistent SpeakerDatabase. The identity stack is where compressed
// (Zoom/phone) audio hurts most: different speakers' WeSpeaker vectors drift
// together and get merged into one person.
//
// A SpeakerSegmentEmbedder lets the app re-derive each segment's embedding with a
// different model (e.g. ERes2Net) *after* diarization, so the consolidation +
// matching path runs on a stronger, codec-robust voiceprint. The diarizer's
// segment boundaries and initial cluster assignment are untouched.

import Foundation

/// Produces a speaker embedding for a 16 kHz mono audio segment.
public protocol SpeakerSegmentEmbedder: Sendable {
    /// Output embedding dimension (e.g. 192 for ERes2Net, 256 for WeSpeaker).
    var dimension: Int { get }

    /// A short, stable identifier for the active model (e.g. "eres2net").
    /// Used to namespace persisted state so embeddings of different dimensions
    /// never mix in one SpeakerDatabase row.
    var identifier: String { get }

    /// Embed 16 kHz mono Float samples into an L2-normalized embedding.
    /// Returns nil when the segment is unusable or inference fails — callers
    /// should fall back to the diarizer's native embedding in that case.
    func embed(samples: [Float], sampleRate: Int) -> [Float]?

    /// Cosine thresholds calibrated for this model's geometry, consumed by the
    /// speaker identity stack (cross-call matching + within-meeting clustering).
    var thresholds: SpeakerEmbeddingThresholds { get }
}
