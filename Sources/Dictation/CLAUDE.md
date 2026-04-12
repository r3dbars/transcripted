# Dictation persistence

## What this directory does

`Sources/Dictation/` owns the small persistence helpers behind completed dictation sessions. It does not handle audio capture or STT itself; that stays in `DictationSessionController` and `Speech/`.

## Files

- `DictationAgentOutput.swift` — Codable models + helper for a JSON day-sidecar format retained in the repo; the current app session flow writes markdown only
- `DictationSessionTimeout.swift` — uptime-based timeout helper so sleep does not consume a session's remaining record window
- `DictationStoragePaths.swift` — capture-library-backed storage root for dictation artifacts
- `DictationTranscriptWriter.swift` — groups completed dictations into one markdown file per day

## Flow

1. `Sources/UI/DictationSessionController.swift` transcribes audio with `STTRouter`.
2. The session tries to paste the text back into the target app.
3. The session records whether delivery was `pasted`, `copied`, or `failed`.
4. `DictationTranscriptWriter.save(...)` appends a new section to that day's markdown file.

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

- `Tests/DictationAgentOutputTests.swift`
- `Tests/DictationSessionTimeoutTests.swift`
- `Tests/DictationTranscriptWriterTests.swift`

## Agent notes

- If you change the markdown layout, update the tests.
- Dictation artifacts are append-only by day; do not assume one file per session.
- `DictationAgentOutput.swift` is currently a retained helper, not part of the live dictation save path. If you wire it back in, update docs and tests in the same change.
- This directory is about persistence and timing helpers only. Recording lifecycle changes belong in `Sources/UI/DictationSessionController.swift` and `Sources/Speech/`.
