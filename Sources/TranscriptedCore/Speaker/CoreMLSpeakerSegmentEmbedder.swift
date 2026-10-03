// CoreMLSpeakerSegmentEmbedder.swift
// Any fused Core ML voiceprint model as a SpeakerSegmentEmbedder.
//
// The model takes raw 16 kHz mono audio shaped [1, N] (or [N], [1, 1, N]) and
// returns one embedding of `dimension` values. Any frontend (fbank, mean
// subtraction) is baked into the graph, so there is no DSP here: this type only
// fits the audio to the lengths the model accepts and combines the pieces.
//
//   - A turn longer than one window is cut into `windowSamples` pieces that start
//     every `hopSamples` (the last piece ends at the end of the turn), each piece is
//     embedded and L2-normalized, then the pieces are pooled and L2-normalized again.
//     `.talkTimeWeighted` weights each piece by the real audio it covers;
//     `.equal` is a plain mean (ERes2NetEmbedder's original behavior).
//   - A piece shorter than the model takes is tiled (repeated) up to the next length
//     it accepts: `minSamples` for a flexible range, the next listed length for a
//     model converted with enumerated lengths. Tiling keeps the frames speech-like;
//     padding with silence skews per-utterance normalization. No real audio is cut.
//
// The accepted lengths come from the model's input shape (a flexible range, a list
// of enumerated lengths, or one fixed length); the configuration may narrow them.
//
// A multifunction model (one fixed-length function per input length, such as the
// ReDimNet2 builds' `len_<samples>` functions; weights shared) accepts exactly its
// functions' lengths. Each call runs on the function whose input has that call's
// length (`MLModelConfiguration.functionName`); each function is loaded on first use
// and kept. Function names are read from the model, else from
// `CoreMLSpeakerEmbedderConfiguration.functionsByLength`. A single-function model
// lists no functions and is loaded as before.
// A window whose output is the wrong size, NaN/Inf, or all zeros counts as failed;
// `embed` returns nil when every window failed, and DiarizationService then drops
// that segment's embedding rather than mixing models.
//
// Not a ContextualSpeakerSegmentEmbedder: these models have no per-frame speaker
// mask, so audio around a turn would blend other people into the voiceprint.

import CoreML
import Foundation

/// How the per-window vectors of a long turn are combined.
public enum SpeakerEmbeddingPooling: String, Sendable, Equatable, CaseIterable {
    /// Weight each window by the real samples it covers (talk time).
    case talkTimeWeighted = "talk-time"
    /// Plain mean of the window vectors.
    case equal
}

/// Everything needed to run one fused Core ML voiceprint model.
public struct CoreMLSpeakerEmbedderConfiguration: Sendable, Equatable {
    /// A compiled `.mlmodelc`.
    public var modelURL: URL
    /// Short, stable id. Hosts key the speaker database on it, so it must be unique
    /// per vector space. Letters, digits, `.`, `_` and `-` only.
    public var identifier: String
    /// Embedding size the model outputs.
    public var dimension: Int
    /// Cosine bars calibrated for this model (see `SpeakerEmbeddingThresholds.load`).
    public var thresholds: SpeakerEmbeddingThresholds
    /// Model input name; nil picks `audio`, or the model's only input.
    public var inputName: String?
    /// Model output name; nil picks `embedding`, or the model's only output.
    public var outputName: String?
    /// Fewest samples one model call takes; nil reads the model's input shape.
    public var minSamples: Int?
    /// Most samples one model call takes; nil reads the model's input shape.
    public var maxSamples: Int?
    /// Long-turn window; nil means the longest accepted length up to 30 s.
    public var windowSamples: Int?
    /// Long-turn hop, at most the window; nil means the window (no overlap).
    public var hopSamples: Int?
    public var pooling: SpeakerEmbeddingPooling
    public var computeUnits: MLComputeUnits
    /// Multifunction model only: the function to run for each input length, in
    /// samples. Used when the model's own function list can't be read or has fewer
    /// than two functions; nil for a single-function model.
    public var functionsByLength: [Int: String]?
    /// Multifunction model only: release every loaded function after this many
    /// seconds without a call (they reload on the next call). A multifunction model
    /// holds GPU memory per loaded function (ReDimNet2: about 125 MB each), and the
    /// app only embeds in the minute after a meeting. nil keeps them loaded.
    public var idleReleaseSeconds: TimeInterval?

