// DiarizationBackend.swift
// Which speaker-diarization model `DiarizationService` runs. Pure value type with
// no FluidAudio dependency so hosts, settings, and the speaker lab can name a
// backend without importing the model stack.

import Foundation

/// Which speaker-diarization model splits meeting audio into speaker turns.
public enum DiarizationBackend: String, CaseIterable, Sendable, Codable {
    /// FluidAudio's offline pyannote community-1 pipeline (segmentation +
    /// WeSpeaker + VBx). Today's default; emits a native 256-d WeSpeaker
    /// embedding per segment.
    case pyannote
    /// NVIDIA Nemotron 3 Diarization via FluidAudio (streaming Sortformer
    /// successor, up to 8 speakers, 10 ms frames). Experimental and off by
    /// default. It emits no speaker embeddings, so `DiarizationService` derives
    /// one per turn with the injected `SpeakerSegmentEmbedder`, or with
    /// `FluidWeSpeakerSegmentEmbedder` when none is injected.
    case nemotron
}
