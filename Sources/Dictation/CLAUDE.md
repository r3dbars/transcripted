# Dictation persistence

## What this directory does

`Sources/Dictation/` owns the on-disk markdown artifacts written after a dictation completes. It does not handle audio capture or STT itself; that stays in `DraftSessionController` and `Speech/`.

## Files

- `DictationStoragePaths.swift` — Draft-named storage root for dictation artifacts
- `DictationTranscriptWriter.swift` — groups completed dictations into one markdown file per day

## Flow

1. `Sources/UI/DraftSessionController.swift` transcribes audio with `STTRouter`.
2. The session tries to paste the text back into the target app.
3. The session records whether delivery was `pasted`, `copied`, or `failed`.
4. `DictationTranscriptWriter.save(...)` appends a new section to that day's markdown file.

## Storage

- root: `~/Library/Application Support/Draft/dictations/`
- transcript folder: `~/Library/Application Support/Draft/dictations/transcripts/`
- file shape: one `Dictations_YYYY-MM-DD.md` file per day, with multiple timestamped sections

Each section captures:

- a generated title
- source app name and bundle id
- delivery outcome
- timestamp
- word count and character count
- final dictated text

## Test coverage

- `Tests/DictationTranscriptWriterTests.swift`

## Agent notes

- If you change the markdown layout, update the tests.
- Dictation artifacts are append-only by day; do not assume one file per session.
- This directory is about persistence only. Recording lifecycle changes belong in `Sources/UI/DraftSessionController.swift` and `Sources/Speech/`.
