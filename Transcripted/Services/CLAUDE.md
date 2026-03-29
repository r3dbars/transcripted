# Services Folder

ML pipeline services, speaker database, audio processing utilities, meeting detection, and service protocols. 18 Swift files across root and Protocols/.

## File Index

### Root (11 files)

| File | Actor | Purpose |
|------|-------|---------|
| `ParakeetService.swift` | @MainActor | Local ASR via FluidAudio's Parakeet TDT V3 CoreML. Batch only. Downloads via ModelDownloadService with mirror fallback. |
| `DiarizationService.swift` | @MainActor | Dual-pipeline: Sortformer (streaming) + PyAnnote (offline). Downloads via ModelDownloadService with mirror fallback. |
| `SpeakerDatabase.swift` | Utility queue | SQLite at ~/Documents/Transcripted/speakers.sqlite, core CRUD + schema |
| `SpeakerEmbeddingMatcher.swift` | Utility queue | Cosine similarity matching against stored speaker profiles (vDSP-accelerated) |
| `SpeakerProfile.swift` | -- | SpeakerProfile struct (256-dim embeddings) + SpeakerMatchResult + NameSource constants (userManual, qwenInferred) |
| `SpeakerProfileMerger.swift` | Utility queue | Profile name updates, merging, pruning, and name variant lookup |
| `QwenService.swift` | @MainActor | On-device Qwen3.5-4B-4bit via mlx-swift-lm, on-demand load/unload. Pre-populates cache via ModelDownloadService with mirror fallback and progress tracking. |
| `EmbeddingClusterer.swift` | Static | 3-stage post-processing: pairwise merge, small cluster absorption, DB-informed split |
| `AudioResampler.swift` | Static | AVAudioConverter-based resampling to 16kHz, WAV loading, slice extraction |
| `SpeakerClipExtractor.swift` | Static | Extract per-speaker audio clips for naming UI playback, 0o600 permissions on temp clips and persistent clips |
| `MeetingDetector.swift` | @MainActor | Monitors Zoom/Teams/Webex/FaceTime, auto-triggers recording |

### Protocols/ (7 files) — see Protocols/CLAUDE.md

| File | Purpose |
|------|---------|
| `SpeechToTextEngine.swift` | Protocol for ASR (conformer: ParakeetService). Defines AudioSource enum. |
| `DiarizationEngine.swift` | Protocol for speaker diarization (conformer: DiarizationService) |
| `SpeakerNamingEngine.swift` | Protocol for LLM-based name inference (conformer: QwenService) |
| `SpeakerStore.swift` | Protocol for speaker database (conformer: SpeakerDatabase) |
| `AudioCaptureEngine.swift` | Protocol for audio recording (conformer: Audio) |
| `StatsStore.swift` | Protocol for stats persistence (conformer: StatsDatabase) |
| `TranscriptStorage.swift` | Protocol for transcript file I/O (conformer: TranscriptSaver) |

## Pipeline Order
```
1. ParakeetService.transcribeSegment(samples, source) -> String
2. DiarizationService.diarizeOffline(samples, sampleRate) -> [SpeakerSegment]
3. EmbeddingClusterer.postProcess(segments, profiles, skipPairwiseMerge) -> [SpeakerSegment]
4. SpeakerDatabase.matchSpeaker(embedding, threshold) -> SpeakerMatchResult?
5. QwenService.inferSpeakerNames(transcript) -> [String: String]  // {"0": "Jack", "1": "Sarah"}
```

## Key Data Types (SpeakerProfile.swift + TranscriptionTypes.swift)
```swift
struct SpeakerSegment {
    let speakerId: Int, startTime: Double, endTime: Double
    let embedding: [Float]?    // 256-dim WeSpeaker
    let qualityScore: Float    // 0-1
}

struct SpeakerProfile: Identifiable {
    let id: UUID
    var displayName: String?, nameSource: String?  // NameSource.userManual | .qwenInferred
    var embedding: [Float]     // 256-dim average
    var firstSeen: Date, lastSeen: Date, callCount: Int
    var confidence: Double     // 0.5-1.0, +0.1 per update, capped at 1.0
    var disputeCount: Int
}

struct SpeakerMatchResult { let profile: SpeakerProfile, similarity: Double }
```

