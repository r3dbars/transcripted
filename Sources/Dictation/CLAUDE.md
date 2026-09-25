# Dictation persistence

## What this directory does

`Sources/Dictation/` owns the small persistence helpers behind completed dictation sessions. It does not handle audio capture or STT itself; that stays in `DictationSessionController` and `Speech/`.

## Files

- `DictationSessionTimeout.swift` — uptime-based timeout helper so sleep does not consume a session's remaining record window
- `DictationStoppedAudioRecovery.swift` — writes a private recovery WAV plus restart-discovery metadata immediately after recording stops and retains both until transcript persistence succeeds or the user explicitly discards the session
- `DictationStoppedAudioCheckpointSignal.swift` — marks checkpoint completion, with bounded cancellation-aware waits for Quit and retry admission; completion alone does not prove persistence
- `DictationTerminationAdmissionPolicy.swift` — prevents Quit, new capture, or consuming inference from discarding the only native recording when no durable WAV exists; fences same-session Retry Saving
- `DictationStoragePaths.swift` — capture-library-backed storage root for dictation artifacts
- `DictationTranscriptWriter.swift` — groups completed dictations into one markdown file per day; serializes day-file writes through `DictationTranscriptMutationLock`
- `DictationTranscriptStore.swift` — shared seam for saving dictation markdown and reading the newest saved dictation back out
- `DictationTranscriptPersistence.swift` — `DictationTranscriptPersistenceResult` (times the writer itself and carries the plain-words save-failure message), the session-publish guard (`DictationSessionCompletionPolicy`), and the cap-completion delivery/failure telemetry snapshot
- `DictationStopFinalizationPolicy.swift` — chooses whether the Markdown save runs before or after the optional Auto Enter keystroke; the default is `saveBeforeAutoEnter`
- `DictationStopBenchmarkRunner.swift` — env-gated in-app benchmark for stop-to-text, stop-to-saved, and stop-to-delivery timing on synthetic audio fixtures; its `production` variant also measures the real snapshot/resample and durable recovery-checkpoint path without touching the real clipboard or focused app

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
- stopped-audio recovery: `~/Library/Application Support/Transcripted/state/dictation-audio-recovery/`

Stopped-audio recovery is intentionally bounded and local. Launch scans at most
one pending metadata record for presentation, then `Show Audio` reveals the WAV
in Finder. The operational recovery path is Transcripted's Capture menu ->
Transcribe Audio File -> select that WAV; this uses the normal local imported-audio transcription pipeline. Reveal or
restart never deletes a checkpoint that may hold speech. The one exception is a
recording with no speech in it: the first launch scan deletes leftovers from
earlier runs that `FailedRecordingSignalProbe.mayContainSpeech(url:)` rules out,
and closing a "Transcribe It" message without pressing it (X, Esc, or a newer
message) deletes that recording if it has no speech. Transcribing those could
only fail with "no audio", and asking about them on every launch was a nag.
The check answers "may contain speech" whenever it can't read the whole file.

Empty ASR output is not automatically silence: after a focused retry, captured
audio with measurable speech-like activity remains checkpointed and offers an
immediate `Show Audio`/Capture -> Transcribe Audio File recovery path. This signal heuristic
does not certify that spoken words were present. Truly quiet or too-short audio
keeps the normal no-speech/explicit-discard flow. Repeated Stop requests for the
same session are fenced before the loading/recording stop decision, so a second
request cannot cancel or overwrite the first durable checkpoint.

If checkpoint conversion or writing fails while native audio remains, inference
and new capture must not consume or overwrite that only copy. `Retry Saving`
re-enters the existing stop/checkpoint flow for the same session without starting
the microphone or automatically pasting. Quit waits for normal finalization, then
uses a bounded checkpoint wait; an unsafe Quit is declined visibly. This does
not recover a permanently blocked native audio driver or protect RAM from force
quit, crashes, power loss, or explicit recording discard.

Each section captures:

- a generated title
- source app name and bundle id
- delivery outcome
- timestamp
- word count and character count
- final dictated text

## Test coverage

- `Tests/DictationSessionTimeoutTests.swift`
- `Tests/DictationStoppedAudioRecoveryTests.swift`
- `Tests/DictationStoppedAudioInterleavingTests.swift`
- `Tests/DictationTerminationCheckpointTests.swift`
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
