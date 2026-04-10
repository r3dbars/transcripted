# Local Folder

## Current State

This folder is currently documentation-only and does not contain active local-inference sources.

Earlier versions of the app used this namespace for local LLM and OCR components. That is no longer the live structure on this branch. The active local speech stack now lives under:

- `Sources/Speech/` for Parakeet STT
- `Sources/Meeting/` and `Sources/TranscriptedCore/` for meeting transcription and diarization

## Guidance

- Do not assume an `MLXEngine`, local vision extractor, or inference manager exists in this tree.
- If local non-STT inference returns, document the concrete files and initialization path here.