    public init(
        modelURL: URL,
        identifier: String,
        dimension: Int,
        thresholds: SpeakerEmbeddingThresholds,
        inputName: String? = nil,
        outputName: String? = nil,
        minSamples: Int? = nil,
        maxSamples: Int? = nil,
        windowSamples: Int? = nil,
        hopSamples: Int? = nil,
        pooling: SpeakerEmbeddingPooling = .talkTimeWeighted,
        computeUnits: MLComputeUnits = .all,
        functionsByLength: [Int: String]? = nil,
        idleReleaseSeconds: TimeInterval? = nil
    ) {
        self.modelURL = modelURL
        self.identifier = identifier
        self.dimension = dimension
        self.thresholds = thresholds
        self.inputName = inputName
        self.outputName = outputName
        self.minSamples = minSamples
        self.maxSamples = maxSamples
        self.windowSamples = windowSamples
        self.hopSamples = hopSamples
        self.pooling = pooling
        self.computeUnits = computeUnits
        self.functionsByLength = functionsByLength
        self.idleReleaseSeconds = idleReleaseSeconds
    }
}

/// Why a Core ML voiceprint model could not be set up. Messages carry feature
/// names and sizes, never paths.
public struct CoreMLSpeakerEmbedderError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The input lengths a model declares.
public enum CoreMLVoiceprintInputLengths: Sendable, Equatable {
    /// Any length in the range (a RangeDim model, or one fixed length).
    case range(ClosedRange<Int>)
    /// Only these lengths (an EnumeratedShapes model).
    case enumerated([Int])

    /// Whether a call of `sampleCount` samples fits.
    public func accepts(_ sampleCount: Int) -> Bool {
        switch self {
        case .range(let range): return range.contains(sampleCount)
        case .enumerated(let lengths): return lengths.contains(sampleCount)
        }
    }

    /// The one length a fixed-shape input takes; nil when it takes several.
    var fixedLength: Int? {
        switch self {
        case .range(let range): return range.lowerBound == range.upperBound ? range.lowerBound : nil
        case .enumerated(let lengths): return lengths.count == 1 ? lengths.first : nil
        }
    }
}

/// The resolved length policy for one model: how audio is fitted to it.
public struct CoreMLSpeakerEmbeddingPlan: Sendable, Equatable {
    public let minSamples: Int
    public let maxSamples: Int
    public let windowSamples: Int
    public let hopSamples: Int
    public let pooling: SpeakerEmbeddingPooling
    /// The only lengths a model call may have (sorted), or nil for any length in
    /// `minSamples...maxSamples`.
    public let allowedLengths: [Int]?

    /// Default long-turn window when the model accepts more: 30 s, like ERes2Net.
    public static let defaultWindowCap = 480_000

    public init(
        minSamples: Int, maxSamples: Int, windowSamples: Int, hopSamples: Int,
        pooling: SpeakerEmbeddingPooling, allowedLengths: [Int]? = nil
    ) {
        self.minSamples = minSamples
        self.maxSamples = maxSamples
        self.windowSamples = windowSamples
        self.hopSamples = hopSamples
        self.pooling = pooling
        self.allowedLengths = allowedLengths
    }

