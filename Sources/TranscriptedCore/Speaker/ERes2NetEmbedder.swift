// ERes2NetEmbedder.swift
// On-device speaker embedding via the Alibaba 3D-Speaker ERes2Net model,
// converted to a single fused CoreML graph (raw 16 kHz audio -> 192-dim vector).
//
// The CoreML model bakes the kaldi-fbank frontend (framing + povey window +
// preemphasis + DC removal + DFT, folded into one Conv1d) and per-utterance
// mean-subtraction directly into the graph, so this Swift wrapper just feeds raw
// Float samples — no DSP here. The model accepts a flexible audio length; long
// segments are split into back-to-back 30 s windows whose L2-normalized
// embeddings are mean-pooled with equal weight.
//
// The model runs through `CoreMLSpeakerSegmentEmbedder` (the generic fused-model
// embedder); this type pins ERes2Net's id, size, thresholds and length policy.
//
// Parity with the PyTorch reference was verified at conversion time
// (min cosine 0.99974 on real AMI segments). See scripts/convert_eres2net_fused.py.

import Foundation
import CoreML

@available(macOS 14.0, *)
public final class ERes2NetEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {

    public let dimension = 192
    public let identifier = "eres2net"
    public let thresholds = SpeakerEmbeddingThresholds.eRes2Net

    // Matches the CoreML model's RangeDim bounds (scripts/convert_eres2net_fused.py).
    static let minSamples = 8000        // 0.5 s — model lower bound
    static let maxSamples = 480_000     // 30 s  — model upper bound

    private let embedder: CoreMLSpeakerSegmentEmbedder

    /// ERes2Net's settings for the generic embedder: short clips tiled to 0.5 s,
    /// long ones cut into back-to-back 30 s windows, pooled with equal weight.
    public static func configuration(modelURL: URL) -> CoreMLSpeakerEmbedderConfiguration {
        CoreMLSpeakerEmbedderConfiguration(
            modelURL: modelURL,
            identifier: "eres2net",
            dimension: 192,
            thresholds: .eRes2Net,
            minSamples: minSamples,
            maxSamples: maxSamples,
            windowSamples: maxSamples,
            hopSamples: maxSamples,
            pooling: .equal,
            computeUnits: .all
        )
    }

    /// Load the compiled `.mlmodelc` at `modelURL`. Returns nil if the model is
    /// missing or fails to load, so callers can fall back to the native embedding.
    public init?(modelURL: URL) {
        do {
            embedder = try CoreMLSpeakerSegmentEmbedder(configuration: Self.configuration(modelURL: modelURL))
        } catch {
            AppLogger.speakers.error("ERes2NetEmbedder: failed to load model", ["url": modelURL.lastPathComponent])
            return nil
        }
    }

    public func embed(samples: [Float], sampleRate: Int) -> [Float]? {
        embedder.embed(samples: samples, sampleRate: sampleRate)
    }

    // MARK: - Pure helpers (unit-tested without the model; shared with the generic embedder)

    /// Window boundaries for an arbitrary sample count. Short audio yields a single
    /// window (the caller tiles it up to the model minimum); audio longer than
    /// `maxSamples` is split into consecutive `maxSamples` windows so each fits the
    /// model's flexible-length bound. Returns [] for empty input.
    static func windowBounds(sampleCount: Int, minSamples: Int, maxSamples: Int) -> [(start: Int, end: Int)] {
        CoreMLSpeakerSegmentEmbedder.windowBounds(sampleCount: sampleCount, window: maxSamples, hop: maxSamples)
    }

    /// Repeat `samples` until it reaches `target` length (keeps frames speech-like
    /// for very short clips instead of padding with silence).
    static func tile(_ samples: [Float], to target: Int) -> [Float] {
        CoreMLSpeakerSegmentEmbedder.tile(samples, to: target)
    }

    /// Mean-pool a set of (already L2-normalized) embeddings, then L2-normalize the
    /// mean. Combines per-window embeddings for long segments.
    static func meanPoolNormalized(_ vectors: [[Float]]) -> [Float] {
        CoreMLSpeakerSegmentEmbedder.meanPoolNormalized(vectors)
    }

    static func l2Normalize(_ v: [Float]) -> [Float] {
        CoreMLSpeakerSegmentEmbedder.l2Normalize(v)
    }
}
