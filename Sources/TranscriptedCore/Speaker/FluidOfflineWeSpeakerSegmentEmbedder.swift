// FluidOfflineWeSpeakerSegmentEmbedder.swift
// Voiceprints for Nemotron turns from the SAME model today's saved speakers came from.
//
// The pyannote backend's per-segment embeddings come from FluidAudio's offline
// WeSpeaker model: `FBank.mlmodelc` (log-mel fbank) feeding `Embedding.mlmodelc`
// with a per-frame weight mask. Every person saved in `speakers.sqlite` was learned
// from vectors made by those two files. Nemotron emits no embeddings, so its turns
// need one each; embedding them with the online WeSpeaker conversion
// (`FluidWeSpeakerSegmentEmbedder`) lands in a nearby but different space (measured
// in the YODAS3 speaker lab: per-clip cosine 0.61-0.81 against the offline vectors,
// one of 29 clusters matching the wrong person).
//
// This embedder runs the offline model files directly, through the public
// `OfflineDiarizerModels.fbankModel` / `.embeddingModel`, the way the pyannote
// pipeline itself embeds a speaker: a real 10 s window of meeting audio with a
// per-frame weight mask that is on only where that speaker talks. It must not pad a
// short clip with silence (FluidAudio's `embedSpan` recipe): the fbank features are
// normalized over the whole window, so padding tilts every vector the same way
// (measured: different people at 0.40-0.65 cosine). Turns longer than one window
// are embedded window by window and combined by talk time, then L2-normalized.
// Same model and space as the pyannote backend's vectors, so it shares
// `speakers.sqlite` and the `.weSpeaker` thresholds.

import CoreML
import Foundation
@preconcurrency import FluidAudio

@available(macOS 14.0, *)
public final class FluidOfflineWeSpeakerSegmentEmbedder: ContextualSpeakerSegmentEmbedder, @unchecked Sendable {
    /// Same vector space as the pyannote backend's native embeddings, so the same
    /// identifier: hosts keep using the default speaker database.
    public static let embedderIdentifier = "wespeaker"
    public let dimension = 256
    public let identifier = FluidOfflineWeSpeakerSegmentEmbedder.embedderIdentifier
    public let thresholds = SpeakerEmbeddingThresholds.weSpeaker

    /// FluidAudio's offline pipeline window: 10 s at 16 kHz.
    static let sampleRate = 16_000
    static let windowSamples = 160_000

    private let fbankModel: MLModel
    private let embeddingModel: MLModel
    private let fbankShape: [NSNumber]
    private let weightShape: [NSNumber]
    private let weightFrames: Int
    private let lock = NSLock()

