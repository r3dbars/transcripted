# Services Folder

ML pipeline services, speaker database, audio processing utilities, meeting detection, and service protocols. 18 Swift files across root and Protocols/.

## File Index

### Root (11 files)

| File | Actor | Purpose |
|------|-------|---------|
| `ParakeetService.swift` | @MainActor | Local ASR via FluidAudio's Parakeet TDT V3 CoreML. Batch only. |
| `DiarizationService.swift` | @MainActor | Dual-pipeline: Sortformer (streaming) + PyAnnote (offline) |
| `SpeakerDatabase.swift` | Utility queue | SQLite at ~/Documents/Transcripted/speakers.sqlite, core CRUD + schema |
| `SpeakerEmbeddingMatcher.swift` | Utility queue | Cosine similarity matching against stored speaker profiles (vDSP-accelerated) |
| `SpeakerProfile.swift` | -- | SpeakerProfile struct (256-dim embeddings) + SpeakerMatchResult |
| `SpeakerProfileMerger.swift` | Utility queue | Profile name updates, merging, pruning, and name variant lookup |
| `QwenService.swift` | @MainActor | On-device Qwen3.5-4B-4bit via mlx-swift-lm, on-demand load/unload |
| `EmbeddingClusterer.swift` | Static | 3-stage post-processing: pairwise merge, small cluster absorption, DB-informed split |
| `AudioResampler.swift` | Static | AVAudioConverter-based resampling to 16kHz, WAV loading, slice extraction |
| `SpeakerClipExtractor.swift` | Static | Extract per-speaker audio clips for naming UI playback |
| `MeetingDetector.swift` | @MainActor | Monitors Zoom/Teams/Webex/FaceTime, auto-triggers recording |

### Protocols/ (7 files)

| File | Purpose |
|------|---------|
| `SpeechToTextEngine.swift` | Protocol for ASR (conformer: ParakeetService). Defines AudioSource enum. |
| `DiarizationEngine.swift` | Protocol for speaker diarization (conformer: DiarizationService) |
| `SpeakerNamingEngine.swift` | Protocol for LLM-based name inference (conformer: QwenService) |
| `SpeakerStore.swift` | Protocol for speaker database (conformer: SpeakerDatabase) |
| `AudioCaptureEngine.swift` | Protocol for audio recording (conformer: Audio) |
| `StatsStore.swift` | Protocol for stats persistence (conformer: StatsDatabase) |
| `TranscriptStorage.swift` | Protocol for transcript file I/O (conformer: TranscriptSaver) |

## Key Splits from Original Files

- `SpeakerDatabase.swift` was split into: SpeakerDatabase (core CRUD + schema), SpeakerEmbeddingMatcher (matching), SpeakerProfile (data models), SpeakerProfileMerger (name management, merging, pruning)
- All 7 Protocols/ files are new -- extracted interfaces for dependency injection via AppServices

## Threading Rules

- **SpeakerDatabase, SpeakerEmbeddingMatcher, SpeakerProfileMerger** -- dedicated utility queue (`com.transcripted.speakerdb`), NOT @MainActor
- **ParakeetService, DiarizationService, QwenService, MeetingDetector** -- @MainActor
- **EmbeddingClusterer, AudioResampler, SpeakerClipExtractor** -- static methods, called from pipeline threads

## Gotchas
- EMA alpha=0.15 is SLOW: takes 6-7 updates to meaningfully shift a speaker profile
- Embeddings can be both `nil` AND empty `[]` -- check both
- SpeakerDatabase silently returns in-memory dummy profiles if DB open fails (logs CRITICAL)
- Qwen has no chunk limits on input -- very long transcripts could exceed context window
- Quality filter cascades: EmbeddingClusterer hardcodes qualityScore >= 0.3 AND duration >= 1.0s
- Pruning is conservative: only deletes unnamed profiles after 1 hour
- WAL mode leaves .sqlite-wal and .sqlite-shm files alongside DB (expected)