    /// Fills unset values from `modelLengths` (what the model's input shape
    /// declares): min/max from its bounds, the window from the longest accepted
    /// length up to 30 s, the hop from the window. Explicit min/max narrow an
    /// enumerated list. Throws when the result can't cover a turn: nothing to take
    /// min/max from, min > max, a window outside min...max (or not one of the
    /// enumerated lengths), or a hop that is not in 1...window.
    public static func resolve(
        minSamples: Int?,
        maxSamples: Int?,
        windowSamples: Int?,
        hopSamples: Int?,
        pooling: SpeakerEmbeddingPooling,
        modelLengths: CoreMLVoiceprintInputLengths?
    ) throws -> CoreMLSpeakerEmbeddingPlan {
        var listed: [Int]?
        var declared: ClosedRange<Int>?
        switch modelLengths {
        case .range(let range): declared = range
        case .enumerated(let lengths):
            let sorted = Array(Set(lengths.filter { $0 > 0 })).sorted()
            if let first = sorted.first, let last = sorted.last {
                listed = sorted
                declared = first...last
            }
        case nil: break
        }
        guard let minimum = minSamples ?? declared?.lowerBound else {
            throw CoreMLSpeakerEmbedderError("model input length is not declared; set minSamples")
        }
        guard let maximum = maxSamples ?? declared?.upperBound else {
            throw CoreMLSpeakerEmbedderError("model input length is not declared; set maxSamples")
        }
        var lower = max(1, minimum)
        var upper = maximum
        guard upper >= lower else {
            throw CoreMLSpeakerEmbedderError("minSamples \(lower) is above maxSamples \(upper)")
        }
        if let all = listed {
            let usable = all.filter { $0 >= lower && $0 <= upper }
            guard let first = usable.first, let last = usable.last else {
                throw CoreMLSpeakerEmbedderError("none of the model's input lengths is within \(lower)...\(upper)")
            }
            listed = usable
            lower = first
            upper = last
        }
        let window: Int
        if let windowSamples {
            window = windowSamples
        } else if let listed {
            window = listed.last(where: { $0 <= defaultWindowCap }) ?? lower
        } else {
            window = max(lower, min(upper, defaultWindowCap))
        }
        guard window >= lower, window <= upper else {
            throw CoreMLSpeakerEmbedderError("windowSamples \(window) must be within \(lower)...\(upper)")
        }
        if let listed, !listed.contains(window) {
            throw CoreMLSpeakerEmbedderError("windowSamples \(window) must be one of the model's lengths \(listed)")
        }
        let hop = hopSamples ?? window
        guard hop >= 1, hop <= window else {
            throw CoreMLSpeakerEmbedderError("hopSamples \(hop) must be within 1...\(window)")
        }
        return CoreMLSpeakerEmbeddingPlan(
            minSamples: lower, maxSamples: upper, windowSamples: window, hopSamples: hop,
            pooling: pooling, allowedLengths: listed)
    }

    /// Length a model call gets for `sampleCount` real samples (at most one window):
    /// unchanged when the model takes it, else the next length it takes.
    public func callLength(forSampleCount sampleCount: Int) -> Int {
        if let allowedLengths {
            return allowedLengths.first(where: { $0 >= sampleCount }) ?? allowedLengths.last ?? sampleCount
        }
        return max(sampleCount, minSamples)
    }
}

@available(macOS 14.0, *)
public final class CoreMLSpeakerSegmentEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {
    public static let sampleRate = 16_000

    public let dimension: Int
    public let identifier: String
    public let thresholds: SpeakerEmbeddingThresholds
    public let plan: CoreMLSpeakerEmbeddingPlan
    /// Multifunction model: the function each input length runs on. nil for a
    /// single-function model.
    public let functionsByLength: [Int: String]?

    /// One model call: exactly one window's samples in, the raw output out.
    private let predict: @Sendable ([Float]) -> [Float]?
    /// Multifunction model: loads the window-length function again after an idle
    /// release. nil for a single-function model, which is never released.
    private let prewarmWindowFunction: (@Sendable () -> Void)?

