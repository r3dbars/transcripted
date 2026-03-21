# Services Folder

ML pipeline for speech-to-text, speaker diarization, and name inference.

## Pipeline Order

1. **ParakeetService** — Local ASR using FluidAudio's Parakeet TDT V3 CoreML model. Batch transcription only (no live streaming).
2. **DiarizationService** — Dual-pipeline speaker diarization:
   - Streaming (Sortformer): Real-time diarization for live preview (future use), up to 4 speakers.
   - Offline (PyAnnote): Post-recording diarization with WeSpeaker embeddings + VBx clustering, unlimited speakers.
3. **SpeakerDatabase** — Persistent SQLite storage for 256-dim speaker embeddings and matching.
4. **QwenService** — On-device speaker name inference using Qwen3.5-4B via mlx-swift-lm, loads on-demand only.

## Key Files

- **ParakeetService.swift** — ASR initialization, model loading from bundle or HuggingFace (~600MB), batch transcription.
- **DiarizationService.swift** — DiarizerManager (streaming) and OfflineDiarizerManager (PyAnnote), produces SpeakerSegment with embeddings.
- **SpeakerDatabase.swift** — SQLite database at `~/Documents/Transcripted/speakers.sqlite`, stores SpeakerProfile with 256-dim embeddings.
- **QwenService.swift** — Loads Qwen3.5-4B-4bit model on-demand (~2.5GB), infers names from transcript text, unloads after inference.

## Speaker DB Schema

- **Table**: `speakers`
- **Columns**: id (UUID), displayName (String?), nameSource (String?), embedding (BLOB 256-dim), firstSeen (Date), lastSeen (Date), callCount (Int), confidence (Double), disputeCount (Int)
- **Matching**: Cosine similarity between new embedding and stored embeddings, threshold-based assignment.

## Model Cache Locations

- **Parakeet**: Bundled in app or downloaded to system temp (~600MB)
- **Qwen**: `~/Library/Caches/models/mlx-community/Qwen3.5-4B-4bit` (~2.5GB)
- **Diarization**: Bundled or downloaded via FluidAudio

## Threading Rules

- All services are `@MainActor` — never call from background threads.
- SpeakerDatabase uses a dedicated utility queue for SQLite operations.
- QwenService loads on-demand to avoid 2.5GB memory spike at app startup.
- Never commit to main — these are production-critical ML components.

## Critical Notes

- Parakeet: No I/O in CoreAudio callbacks, batch transcription only.
- Diarization: Both pipelines produce identical 256-dim WeSpeaker embeddings.
- Qwen: Unloads immediately after inference to free memory.
- SpeakerDatabase: Thread-safe with queue-based SQLite access.