    public init(models: OfflineDiarizerModels) throws {
        fbankModel = models.fbankModel
        embeddingModel = models.embeddingModel
        guard let audio = fbankModel.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint,
              let weights = embeddingModel.modelDescription.inputDescriptionsByName["weights"]?.multiArrayConstraint,
              embeddingModel.modelDescription.outputDescriptionsByName["embedding"] != nil
        else {
            throw NSError(domain: "FluidOfflineWeSpeakerSegmentEmbedder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Offline WeSpeaker models are missing the expected inputs/outputs"
            ])
        }
        fbankShape = Self.shape(of: audio, fallback: [1, 1, Self.windowSamples])
        weightShape = Self.shape(of: weights, fallback: [1, 589])
        weightFrames = max(1, weightShape.last?.intValue ?? 589)
        AppLogger.transcription.info("Offline WeSpeaker embedder ready", [
            "audioShape": fbankShape.map { "\($0)" }.joined(separator: "x"),
            "weightShape": weightShape.map { "\($0)" }.joined(separator: "x"),
            "audioType": "\(audio.dataType.rawValue)",
            "weightType": "\(weights.dataType.rawValue)"
        ])
    }

    /// Loads the offline diarizer models from `directory` (a bundled copy) or from
    /// FluidAudio's cache, the same files the pyannote backend loads.
    public static func load(directory: URL?) async throws -> FluidOfflineWeSpeakerSegmentEmbedder {
        let models = try await OfflineDiarizerModels.load(from: directory ?? OfflineDiarizerModels.defaultModelsDirectory())
        return try FluidOfflineWeSpeakerSegmentEmbedder(models: models)
    }

    /// Embed `start..<end` of `audio` (16 kHz) using the surrounding meeting audio as
    /// context, like the pyannote pipeline does.
    public func embed(audio: [Float], sampleRate: Int, startSample: Int, endSample: Int) -> [Float]? {
        guard sampleRate == Self.sampleRate, !audio.isEmpty else {
            return embed(samples: Array(audio[max(0, startSample)..<min(audio.count, endSample)]), sampleRate: sampleRate)
        }
        let start = max(0, min(startSample, audio.count))
        let end = max(start, min(endSample, audio.count))
        guard end > start else { return nil }
        let window = Self.windowSamples
        var sum = [Float](repeating: 0, count: dimension)
        var total: Float = 0
        var pieceStart = start
        while pieceStart < end {
            let pieceEnd = min(end, pieceStart + window)
            let pieceLength = pieceEnd - pieceStart
            if pieceLength < Self.sampleRate / 2, total > 0 { break }
            // A real 10 s window around the piece, kept inside the recording.
            let slack = window - pieceLength
            var windowStart = pieceStart - slack / 2
            windowStart = max(0, min(windowStart, audio.count - window))
            windowStart = max(0, windowStart)
            let windowLength = min(window, audio.count - windowStart)
            if let vector = embedWindow(
                audio, start: windowStart, length: windowLength,
                activeFrom: pieceStart - windowStart, activeTo: pieceEnd - windowStart
            ), vector.count == dimension {
                let weight = Float(pieceLength)
                for i in 0..<dimension { sum[i] += vector[i] * weight }
                total += weight
            }
            pieceStart = pieceEnd
        }
        return Self.normalized(sum, total: total)
    }

    public func embed(samples: [Float], sampleRate: Int) -> [Float]? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }
        let audio = sampleRate == Self.sampleRate
            ? samples
            : AudioResampler.resample(samples, from: Double(sampleRate), to: Double(Self.sampleRate))
        guard !audio.isEmpty else { return nil }

        var sum = [Float](repeating: 0, count: dimension)
        var total: Float = 0
        var start = 0
        while start < audio.count {
            let length = min(Self.windowSamples, audio.count - start)
            // Skip a trailing sliver under 0.5 s when earlier pieces already cover the clip.
            if length < Self.sampleRate / 2, total > 0 { break }
            guard let vector = embedWindow(audio, start: start, length: length, activeFrom: 0, activeTo: length),
                  vector.count == dimension else {
                start += Self.windowSamples
                continue
            }
            let weight = Float(length)
            for i in 0..<dimension { sum[i] += vector[i] * weight }
            total += weight
            start += Self.windowSamples
        }
        return Self.normalized(sum, total: total)
    }

    /// L2-normalized per the SpeakerSegmentEmbedder contract; cosine matching is
    /// scale-free, so this matches the pyannote backend's raw vectors as well.
    static func normalized(_ sum: [Float], total: Float) -> [Float]? {
        guard total > 0 else { return nil }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return nil }
        return sum.map { $0 / norm }
    }

    /// One 10 s window of `audio` from `start` (zero beyond `length`), with the weight
    /// mask on only for samples `activeFrom..<activeTo` of the window. One pool around
    /// both predictions (the fbank output is the second model's input), so Core ML's
    /// autoreleased arrays are freed per window, not when the whole meeting is done.
    private func embedWindow(_ audio: [Float], start: Int, length: Int, activeFrom: Int, activeTo: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return autoreleasepool { () -> [Float]? in
            do {
                let audioArray = try MLMultiArray(shape: fbankShape, dataType: .float32)
                let audioPointer = audioArray.dataPointer.assumingMemoryBound(to: Float.self)
                audioPointer.update(repeating: 0, count: audioArray.count)
                let copy = min(length, audioArray.count)
                audio.withUnsafeBufferPointer { buffer in
                    audioPointer.update(from: buffer.baseAddress! + start, count: copy)
                }
                let fbankOut = try fbankModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": audioArray]))
                guard let features = fbankOut.featureValue(for: "fbank_features")?.multiArrayValue else { return nil }

                let weights = try MLMultiArray(shape: weightShape, dataType: .float32)
                let weightPointer = weights.dataPointer.assumingMemoryBound(to: Float.self)
                weightPointer.update(repeating: 0, count: weights.count)
                let firstFrame = max(0, min(weightFrames - 1,
                    Int((Double(activeFrom) / Double(Self.windowSamples) * Double(weightFrames)).rounded(.down))))
                let lastFrame = max(firstFrame + 1, min(weightFrames,
                    Int((Double(activeTo) / Double(Self.windowSamples) * Double(weightFrames)).rounded(.up))))
                for frame in firstFrame..<min(lastFrame, weights.count) { weightPointer[frame] = 1 }

                let out = try embeddingModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "fbank_features": features, "weights": weights,
                ]))
                guard let embedding = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
                let vector = Self.floats(embedding)
                return vector.allSatisfy(\.isFinite) ? vector : nil
            } catch {
                AppLogger.transcription.warning("Offline WeSpeaker embedding failed", ["error": error.localizedDescription])
                return nil
            }
        }
    }

    /// Reads a multiarray as Float32 whatever its element type (the embedding model
    /// may return Float16).
    static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        case .float16:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float16.self)
            return UnsafeBufferPointer(start: pointer, count: count).map { Float($0) }
        case .double:
            let pointer = array.dataPointer.assumingMemoryBound(to: Double.self)
            return UnsafeBufferPointer(start: pointer, count: count).map { Float($0) }
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }

    /// The model's declared input shape (enumerated, explicit, or range minimums).
    private static func shape(of constraint: MLMultiArrayConstraint, fallback: [Int]) -> [NSNumber] {
        if let enumerated = constraint.shapeConstraint.enumeratedShapes.first, !enumerated.isEmpty {
            return enumerated.map { NSNumber(value: max(1, $0.intValue)) }
        }
        if !constraint.shape.isEmpty, constraint.shape.allSatisfy({ $0.intValue > 0 }) {
            return constraint.shape
        }
        let ranges = constraint.shapeConstraint.sizeRangeForDimension
        if !ranges.isEmpty {
            return ranges.enumerated().map { index, value in
                let location = value.rangeValue.location
                return NSNumber(value: location > 0 ? location : (index < fallback.count ? fallback[index] : 1))
            }
        }
        return fallback.map { NSNumber(value: $0) }
    }
}