    /// Loads `configuration.modelURL` and checks it against the configuration.
    public convenience init(configuration: CoreMLSpeakerEmbedderConfiguration) throws {
        let functions = try CoreMLVoiceprintFunctions.resolve(
            modelFunctions: CoreMLVoiceprintFunctions.readModelFunctions(
                at: configuration.modelURL, inputName: configuration.inputName),
            configured: configuration.functionsByLength)
        if let functions {
            let lengthByName = Dictionary(functions.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            let router = CoreMLVoiceprintFunctionRouter(
                functionsByLength: functions, idleReleaseSeconds: configuration.idleReleaseSeconds
            ) { name in
                let runner = try CoreMLSpeakerSegmentEmbedder.loadModel(configuration, functionName: name)
                if let length = lengthByName[name], !(runner.inputLengths?.accepts(length) ?? true) {
                    throw CoreMLSpeakerEmbedderError("function \(name) does not take \(length) samples")
                }
                return { runner.predict($0) }
            }
            let plan = try CoreMLSpeakerEmbeddingPlan.resolve(
                minSamples: configuration.minSamples, maxSamples: configuration.maxSamples,
                windowSamples: configuration.windowSamples, hopSamples: configuration.hopSamples,
                pooling: configuration.pooling, modelLengths: .enumerated(router.lengths))
            // Fail fast on the function most calls use: it must load and fit the
            // configured input, output and size. The others load on first use.
            try router.preload(length: plan.windowSamples)
            try self.init(
                identifier: configuration.identifier, dimension: configuration.dimension,
                thresholds: configuration.thresholds, plan: plan, functionsByLength: functions,
                predict: { router.predict($0) },
                prewarm: { [windowSamples = plan.windowSamples] in _ = try? router.preload(length: windowSamples) })
            AppLogger.speakers.info("Core ML speaker embedder loaded", [
                "embedder": identifier, "functions": "\(functions.count)",
                "dim": "\(dimension)", "minSamples": "\(plan.minSamples)", "maxSamples": "\(plan.maxSamples)",
                "lengths": plan.allowedLengths.map { "\($0.count)" } ?? "any",
                "window": "\(plan.windowSamples)", "hop": "\(plan.hopSamples)", "pooling": plan.pooling.rawValue,
            ])
        } else {
            let runner = try CoreMLSpeakerSegmentEmbedder.loadModel(configuration, functionName: nil)
            let plan = try CoreMLSpeakerEmbeddingPlan.resolve(
                minSamples: configuration.minSamples, maxSamples: configuration.maxSamples,
                windowSamples: configuration.windowSamples, hopSamples: configuration.hopSamples,
                pooling: configuration.pooling, modelLengths: runner.inputLengths)
            try self.init(
                identifier: configuration.identifier, dimension: configuration.dimension,
                thresholds: configuration.thresholds, plan: plan,
                predict: { runner.predict($0) })
            AppLogger.speakers.info("Core ML speaker embedder loaded", [
                "embedder": identifier, "input": runner.inputName, "output": runner.outputName,
                "dim": "\(dimension)", "minSamples": "\(plan.minSamples)", "maxSamples": "\(plan.maxSamples)",
                "lengths": plan.allowedLengths.map { "\($0.count)" } ?? "any",
                "window": "\(plan.windowSamples)", "hop": "\(plan.hopSamples)", "pooling": plan.pooling.rawValue,
            ])
        }
    }

    /// Loads the model (one function of it, for a multifunction model) and checks
    /// its input, output and size against the configuration.
    private static func loadModel(
        _ configuration: CoreMLSpeakerEmbedderConfiguration, functionName: String?
    ) throws -> CoreMLVoiceprintModel {
        let modelConfiguration = MLModelConfiguration()
        modelConfiguration.computeUnits = configuration.computeUnits
        if let functionName { modelConfiguration.functionName = functionName }
        let model: MLModel
        do {
            model = try MLModel(contentsOf: configuration.modelURL, configuration: modelConfiguration)
        } catch {
            // Domain and code only: Core ML's message can include the model's path.
            let nsError = error as NSError
            let what = functionName.map { "Core ML model function \($0)" } ?? "Core ML model"
            throw CoreMLSpeakerEmbedderError("\(what) failed to load (\(nsError.domain) \(nsError.code))")
        }
        return try CoreMLVoiceprintModel(
            model: model, inputName: configuration.inputName, outputName: configuration.outputName,
            dimension: configuration.dimension)
    }

    /// The model-free core, so the fitting and pooling can be exercised with a
    /// stand-in model.
    init(
        identifier: String,
        dimension: Int,
        thresholds: SpeakerEmbeddingThresholds,
        plan: CoreMLSpeakerEmbeddingPlan,
        functionsByLength: [Int: String]? = nil,
        predict: @escaping @Sendable ([Float]) -> [Float]?,
        prewarm: (@Sendable () -> Void)? = nil
    ) throws {
        guard Self.isValidIdentifier(identifier) else {
            throw CoreMLSpeakerEmbedderError("embedder id must be letters, digits, '.', '_' or '-'")
        }
        guard dimension > 0 else {
            throw CoreMLSpeakerEmbedderError("embedding dimension must be positive")
        }
        self.identifier = identifier
        self.dimension = dimension
        self.thresholds = thresholds
        self.plan = plan
        self.functionsByLength = functionsByLength
        self.predict = predict
        self.prewarmWindowFunction = prewarm
    }

    /// Reloads the function most calls use if an idle release dropped it, so the
    /// next meeting's first embed doesn't wait on it. Blocks while it loads; call
    /// it off the main thread. It counts as a use for the idle timer.
    public func prewarm() {
        prewarmWindowFunction?()
    }

    public func embed(samples: [Float], sampleRate: Int) -> [Float]? {
        guard sampleRate == Self.sampleRate else {
            AppLogger.speakers.error("Core ML speaker embedder requires 16 kHz audio", [
                "embedder": identifier, "got": "\(sampleRate)",
            ])
            return nil
        }
        guard !samples.isEmpty else { return nil }
        var pieces: [(vector: [Float], weight: Float)] = []
        for (start, end) in Self.windowBounds(
            sampleCount: samples.count, window: plan.windowSamples, hop: plan.hopSamples
        ) {
            let window = Self.tile(Array(samples[start..<end]), to: plan.callLength(forSampleCount: end - start))
            guard let raw = predict(window), raw.count == dimension, let unit = Self.unitVector(raw) else {
                continue
            }
            pieces.append((vector: unit, weight: Float(end - start)))
        }
        return Self.pool(pieces, pooling: plan.pooling)
    }

    // MARK: - Pure helpers

    static func isValidIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.count <= 64 && identifier.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0)
        }
    }

    /// Windows covering `sampleCount` samples: `window` long, starting every `hop`,
    /// the last one ending at the end of the audio. Audio that fits is one window.
    /// With `hop == window` the windows are back to back. [] for empty input.
    static func windowBounds(sampleCount: Int, window: Int, hop: Int) -> [(start: Int, end: Int)] {
        guard sampleCount > 0, window > 0, hop > 0 else { return [] }
        var out: [(start: Int, end: Int)] = []
        var start = 0
        while true {
            let end = min(start + window, sampleCount)
            out.append((start, end))
            if end >= sampleCount { break }
            start += hop
        }
        return out
    }

    /// Repeats `samples` until it is `target` long. Empty or long enough: unchanged.
    static func tile(_ samples: [Float], to target: Int) -> [Float] {
        guard !samples.isEmpty, samples.count < target else { return samples }
        var out = [Float]()
        out.reserveCapacity(target)
        while out.count < target {
            out.append(contentsOf: samples.prefix(target - out.count))
        }
        return out
    }

    /// Unit-length copy of `v`; the zero vector stays zero.
    static func l2Normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Unit-length copy of `v`, or nil when it has NaN/Inf or no length.
    static func unitVector(_ v: [Float]) -> [Float]? {
        guard !v.isEmpty, v.allSatisfy(\.isFinite) else { return nil }
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return v.map { $0 / norm }
    }

    /// Weighted sum of vectors that share the first vector's size (others skipped).
    static func weightedSum(_ pieces: [(vector: [Float], weight: Float)]) -> [Float] {
        guard let dim = pieces.first?.vector.count else { return [] }
        var acc = [Float](repeating: 0, count: dim)
        for piece in pieces where piece.vector.count == dim {
            for i in 0..<dim { acc[i] += piece.vector[i] * piece.weight }
        }
        return acc
    }

    /// Mean of already-normalized vectors, L2-normalized; [] for no vectors.
    static func meanPoolNormalized(_ vectors: [[Float]]) -> [Float] {
        l2Normalize(weightedSum(vectors.map { (vector: $0, weight: Float(1)) }))
    }

    /// Combines per-window unit vectors into one voiceprint. One window passes
    /// through; none, or a pool that cancels to zero, is nil.
    static func pool(_ pieces: [(vector: [Float], weight: Float)], pooling: SpeakerEmbeddingPooling) -> [Float]? {
        guard let first = pieces.first else { return nil }
        if pieces.count == 1 { return first.vector }
        switch pooling {
        case .talkTimeWeighted:
            return unitVector(weightedSum(pieces))
        case .equal:
            return unitVector(weightedSum(pieces.map { (vector: $0.vector, weight: Float(1)) }))
        }
    }
}

