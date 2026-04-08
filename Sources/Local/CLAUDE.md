# Local directory

## Current status

No Swift sources currently live in `Sources/Local/` on `main`.

Older docs in this directory described an `MLXEngine`, local OCR helpers, and a local inference manager. Those sources are not present in the current tree.

## Agent notes

- Do not assume a local LLM or OCR pipeline is available on `main` just because older markdown mentions it.
- If you need current STT behavior, read `Sources/Speech/CLAUDE.md`.
- If you need current meeting transcription behavior, read `Sources/Meeting/CLAUDE.md` and `Sources/TranscriptedCore/CLAUDE.md`.
