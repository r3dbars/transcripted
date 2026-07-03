# Dictation persistence

## What this directory does

`Sources/Dictation/` owns the small persistence helpers behind completed dictation sessions. It does not handle audio capture or STT itself; that stays in `DictationSessionController` and `Speech/`.

## Files

- `DictationSessionTimeout.swift` — uptime-based timeout helper so sleep does not consume a session's remaining record window
- `DictationStoragePaths.swift` — capture-library-backed storage root for dictation artifacts
- `DictationTranscriptWriter.swift` — groups completed dictations into one markdown file per day; serializes day-file writes through `DictationTranscriptMutationLock`
- `DictationTranscriptStore.swift` — shared seam for saving dictation markdown and reading the newest saved dictation back out
- `DictationStopFinalizationPolicy.swift` — chooses whether the Markdown save runs before or after the optional Auto Enter keystroke; the default is `saveBeforeAutoEnter`
- `DictationStopBenchmarkRunner.swift` — env-gated in-app benchmark for stop-to-text, stop-to-saved, and stop-to-delivery timing on synthetic audio fixtures; it does not touch the real clipboard or focused app

## Flow

1. `Sources/UI/Overlay/DictationSessionController.swift` transcribes audio with `STTRouter`.
2. The session tries to paste the text back into the target app.
3. The session records whether delivery was `pasted`, `copied`, or `failed`.
4. `DictationStopFinalizationPolicy.order` decides whether the session saves before or after the optional Auto Enter keystroke. The current default starts the save before Auto Enter, then awaits the save result.
5. `DictationTranscriptStore.save(...)` appends a new section to that day's markdown file, with mutations serialized through `DictationTranscriptMutationLock`.

## Storage

- default capture library: `~/Library/Application Support/Transcripted/captures/`
- root: `<capture-library>/dictations/`
- transcript folder: same as the dictation root
- file shape: one `Dictations_YYYY-MM-DD.md` file per day, with multiple timestamped sections

Each section captures:

- a generated title
- source app name and bundle id
- delivery outcome
- timestamp
- word count and character count
- final dictated text

## Test coverage

- `Tests/DictationSessionTimeoutTests.swift`
- `Tests/DictationTranscriptStoreTests.swift`
- `Tests/DictationTranscriptWriterTests.swift`

## Verification

```bash
bash build.sh --no-open
bash run-tests.sh
```

## Agent notes

- If you change the markdown layout, update the tests. The `Dictations_YYYY-MM-DD.md` day-file format is also parsed by the standalone tools through `Tools/TranscriptedCaptureKit` — update its parser and tests in the same change.
- The day-file format (frontmatter keys including `format_version`, section grammar, metadata lines) is specified in `docs/capture-format.md`. Keep that spec in sync, and keep new frontmatter keys flat.
- Dictation artifacts are append-only by day; do not assume one file per session.
- This directory owns dictation persistence plus the newest-saved-dictation lookup seam. Recording lifecycle changes still belong in `Sources/UI/Overlay/DictationSessionController.swift` and `Sources/Speech/`.