// MARK: - Core ML invocation

/// One loaded fused voiceprint model: resolves its input/output features and runs
/// one window per call. Predictions are serialized on a lock.
@available(macOS 14.0, *)
final class CoreMLVoiceprintModel: @unchecked Sendable {
    let inputName: String
    let outputName: String
    /// Input lengths the model declares; nil if its shape says nothing usable.
    let inputLengths: CoreMLVoiceprintInputLengths?

    private let model: MLModel
    private let inputRank: Int
    private let inputType: MLMultiArrayDataType
    private let lock = NSLock()

    init(model: MLModel, inputName: String?, outputName: String?, dimension: Int) throws {
        self.model = model
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        self.inputName = try Self.pickFeature(inputName, preferred: "audio", from: Array(inputs.keys), kind: "input")
        self.outputName = try Self.pickFeature(
            outputName, preferred: "embedding", from: Array(outputs.keys), kind: "output")
        guard let input = inputs[self.inputName]?.multiArrayConstraint else {
            throw CoreMLSpeakerEmbedderError("input \(self.inputName) is not a multiarray")
        }
        let rank = max(input.shape.count, input.shapeConstraint.sizeRangeForDimension.count)
        inputRank = max(1, rank)
        inputType = input.dataType == .float16 ? .float16 : .float32
        inputLengths = Self.inputLengths(of: input)
        if let output = outputs[self.outputName]?.multiArrayConstraint {
            let dims = output.shape.map(\.intValue)
            if !dims.isEmpty, dims.allSatisfy({ $0 > 0 }), dims.reduce(1, *) != dimension {
                throw CoreMLSpeakerEmbedderError(
                    "output \(self.outputName) has \(dims.reduce(1, *)) values, expected \(dimension)")
            }
        }
    }

