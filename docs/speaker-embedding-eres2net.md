# ERes2Net speaker embedding (codec-robust voiceprint)

Optional on-device speaker-embedding model that replaces the diarizer's built-in
WeSpeaker voiceprint for **speaker identity** — same-voice consolidation and
cross-call matching against the persistent speaker database. ERes2Net (Alibaba
3D-Speaker, 192-dim) is markedly more robust to compressed call audio (Zoom /
phone), where WeSpeaker's different-speaker embeddings drift together and get
merged into one person.

This is the productionization of the research in
`Tools/SpeakerEvalHarness/EMBEDDING_BAKEOFF_REPORT.md` /
`MASTER_SCORECARD.md` (ERes2Net ~halves within-meeting DER on compressed audio
and is the only accuracy co-winner that also converts cleanly to CoreML).

## What it does and does not change

- **Changes:** the embedding used by the app-side identity stack —
  `EmbeddingClusterer` consolidation/split and `SpeakerDatabase` matching. After
  diarization, each segment is re-embedded with ERes2Net and that vector flows
  downstream. This is exactly the "two different people merged into one speaker,
  worse on Zoom" axis.
- **Does not change:** FluidAudio's internal "who spoke when" (segmentation + VBx
  clustering still use its built-in WeSpeaker, because that's baked into the
  FluidAudio binary). Segment boundaries and the initial cluster assignment are
  untouched.

## Architecture

```
audio ─▶ FluidAudio offline diarizer (PyAnnote seg + WeSpeaker + VBx)
            │  segments + times  (WeSpeaker 256-d embeddings)
            ▼
   DiarizationService.diarizeOffline
            │  reembedIfNeeded(): slice samples per segment ─▶ ERes2NetEmbedder
            ▼
   segments with ERes2Net 192-d embeddings
            ▼
   EmbeddingClusterer.postProcess  +  SpeakerDatabase matching  (identity)
```

The model is a **single fused CoreML graph: raw 16 kHz mono audio → 192-d
embedding**. The kaldi-fbank frontend (framing + povey window + preemphasis + DC
removal + DFT) is folded into one `Conv1d`, followed by a mel `Conv1d`, `log`,
per-utterance mean-subtraction, and the ERes2Net trunk. So the Swift side does
**zero DSP** — it just feeds `[Float]` samples. Conversion parity vs the
modelscope PyTorch reference: **min cosine 0.99974** on real AMI segments.

Key code:

- `Sources/TranscriptedCore/Speaker/SpeakerSegmentEmbedder.swift` — protocol seam
- `Sources/TranscriptedCore/Speaker/ERes2NetEmbedder.swift` — CoreML wrapper
  (windows + mean-pools long segments, L2-normalizes)
- `Sources/TranscriptedCore/Services/DiarizationService.swift` —
  `reembedIfNeeded(...)` re-embeds in `diarizeOffline`
- `Sources/Support/SpeakerEmbedderPreferences.swift` — choice + env override
- `Sources/Support/SpeakerEmbedderFactory.swift` — model resolution (bundle /
  FluidAudio Models cache)
- `Sources/Meeting/MeetingSessionController.swift` — injects the embedder and
  selects the per-model DB path

## Enabling it

Default is WeSpeaker (unchanged behavior). To switch to ERes2Net:

- **Settings:** General → model settings → "Speaker voiceprint (experimental)" →
  pick ERes2Net. Restart Transcripted to apply.
- **Env override (no UI / tests):** `TRANSCRIPTED_SPEAKER_EMBEDDER=eres2net`.

ERes2Net uses a **separate database file** `state/speakers_eres2net.sqlite` so
its 192-d vectors never share a `SpeakerProfile` row with the WeSpeaker 256-d
profiles (the EMA blend would corrupt mixed dimensions). Switching models thus
starts a fresh, isolated speaker memory.

## The model artifact

The compiled `Model.mlmodelc` (~13 MB) follows the same pattern as the diarizer /
Parakeet models: **not committed**, sourced from the shared cache and bundled at
build time.

- Staged at: `~/Library/Application Support/FluidAudio/Models/eres2net-embedding/Model.mlmodelc`
- `build.sh` / `build-beta.sh` copy it into `App.app/Contents/Resources/eres2net-embedding/`.
- Runtime resolution order (`SpeakerEmbedderFactory`): app bundle → FluidAudio
  Models cache. If neither is present, the app silently falls back to WeSpeaker.

### Regenerate / stage the model

Requires the embedding venv + modelscope cache used by the research harness:

```bash
# 1) build + verify parity, compile .mlmodelc, write golden vectors
.venv_emb/bin/python3 scripts/convert_eres2net_fused.py     # -> scripts/out/eres2net_fused.mlmodelc

# 2) stage into the FluidAudio Models cache (where build.sh sources it)
mkdir -p "$HOME/Library/Application Support/FluidAudio/Models/eres2net-embedding"
cp -R scripts/out/eres2net_fused.mlmodelc \
  "$HOME/Library/Application Support/FluidAudio/Models/eres2net-embedding/Model.mlmodelc"
```

## Tests

- `Tests/TranscriptedCoreTests/ERes2NetEmbedderParityTests.swift` — asserts the
  Swift embedder reproduces the CoreML golden (cosine ≥ 0.999). Skips if the model
  isn't staged.
- `Tests/TranscriptedCoreTests/ERes2NetDiarizationE2ETests.swift` — runs the real
  diarizer + re-embed path on a wav and asserts all embeddings are 192-d. Gated on
  `TRANSCRIPTED_E2E_WAV=/path/to/16k.wav` (skips in CI).

## Known limitations / follow-ups

- **Matcher thresholds are still WeSpeaker-tuned.** The embedding-quality win is
  threshold-independent (separability improves regardless of operating point), but
  the consolidation/match thresholds should be recalibrated for ERes2Net's cosine
  geometry on labeled cross-call audio. Tooling:
  `scripts/calibrate_eres2net_thresholds.py`, `scripts/run_zoom_eval.sh`.
- **Distribution.** The model is staged/bundled locally. Shipping to users needs a
  download path (HF mirror) like the diarizer models, or committing the artifact.
- Switching models in Settings requires an app restart (the embedder + DB path are
  bound when `MeetingSessionController` is constructed).
```
