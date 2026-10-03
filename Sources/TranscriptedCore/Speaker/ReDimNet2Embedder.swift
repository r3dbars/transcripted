// ReDimNet2Embedder.swift
// The default voiceprint: ReDimNet2 b4 by Palabra.ai (MIT; builds on ID R&D's ReDimNet),
// weights trained on VoxCeleb2 (CC BY 4.0; credits in THIRD_PARTY_LICENSES.md),
// converted to a fused Core ML model (raw 16 kHz audio -> 192-dim vector) by
// scripts/voiceprint/convert/redimnet_slim.py.
//
// The voiceprint bake-off picked it over WeSpeaker ResNet34 (the diarizer's own
// embedding, used before): on call audio it recognizes 83.0% vs 74.6% of same-person
// pairs at 1 false accept in 1,000, and names 85.8% vs 70.2% of people in a
// 334-person lineup with zero wrong names (Tools/SpeakerEvalHarness/VOICEPRINT_RESULTS.md).
//
// The model is a multifunction package, one fixed-length function per input length
// (1, 2, 4 and 8 s, fp16): a single flexible-length graph re-plans on every length
// change and falls off the GPU. `CoreMLSpeakerSegmentEmbedder` tiles each piece up to
// the next length and routes it to that length's function. Loading a function costs
// a few MB; its GPU memory comes with its first prediction (about 370 MB for the 8 s
// function, 470-540 MB with all four in use, settling to about 210-230 MB a few
// seconds after the last call). They are released after a minute without a call and
// reload on the next meeting: the pipeline reloads all four at job start (load only)
// and warms the lengths a meeting's turns need just before re-embedding them.

import Foundation
import CoreML

@available(macOS 14.0, *)
public enum ReDimNet2Embedder {
    /// Embedder id; the speaker database for this model is `speakers_redimnet2-b4.sqlite`.
    public static let identifier = "redimnet2-b4"
    public static let dimension = 192
    /// Longest window (8 s, the model's largest function); longer turns are windowed
    /// and pooled by talk time.
    public static let windowSamples = 128_000
    /// Release the loaded functions after this long without a call.
    public static let idleReleaseSeconds: TimeInterval = 60

    /// ReDimNet2's settings for the generic embedder. CPU+GPU, not the Neural Engine:
    /// the build is tuned for the GPU, and with `.all` the 1 s function ran 2.7x slower.
    public static func configuration(modelURL: URL) -> CoreMLSpeakerEmbedderConfiguration {
        CoreMLSpeakerEmbedderConfiguration(
            modelURL: modelURL,
            identifier: identifier,
            dimension: dimension,
            thresholds: .reDimNet2B4,
            windowSamples: windowSamples,
            pooling: .talkTimeWeighted,
            computeUnits: .cpuAndGPU,
            idleReleaseSeconds: idleReleaseSeconds
        )
    }

    /// Loads the compiled `.mlmodelc` at `modelURL`; nil if it is missing or fails to
    /// load, so the caller can fall back to the diarizer's own voiceprint.
    public static func load(modelURL: URL) -> CoreMLSpeakerSegmentEmbedder? {
        do {
            return try CoreMLSpeakerSegmentEmbedder(configuration: configuration(modelURL: modelURL))
        } catch {
            let reason = (error as? CoreMLSpeakerEmbedderError)?.message ?? "load failed"
            AppLogger.speakers.error("ReDimNet2 voiceprint failed to load", ["reason": reason])
            return nil
        }
    }
}
