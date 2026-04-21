# Dictation persistence

## What this directory does

`Sources/Dictation/` owns the small persistence helpers behind completed dictation sessions. It does not handle audio capture or STT itself; that stays in `DictationSessionController` and `Speech/`.

## Files

- `DictationSessionTimeout.swift` — uptime-based timeout helper so sleep does not consume a session's remaining record window
- `DictationStoragePaths.swift` — capture-library-backed storage root for dictation artifacts
- `DictationTranscriptWriter.swift` — groups completed dictations into one markdown file per day
- `DictationTranscriptStore.swift` — shared seam for saving dictation markdown and reading the newest saved dictation back out

## Flow

1. `Sources/UI/Overlay/DictationSessionController.swift` transcribes audio with `STTRouter`.
2. The session tries to paste the text back into the target app.
3. The session records whether delivery was `pasted`, `copied`, or `failed`.
4. `DictationTranscriptStore.save(...)` appends a new section to that day's markdown file.

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

## Agent notes

- If you change the markdown layout, update the tests.
- Dictation artifacts are append-only by day; do not assume one file per session.
- This directory owns dictation persistence plus the newest-saved-dictation lookup seam. Recording lifecycle changes still belong in `Sources/UI/Overlay/DictationSessionController.swift` and `Sources/Speech/`.