    func predict(_ window: [Float]) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        do {
            let shape = Array(repeating: NSNumber(value: 1), count: inputRank - 1) + [NSNumber(value: window.count)]
            let array = try MLMultiArray(shape: shape, dataType: inputType)
            if inputType == .float16 {
                let pointer = array.dataPointer.assumingMemoryBound(to: Float16.self)
                for i in 0..<window.count { pointer[i] = Float16(window[i]) }
            } else {
                window.withUnsafeBytes { source in
                    array.dataPointer.copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
            }
            let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
            let out = try model.prediction(from: input)
            guard let embedding = out.featureValue(for: outputName)?.multiArrayValue else {
                AppLogger.speakers.error("Core ML speaker embedder: no embedding output")
                return nil
            }
            return FluidOfflineWeSpeakerSegmentEmbedder.floats(embedding)
        } catch {
            AppLogger.speakers.error("Core ML speaker embedder: prediction failed", [
                "error": error.localizedDescription,
            ])
            return nil
        }
    }

    static func pickFeature(_ requested: String?, preferred: String, from names: [String], kind: String) throws -> String {
        if let requested {
            guard names.contains(requested) else {
                throw CoreMLSpeakerEmbedderError("model has no \(kind) named \(requested) (has \(names.sorted()))")
            }
            return requested
        }
        if names.contains(preferred) { return preferred }
        if names.count == 1, let only = names.first { return only }
        throw CoreMLSpeakerEmbedderError("model \(kind)s \(names.sorted()) are ambiguous; name the \(kind)")
    }

    /// Accepted lengths of the last (time) dimension: a flexible range, enumerated
    /// lengths, or one fixed length (Core ML reports a fixed input as a single
    /// enumerated shape).
    static func inputLengths(of constraint: MLMultiArrayConstraint) -> CoreMLVoiceprintInputLengths? {
        switch constraint.shapeConstraint.type {
        case .range:
            guard let last = constraint.shapeConstraint.sizeRangeForDimension.last?.rangeValue else { return nil }
            let lower = max(1, last.location)
            // NSRange length counts the lengths accepted; an unbounded end comes back huge.
            let upper = last.length >= Int(Int32.max) - lower ? Int(Int32.max) : lower + max(0, last.length - 1)
            return .range(lower...max(lower, upper))
        case .enumerated:
            let lengths = Set(constraint.shapeConstraint.enumeratedShapes.compactMap { $0.last?.intValue })
                .filter { $0 > 0 }.sorted()
            guard !lengths.isEmpty else { return nil }
            return .enumerated(lengths)
        default:
            guard let fixed = constraint.shape.last?.intValue, fixed > 0 else { return nil }
            return .range(fixed...fixed)
        }
    }
}

// MARK: - Multifunction models

