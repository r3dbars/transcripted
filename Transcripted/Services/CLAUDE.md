# Services — CLAUDE.md

## Purpose
Local ML inference engines (Parakeet STT, Sortformer diarization), persistent speaker voice database, audio resampling, and optional Qwen speaker name inference. All services run 100% on-device — no cloud APIs.

## Files

| File | Responsibility | Threading |
|---|---|---|
| `ParakeetService.swift` | Local STT via FluidAudio Parakeet TDT V3 (~600MB CoreML) | @MainActor, nonisolated for transcription |
| `SortformerService.swift` | Speaker diarization via FluidAudio Sortformer | @MainActor, nonisolated for diarization |
| `SpeakerDatabase.swift` | SQLite with 256-dim voice embeddings, cosine similarity matching | Singleton (.shared), DispatchQueue serial |
| `AudioResampler.swift` | Audio format conversion (48kHz→16kHz mono), WAV loading | Static methods |
| `QwenService.swift` | Local Qwen3.5-4B for speaker name inference from transcript | @MainActor, nonisolated for inference |
| `EmbeddingClusterer.swift` | Post-processing: pairwise merge + DB-informed split | Static methods |
| `SpeakerClipExtractor.swift` | Extracts 5-8s audio clips per speaker for naming UI | Static methods |

## Key Types

**ParakeetService**: `@Published modelState: ParakeetModelState` (.notLoaded/.loading/.ready/.failed). `initialize()` async loads from bundle or HuggingFace. `transcribe(audioURL:)` nonisolated — loads, resamples to 16kHz, transcribes. `transcribeSegment(samples:source:)` nonisolated — pre-resampled input. Uses FluidAudio `AsrManager`.

**SortformerService**: `@Published modelState: SortformerModelState`. `initialize()` async. `diarize(samples:sampleRate:)` nonisolated → `[SpeakerSegment]`. Uses FluidAudio `DiarizerManager`.

**SpeakerSegment**: `speakerId: Int`, `startTime: Double`, `endTime: Double`, `embedding: [Float]?` (256-dim), `qualityScore: Double`, `duration: Double` (computed).

**SpeakerDatabase**: Singleton (`SpeakerDatabase.shared`). NOT @MainActor — internal DispatchQueue.
- `matchSpeaker(embedding:threshold:)` → `SpeakerMatchResult?` (profile + similarity score)
- `addOrUpdateSpeaker(embedding:existingId:)` → `SpeakerProfile` (creates or EMA-blends)
- `setDisplayName(id:name:source:)` async — source: "user_manual" or "qwen_inferred"
- `allSpeakers()`, `getSpeaker(id:)`, `deleteSpeaker(id:)`, `mergeProfiles(sourceId:into:)`
- `findProfilesByName(_:)` — fuzzy matching with name variants
- `pruneWeakProfiles()` — removes unnamed, single-call, low-confidence, stale (>1hr) profiles

**SpeakerProfile**: `id: UUID`, `displayName: String?`, `nameSource: String?`, `embedding: [Float]` (256-dim), `confidence: Double`, `callCount: Int`, `disputeCount: Int`.

**QwenService**: `@Published modelState: QwenModelState`. On-demand only — NOT loaded at startup.
- `loadModel()` async — downloads ~2.5GB Qwen3.5-4B-4bit if not cached
- `inferSpeakerNames(transcript:)` nonisolated → `[String: String]` ("0": "Jack", "1": "Sarah")
- `unload()` — frees memory immediately
- `static isEnabled` → UserDefaults "enableQwenSpeakerInference"
- `static isModelCached` → checks ~/Library/Caches/models/mlx-community/Qwen3.5-4B-4bit/

**AudioResampler**: `resample(_:from:to:)`, `loadWAV(url:)` → (samples, sampleRate), `loadAndResample(url:targetRate:)`, `extractSlice(from:sampleRate:startTime:endTime:)`. Stereo→mono by averaging.

**EmbeddingClusterer**: `postProcess(segments:existingProfiles:)` → applies pairwise merge then DB-informed split. Fixes fragmentation (same speaker→multiple IDs) and merging (different speakers→same ID).

## Speaker Matching Algorithm
- **Embeddings**: 256-dim WeSpeaker, L2-normalized, cosine similarity via Accelerate vDSP
- **Adaptive threshold**: 0.85 (1 segment) → 0.80 (2) → 0.75 (3) → 0.70 (4+ segments)
- **EMA blending**: alpha=0.15 for embedding updates on match
- **Post-processing** (EmbeddingClusterer):
  - Pairwise merge: union-find transitive, 0.85 cosine threshold
  - DB-informed split: per-segment 0.62 threshold, requires 8+ segments per profile to split
- **Name variants**: 34 hardcoded pairs ("mike"↔"michael", "nate"↔"nathan", etc.) in `areNameVariants()`
- **Pruning**: `pruneWeakProfiles()` removes unnamed profiles with 1 call, low confidence, >1hr stale

## Model Lifecycle
- **Parakeet + Sortformer**: Loaded at app startup via `Transcription.initializeModels()`. From bundle (`Contents/Resources/*-models/`) or HuggingFace download on first run.
- **Qwen**: Loaded on-demand when unidentified speakers exist. `loadModel()` → `inferSpeakerNames()` → `unload()`. Requires ~4GB free memory (checked via `mach_host_self()` free pages). Model cached at `~/Library/Caches/models/mlx-community/Qwen3.5-4B-4bit/`.
- **State progression**: `.notLoaded` → `.loading` → `.ready` | `.failed(String)`

## Modification Recipes

| Task | Files to touch |
|---|---|
| Adjust speaker matching sensitivity | `SpeakerDatabase.swift` — threshold constants in `matchSpeaker()` |
| Change STT model | `ParakeetService.swift` — update `AsrModels` loading path |
| Change diarization model | `SortformerService.swift` — update `DiarizerModels` loading path |
| Add speaker DB field | `SpeakerDatabase.swift` — createTables + migrateSchema + SpeakerProfile struct |
| Fix Qwen inference | `QwenService.swift` — check model cache path, prompt in `buildChatMessages()` |
| Fix audio resampling | `AudioResampler.swift` — system audio rate from device nominal rate, not tap format |
| Add name variant | `SpeakerDatabase.swift` — `areNameVariants()` dictionary |
| Fix embedding clustering | `EmbeddingClusterer.swift` — pairwiseMerge threshold or dbInformedSplit params |

## Gotchas
- SpeakerDatabase is singleton — always use `.shared`
- Qwen needs 4GB free memory — `hasMemoryForQwen()` check in TranscriptionTaskManager
- AudioResampler: system audio rate comes from the WAV file header (set by device nominal rate)
- Qwen prompt has critical rule: "Hey Jack" = talking TO Jack, not introducing self
- Sortformer max 4 speakers per diarization run
- SpeakerClipExtractor writes temp clips — call `cleanupClips()` after use
- Speaker clips persisted at `~/Documents/Transcripted/speaker_clips/{UUID}.wav`

## Logging Subsystems
`transcription` — Parakeet/Sortformer model loading, transcription/diarization results
`speaker-db` — database open/close, speaker matching, merges, pruning
`services` — Qwen loading, inference results
