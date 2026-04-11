# Dictation Persistence

## What this directory owns

`Sources/Dictation/` owns the on-disk artifacts written after a dictation
finishes. It does not own recording or live STT.

## Important files

- `DictationStoragePaths.swift` — capture-library-backed storage root for dictation exports
- `DictationTranscriptWriter.swift` — appends completed dictations into one markdown file per day
- `DictationAgentOutput.swift` — Codable day / entry models plus JSON-sidecar helpers for agent-oriented dictation output
- `DictationSessionTimeout.swift` — shared timeout helper for long-running dictation sessions

## Current storage model

Default folder:

- `~/Library/Application Support/Transcripted/captures/dictations/`

Current app behavior centers on daily markdown files written directly into that
folder:

- `Dictations_YYYY-MM-DD.md`

Each entry records:

- entry ID
- capture timestamp
- source app name and bundle ID
- delivery result (`pasted`, `copied`, or `failed`)
- word count and character count
- final dictated text

## Flow

1. `Sources/UI/DictationSessionController.swift` transcribes audio with `STTRouter`.
2. The session tries to paste the text back into the target app.
3. The session records the delivery outcome.
4. `DictationTranscriptWriter.save(...)` appends the entry to that day’s markdown file.

## Guardrails

- treat dictation artifacts as append-by-day, not one-file-per-session
- storage changes here should preserve stable markdown output for tools and agents
- recording lifecycle changes belong in `Sources/UI/DictationSessionController.swift` or `Sources/Speech/`

## Verify

```bash
bash build.sh
bash run-tests.sh
```

Relevant tests:

- `Tests/DictationTranscriptWriterTests.swift`