/// Finds the functions of a multifunction voiceprint model and the input length
/// each one takes.
enum CoreMLVoiceprintFunctions {
    /// The length in a `len_<samples>` function name (how the bake-off converter
    /// names them); nil for any other name.
    static func length(fromFunctionName name: String) -> Int? {
        let prefix = "len_"
        guard name.hasPrefix(prefix) else { return nil }
        let digits = name.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let length = Int(digits), length > 0 else { return nil }
        return length
    }

    /// The length -> function map to run, or nil for a single-function model.
    /// A model that lists two or more functions wins: each is keyed by the one input
    /// length it declares, else the length in its `len_<samples>` name, and functions
    /// with neither are left out. Otherwise the configured map is used. Throws when
    /// two functions take the same length, when none of the model's functions has a
    /// length, or when the configured map has a non-positive length or empty name.
    static func resolve(
        modelFunctions: [(name: String, inputLength: Int?)]?, configured: [Int: String]?
    ) throws -> [Int: String]? {
        if let modelFunctions, modelFunctions.count >= 2 {
            var map: [Int: String] = [:]
            for function in modelFunctions {
                guard let samples = function.inputLength ?? Self.length(fromFunctionName: function.name),
                      samples > 0 else { continue }
                if let other = map[samples] {
                    throw CoreMLSpeakerEmbedderError(
                        "model functions \(other) and \(function.name) both take \(samples) samples")
                }
                map[samples] = function.name
            }
            guard !map.isEmpty else {
                throw CoreMLSpeakerEmbedderError(
                    "none of the model's \(modelFunctions.count) functions takes one fixed input length")
            }
            return map
        }
        guard let configured else { return nil }
        guard !configured.isEmpty, configured.allSatisfy({ $0.key > 0 && !$0.value.isEmpty }) else {
            throw CoreMLSpeakerEmbedderError("functionsByLength needs positive lengths and function names")
        }
        return configured
    }

    /// The compiled model's functions, each with the one input length its input
    /// declares (nil when that input takes several lengths). A single-function model
    /// lists at most one function; nil when the list can't be read. Only listed
    /// names are ever asked about: Core ML raises an exception for an unknown one.
    static func readModelFunctions(at url: URL, inputName: String?) -> [(name: String, inputLength: Int?)]? {
        guard let asset = try? MLModelAsset(url: url) else { return nil }
        let reply: [String]?? = waitForCallback { done in
            asset.functionNames { functionNames, _ in done(functionNames) }
        }
        guard let listed = reply ?? nil else { return nil }
        guard listed.count >= 2 else {
            return listed.map { (name: $0, inputLength: Int?.none) }
        }
        return listed.map { functionName -> (name: String, inputLength: Int?) in
            let declared: Int?? = waitForCallback { done in
                asset.modelDescription(ofFunctionNamed: functionName) { modelDescription, _ in
                    done(modelDescription.flatMap {
                        CoreMLVoiceprintFunctions.fixedInputLength(of: $0, inputName: inputName)
                    })
                }
            }
            return (name: functionName, inputLength: declared ?? nil)
        }
    }

    /// The one length the voiceprint input of `description` takes, if it takes one.
    static func fixedInputLength(of description: MLModelDescription, inputName: String?) -> Int? {
        let inputs = description.inputDescriptionsByName
        let feature = inputName.flatMap { inputs[$0] } ?? inputs["audio"]
            ?? (inputs.count == 1 ? inputs.values.first : nil)
        guard let constraint = feature?.multiArrayConstraint else { return nil }
        return CoreMLVoiceprintModel.inputLengths(of: constraint)?.fixedLength
    }

    /// Runs a completion-handler Core ML call synchronously (model setup only; never
    /// on a real-time thread). nil if it doesn't call back within 30 s.
    private static func waitForCallback<T: Sendable>(
        _ start: (@escaping @Sendable (T) -> Void) -> Void
    ) -> T? {
        let box = CoreMLCallbackBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        start { value in
            box.lock.lock()
            box.value = value
            box.lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else { return nil }
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.value
    }
}

/// Holds one callback's value for `CoreMLVoiceprintFunctions.waitForCallback`.
private final class CoreMLCallbackBox<T>: @unchecked Sendable {
    let lock = NSLock()
    var value: T?
}
