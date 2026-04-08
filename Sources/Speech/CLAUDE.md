# Speech

## What This Contains

Speech-to-text integration centered on the local Parakeet pipeline.

Current Swift files: **2**

| File | Purpose |
|---|---|
| `ParakeetEngine.swift` | FluidAudio/CoreML-backed Parakeet TDT V3 transcription engine |
| `STTRouter.swift` | Thin routing layer that currently forwards to Parakeet |

## Notes
- This directory is now intentionally small.
- Route all current STT traffic through `STTRouter` instead of calling engine details from unrelated modules.
