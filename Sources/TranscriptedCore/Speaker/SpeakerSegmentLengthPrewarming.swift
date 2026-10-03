// SpeakerSegmentLengthPrewarming.swift
// An embedder that can get ready for a known set of turns before it embeds them.
//
// A multifunction Core ML voiceprint (ReDimNet2) runs each turn on the function
// built for its length, and a function's first prediction after a load costs about
// 100 ms of GPU setup. `DiarizationService` knows every turn's length as soon as
// diarization ends, so it hands them over here on a background queue and the
// first predictions overlap instead of landing one at a time on re-embedding.

import Foundation

/// A `SpeakerSegmentEmbedder` that can warm up for turns of known lengths.
public protocol SpeakerSegmentLengthPrewarming: SpeakerSegmentEmbedder {
    /// Gets ready to embed turns of these sample counts (16 kHz). May block; never
    /// call it on the main thread. Never changes what `embed` returns.
    func prewarm(sampleCounts: [Int])
}