## Speaker DB Schema (SpeakerDatabase.swift)
```sql
CREATE TABLE speakers (
    id TEXT PRIMARY KEY,          -- UUID string
    display_name TEXT,
    name_source TEXT DEFAULT NULL, -- "user_manual", "qwen_inferred"
    embedding BLOB NOT NULL,       -- 256-dim float32 binary
    first_seen TEXT NOT NULL,      -- ISO8601
    last_seen TEXT NOT NULL,
    call_count INTEGER DEFAULT 1,
    confidence REAL DEFAULT 0.5,
    dispute_count INTEGER DEFAULT 0,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
```
WAL mode, busy_timeout 5000ms, 0o600 permissions. All writes via dedicated utility queue.

## SpeakerDatabase Key Methods (split across SpeakerDatabase + SpeakerEmbeddingMatcher + SpeakerProfileMerger)
- `matchSpeaker(embedding:, threshold: 0.6)` -> best match above threshold via cosine similarity (vDSP-accelerated) — SpeakerEmbeddingMatcher
- `addOrUpdateSpeaker(embedding:, existingId:)` -> NEW: confidence=0.5, callCount=1. UPDATE: EMA blend (alpha=0.15), confidence += 0.1, callCount += 1 — SpeakerDatabase
- `setDisplayName(id:, name:, source:)` -> updates name + source provenance — SpeakerProfileMerger
- `allSpeakers()`, `getSpeaker(id:)`, `deleteSpeaker(id:)` — SpeakerDatabase
- `findProfilesByName(_:)` (fuzzy, with name variants) — SpeakerProfileMerger
- `mergeProfiles(sourceId:, into:)` -> blend by callCount weight, atomic transaction — SpeakerProfileMerger
- `pruneWeakProfiles()` -> deletes unnamed AND callCount<=1 AND confidence<=0.5 AND age>1hr — SpeakerProfileMerger
- `mergeProfilesByName()` -> merges profiles that ended up with the same name (e.g., "Jenny Wen") — SpeakerDatabase
- `getColumnNames(tableName:)` -> PRAGMA table_info with compile-time allowlist validation for SQL injection prevention — SpeakerDatabase

## Cosine Similarity Thresholds (vary by context)
| Context | Threshold | Purpose |
|---------|-----------|---------|
| `matchSpeaker()` default | 0.60 | New segment matching |
| Pairwise merge (EmbeddingClusterer) | 0.85 | Very conservative cluster merge |
| Small cluster absorption | 0.72 | Merge short interjections |
| Micro-cluster absorption (<10s) | 0.62 | Absorb noise fragments (above codec similarity range) |
| DB-informed split per-segment | 0.62 | Re-separate mixed clusters |
| Adaptive threshold (1 segment) | 0.85 | High certainty for single segment |
| Adaptive threshold (2-3 segments) | 0.78 | Moderate caution |
| Adaptive threshold (4+ segments) | 0.70 | Reliable mean embedding |

## EmbeddingClusterer 3-Stage Pipeline (EmbeddingClusterer.swift)
```
postProcess(segments, existingProfiles, skipPairwiseMerge):
  Stage 1 - Pairwise Merge (skip for PyAnnote, VBx already handles):
    Union-find graph, merge clusters with mean similarity >= 0.85
  Stage 2 - Small Cluster Absorption:
    Micro-clusters (<10s): absorb at 0.62 threshold (above codec similarity range)
    Clusters with 3+ segments protected from absorption (real speaker)
    Small clusters (10-30s): absorb at 0.72 threshold
  Stage 3 - DB-Informed Split:
    Per-segment matching against known profiles (threshold 0.62)
    Minimum 8 segments per profile to claim ownership
    Splits mixed clusters where diarizer merged 2+ speakers
```

## QwenService Details (QwenService.swift)
- **Model**: `mlx-community/Qwen3.5-4B-4bit` (~2.5GB)
- **Cache**: `~/Library/Caches/models/mlx-community/Qwen3.5-4B-4bit`
- **Download**: Pre-populates cache via `ModelDownloadService.prePopulateQwenCache()` with HuggingFace mirror fallback, progress tracking, and disk space validation. Falls back to mlx-swift-lm's built-in download on failure.
- **Inference**: temperature=0.1 (deterministic), maxTokens=200
- **Prompt**: Teaches model that "Hey Jack" means speaker is talking TO Jack (listener), not IS Jack
- **Output**: JSON keys are speaker numbers ("0", "1"), values are names or "Unknown"
- **Response parsing**: Strips markdown fences, extracts JSON, returns `[:]` on parse failure
- **Lifecycle**: Load on-demand -> inference -> unload immediately (frees ~2.5GB)
- **Double-load guard**: Prevents 2x memory allocation during concurrent async calls

