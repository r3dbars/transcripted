// ERes2NetEmbedder.swift
// On-device speaker embedding via the Alibaba 3D-Speaker ERes2Net model,
// converted to a single fused CoreML graph (raw 16 kHz audio -> 192-dim vector).
//
// The CoreML model bakes the kaldi-fbank frontend (framing + povey window +
// preemphasis + DC removal + DFT, folded into one Conv1d) and per-utterance
// mean-subtraction directly into the graph, so this Swift wrapper just feeds raw
// Float samples — no DSP here. The model accepts a flexible audio length; this
// wrapper windows long segments and mean-pools the per-window embeddings.
//
// Parity with the PyTorch reference was verified at conversion time
// (min cosine 0.99974 on real AMI segments). See scripts/convert_eres2net_fused.py.

import Foundation
import CoreML

@available(macOS 14.0, *)
public final class ERes2NetEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {

    public let dimension = 192
    public let identifier = "eres2net"

    private let model: MLModel
    private let inputName: String
    private let outputName: String

    // Matches the CoreML model's RangeDim bounds (scripts/convert_eres2net_fused.py).
    private let minSamples = 8000        // 0.5 s — model lower bound
    private let maxSamples = 480_000     // 30 s  — model upper bound

    /// Load the compiled `.mlmodelc` at `modelURL`. Returns nil if the model is
    /// missing or fails to load, so callers can fall back to the native embedding.
    public init?(modelURL: URL) {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let loaded = try? MLModel(contentsOf: modelURL, configuration: config) else {
            AppLogger.speakers.error("ERes2NetEmbedder: failed to load model", ["url": modelURL.lastPathComponent])
            return nil
        }
        self.model = loaded

        // Resolve IO feature names (the converter names them "audio"/"embedding",
        // but resolve defensively against the model description).
        let inputs = loaded.modelDescription.inputDescriptionsByName
        let outputs = loaded.modelDescription.outputDescriptionsByName
        self.inputName = inputs["audio"] != nil ? "audio" : (inputs.keys.first ?? "audio")
        self.outputName = outputs["embedding"] != nil ? "embedding" : (outputs.keys.first ?? "embedding")

        AppLogger.speakers.info("ERes2NetEmbedder loaded", [
            "input": inputName, "output": outputName, "dim": "\(dimension)"
        ])
    }

    public func embed(samples: [Float], sampleRate: Int) -> [Float]? {
        guard sampleRate == 16000 else {
            AppLogger.speakers.error("ERes2NetEmbedder requires 16kHz audio", ["got": "\(sampleRate)"])
            return nil
        }
        guard !samples.isEmpty else { return nil }

        // Split into <= maxSamples windows (short clips become a single window,
        // tiled up to the model minimum), embed + L2-normalize each, then mean-pool
        // the per-window embeddings (a no-op for the common single-window case).
        // The window math is pure and unit-tested via Self.windowBounds.
        let bounds = Self.windowBounds(sampleCount: samples.count, minSamples: minSamples, maxSamples: maxSamples)
        var pooled: [[Float]] = []
        pooled.reserveCapacity(bounds.count)
        for (start, end) in bounds {
            var window = Array(samples[start..<end])
            if window.count < minSamples { window = Self.tile(window, to: minSamples) }
            if let raw = runModel(window) { pooled.append(Self.l2Normalize(raw)) }
        }
        guard !pooled.isEmpty else { return nil }
        return pooled.count == 1 ? pooled[0] : Self.meanPoolNormalized(pooled)
    }

    // MARK: - CoreML invocation

    private func runModel(_ window: [Float]) -> [Float]? {
        do {
            let array = try MLMultiArray(shape: [1, NSNumber(value: window.count)], dataType: .float32)
            // Bulk copy into the backing buffer (per-element subscript is far slower).
            window.withUnsafeBytes { src in
                array.dataPointer.copyMemory(from: src.baseAddress!, byteCount: window.count * MemoryLayout<Float>.stride)
            }
            let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
            let out = try model.prediction(from: input)
            guard let emb = out.featureValue(for: outputName)?.multiArrayValue else {
                AppLogger.speakers.error("ERes2NetEmbedder: no embedding output")
                return nil
            }
            let count = emb.count
            guard count == dimension else {
                AppLogger.speakers.error("ERes2NetEmbedder: unexpected output dim", ["got": "\(count)"])
                return nil
            }
            var result = [Float](repeating: 0, count: count)
            if emb.dataType == .float32 {
                let ptr = emb.dataPointer.assumingMemoryBound(to: Float.self)
                for i in 0..<count { result[i] = ptr[i] }
            } else {
                for i in 0..<count { result[i] = emb[i].floatValue }
            }
            return result
        } catch {
            AppLogger.speakers.error("ERes2NetEmbedder: prediction failed", ["error": "\(error.localizedDescription)"])
            return nil
        }
    }

    // MARK: - Helpers

    // MARK: - Pure helpers (unit-tested without the model)

    /// Window boundaries for an arbitrary sample count. Short audio yields a single
    /// window (the caller tiles it up to the model minimum); audio longer than
    /// `maxSamples` is split into consecutive `maxSamples` windows so each fits the
    /// model's flexible-length bound. Returns [] for empty input.
    static func windowBounds(sampleCount: Int, minSamples: Int, maxSamples: Int) -> [(start: Int, end: Int)] {
        guard sampleCount > 0 else { return [] }
        if sampleCount <= maxSamples { return [(0, sampleCount)] }
        var out: [(start: Int, end: Int)] = []
        var start = 0
        while start < sampleCount {
            out.append((start, min(start + maxSamples, sampleCount)))
            start += maxSamples
        }
        return out
    }

    /// Repeat `samples` until it reaches `target` length (keeps frames speech-like
    /// for very short clips instead of padding with silence).
    static func tile(_ samples: [Float], to target: Int) -> [Float] {
        guard !samples.isEmpty, samples.count < target else { return samples }
        var out = [Float]()
        out.reserveCapacity(target)
        while out.count < target {
            out.append(contentsOf: samples.prefix(target - out.count))
        }
        return out
    }

    /// Mean-pool a set of (already L2-normalized) embeddings, then L2-normalize the
    /// mean. Combines per-window embeddings for long segments.
    static func meanPoolNormalized(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        let dim = first.count
        var acc = [Float](repeating: 0, count: dim)
        for v in vectors where v.count == dim {
            for i in 0..<dim { acc[i] += v[i] }
        }
        return l2Normalize(acc)
    }

    static func l2Normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }
}
