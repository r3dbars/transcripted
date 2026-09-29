// LabVoiceprintEmbedder.swift — load any fused Core ML voiceprint model for a lab run.
//
//   --embedder-model <model.mlmodelc>   raw 16 kHz audio [1, N] -> embedding [1, D]
//   --embedder-id <id>                  names the run's throwaway speaker DB (speakers_<id>.sqlite)
//   --embedder-dim <D>                  embedding size; the model's output must match
//   [--embedder-thresholds <json>]      calibrated cosine bars (SpeakerEmbeddingThresholds.load);
//                                       without it the WeSpeaker bars are used, with a warning
//   [--embedder-window-s <s>]           long-turn window (default: the longest accepted length up
//                                       to 30 s; on an enumerated model it must be one of its lengths)
//   [--embedder-hop-s <s>]              long-turn hop (default: the window, no overlap)
//   [--embedder-pooling talk-time|equal]  how windows combine (default talk-time)
//
// Accepted lengths come from the model's input shape (range, enumerated, or fixed). The model is loaded and
// probed once before any meeting runs; a model that can't load or embed stops the
// run instead of falling back to another voiceprint, so a result always means what
// its flags say.

import Foundation
import TranscriptedCore

struct LabVoiceprintEmbedder {
    let embedder: CoreMLSpeakerSegmentEmbedder
    let thresholdsSource: String

    static let flags = [
        "--embedder-model", "--embedder-id", "--embedder-dim", "--embedder-thresholds",
        "--embedder-window-s", "--embedder-hop-s", "--embedder-pooling",
    ]

    /// nil when no `--embedder-*` flag was given (the run keeps Core's default voiceprint).
    @available(macOS 14.0, *)
    static func load(from args: [String]) -> LabVoiceprintEmbedder? {
        guard flags.contains(where: { args.contains($0) }) else { return nil }
        guard let modelPath = argValue("--embedder-model", in: args),
              let identifier = argValue("--embedder-id", in: args),
              let dimensionRaw = argValue("--embedder-dim", in: args) else {
            die("a custom voiceprint needs --embedder-model <model.mlmodelc> --embedder-id <id> --embedder-dim <D>")
        }
        guard let dimension = Int(dimensionRaw), dimension > 0 else { die("--embedder-dim wants a positive integer") }
        guard FileManager.default.fileExists(atPath: modelPath) else { die("voiceprint model not found at \(modelPath)") }

        let thresholds: SpeakerEmbeddingThresholds
        let thresholdsSource: String
        if let thresholdsPath = argValue("--embedder-thresholds", in: args) {
            do {
                thresholds = try SpeakerEmbeddingThresholds.load(contentsOf: URL(fileURLWithPath: thresholdsPath))
            } catch {
                die("--embedder-thresholds \(thresholdsPath): \(error.localizedDescription)")
            }
            thresholdsSource = "file"
        } else {
            thresholds = .weSpeaker
            thresholdsSource = "wespeaker-default"
            log("[lab] WARNING: no --embedder-thresholds; using WeSpeaker's cosine bars, "
                + "which do not fit another model's geometry")
        }

        func samples(_ flag: String) -> Int? {
            guard let raw = argValue(flag, in: args) else { return nil }
            guard let seconds = Double(raw), seconds > 0 else { die("\(flag) wants seconds > 0") }
            return Int((seconds * Double(CoreMLSpeakerSegmentEmbedder.sampleRate)).rounded())
        }
        let poolingRaw = argValue("--embedder-pooling", in: args) ?? SpeakerEmbeddingPooling.talkTimeWeighted.rawValue
        guard let pooling = SpeakerEmbeddingPooling(rawValue: poolingRaw) else {
            die("--embedder-pooling wants \(SpeakerEmbeddingPooling.allCases.map(\.rawValue).joined(separator: "|"))")
        }

        let configuration = CoreMLSpeakerEmbedderConfiguration(
            modelURL: URL(fileURLWithPath: modelPath),
            identifier: identifier,
            dimension: dimension,
            thresholds: thresholds,
            windowSamples: samples("--embedder-window-s"),
            hopSamples: samples("--embedder-hop-s"),
            pooling: pooling
        )
        let embedder: CoreMLSpeakerSegmentEmbedder
        do {
            embedder = try CoreMLSpeakerSegmentEmbedder(configuration: configuration)
        } catch {
            die("voiceprint model \(identifier) failed to load: \(error.localizedDescription)")
        }

        // One real call before any meeting: a short and a multi-window clip must embed.
        for seconds in [1.0, 2.5 * Double(embedder.plan.windowSamples) / Double(CoreMLSpeakerSegmentEmbedder.sampleRate)] {
            let probe = probeAudio(seconds: min(seconds, 90))
            guard let vector = embedder.embed(samples: probe, sampleRate: CoreMLSpeakerSegmentEmbedder.sampleRate),
                  vector.count == dimension else {
                die("voiceprint model \(identifier) returned no \(dimension)-d embedding for a \(String(format: "%.1f", seconds)) s probe")
            }
        }
        let plan = embedder.plan
        log(String(format: "[lab] voiceprint %@ (%d-d, thresholds %@): %.2f-%.1f s per call (%@), window %.1f s, hop %.1f s, %@ pooling",
                   identifier, dimension, thresholdsSource,
                   Double(plan.minSamples) / 16_000, Double(plan.maxSamples) / 16_000,
                   plan.allowedLengths.map { "\($0.count) enumerated lengths" } ?? "any length",
                   Double(plan.windowSamples) / 16_000, Double(plan.hopSamples) / 16_000, plan.pooling.rawValue))
        return LabVoiceprintEmbedder(embedder: embedder, thresholdsSource: thresholdsSource)
    }

    /// Speaker DB file for the run, named like the app names per-model databases
    /// (`SpeakerEmbedderPreferences.speakerDBFileName`), so vectors of different
    /// models never share a database even when runs share a work folder.
    var speakerDBFileName: String { "speakers_\(embedder.identifier).sqlite" }

    /// Deterministic voice-like probe: a gliding harmonic tone with a little noise.
    static func probeAudio(seconds: Double) -> [Float] {
        let rate = Double(CoreMLSpeakerSegmentEmbedder.sampleRate)
        let count = max(1, Int(seconds * rate))
        var seed: UInt32 = 12_345
        return (0..<count).map { i in
            let t = Double(i) / rate
            let f0 = 140 + 30 * sin(2 * Double.pi * 3 * t)
            var sample = 0.0
            for harmonic in 1...5 { sample += sin(2 * Double.pi * f0 * Double(harmonic) * t) / Double(harmonic) }
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed >> 8) / Double(1 << 24) - 0.5
            return Float(0.15 * sample + 0.02 * noise)
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