## MeetingDetector (MeetingDetector.swift)
- **Known apps**: Zoom (`us.zoom.xos`), Teams (`com.microsoft.teams2`), Webex, FaceTime, Loom
- **Detection**: NSWorkspace app launch/quit notifications + 1s polling
- **Auto-start trigger**: Both mic + system audio > 0.02 for >= 5 seconds
- **Auto-stop**: 15 seconds of silence grace period
- **Manual override**: Only auto-stops recordings it auto-triggered, not manual ones

## AudioResampler (AudioResampler.swift)
- `loadAndResample(url:, targetRate: 16000)` -> hardware-accelerated via AVAudioConverter
- Streams in 30-second chunks to avoid memory spikes
- Handles stereo-to-mono + rate conversion in one pass
- Single `convert()` call to avoid AVAudioConverter terminal state bug

## SpeakerClipExtractor (SpeakerClipExtractor.swift)
- Extracts per-speaker clips for naming UI: prefers single long utterance >= 3s, else concatenates (cap 8s)
- Persistent clips at `~/Documents/Transcripted/speaker_clips/{speakerId}.wav`
- Overwrites on subsequent recordings (keeps latest voice sample)

## Name Variants (SpeakerProfileMerger.swift)
Hardcoded lookup table: mike/michael/mikey, nate/nathan/nathaniel, dave/david, alex/alexander/alexandra, dan/daniel/danny, matt/matthew, chris/christopher, nick/nicholas, rob/robert/bob, + 15 more. Also substring matching.

## Key Splits from Original Files
- `SpeakerDatabase.swift` was split into: SpeakerDatabase (core CRUD + schema), SpeakerEmbeddingMatcher (matching), SpeakerProfile (data models), SpeakerProfileMerger (name management, merging, pruning)
- All 7 Protocols/ files are new -- extracted interfaces for dependency injection via AppServices

## Threading Rules
- **SpeakerDatabase, SpeakerEmbeddingMatcher, SpeakerProfileMerger** -- dedicated utility queue (`com.transcripted.speakerdb`), NOT @MainActor
- **ParakeetService, DiarizationService, QwenService, MeetingDetector** -- @MainActor
- **EmbeddingClusterer, AudioResampler, SpeakerClipExtractor** -- static methods, called from pipeline threads

## Model Download Resilience (via Core/ModelDownloadService.swift)
All three ML services (Parakeet, Diarization, Qwen) use `ModelDownloadService` for resilient downloads:
- **Mirror fallback**: Primary `huggingface.co` -> fallback `hf-mirror.com`
- **Retry**: Exponential backoff (2s, 5s, 10s), max 3 attempts per mirror
- **Error classification**: `DownloadErrorKind` (networkOffline, tlsFailure, timeout, diskSpace, serverError, unknown) with user-friendly messages
- **Network check**: NWPathMonitor reachability probe with 3s timeout
- **Disk validation**: Requires ~2.5GB free for Qwen
- Services call `ModelDownloadService.withRetry()` for Parakeet/Diarization, `ModelDownloadService.prePopulateQwenCache()` for Qwen
- Errors classified via `ModelDownloadService.classifyError()` and surfaced to UI as `OnboardingState.modelErrorKind`

## Gotchas
- EMA alpha=0.15 is SLOW: takes 6-7 updates to meaningfully shift a speaker profile
- Embeddings can be both `nil` AND empty `[]` -- check both
- SpeakerDatabase silently returns in-memory dummy profiles if DB open fails (logs CRITICAL)
- Qwen has no chunk limits on input -- very long transcripts could exceed context window
- Quality filter cascades: EmbeddingClusterer hardcodes qualityScore >= 0.3 AND duration >= 1.0s
- New speaker IDs from EmbeddingClusterer start above max existing ID (can create gaps)
- Pruning is conservative: only deletes unnamed profiles after 1 hour
- WAL mode leaves .sqlite-wal and .sqlite-shm files alongside DB (expected)
