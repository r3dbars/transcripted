# Dictation persistence

## What this directory does

`Sources/Dictation/` owns the small persistence helpers behind completed dictation sessions. It does not handle audio capture or STT itself; that stays in `DictationSessionController` and `Speech/`.

## Module

`Dictation` in `.agents/modules.json`.

- **Owns:** saving finished dictations to the day files, the stop checkpoint and stopped-audio recovery, stop and finalize policies, the session cap clock, dictation storage paths.
- **Public surface:** `DictationTranscriptStore`, `DictationTranscriptWriter`, `DictationTranscriptPersistenceResult`, `SavedDictation*`, `DictationStoppedAudioRecovery*`, `DictationStopFinalizationPolicy`, `DictationStoragePaths`.
- **May depend on:** Speech, Support, Observability, Core `core-vocab`.
- **Grandfathered crossing:** `DictationSessionCapTimer.swift` names `DictationSessionCapWarningPolicy` from `UI/Overlay`; moving that policy file here fixes it after #1946.
- **Entry points:** `DictationTranscriptStore.save(...)`, `DictationStopCheckpoint`.
- **Tests:** `bash run-tests.sh --filter Dictation`.
- **Rules:** writes go through `DictationTranscriptMutationLock`; nothing here records audio or runs STT.

## Files

- `DictationSessionTimeout.swift` — uptime-based timeout helper so sleep does not consume a session's remaining record window
- `DictationSessionCapTimer.swift` — the clock behind the 5-minute cap: sleep until the last 30 seconds, then tick every second so the pill counts down (telling VoiceOver once, the first time the countdown shows), and return at the cap or on cancel. `DictationSessionController.installSessionTimeout` runs it on the real uptime clock and then finalizes the take; `Tests/DictationSessionCapTimerTests.swift` runs it on a fake clock
- `DictationStoppedAudioRecovery.swift` — writes a private recovery WAV plus metadata immediately after recording stops and keeps both until the transcript saves, the take is discarded (Esc, no speech, or a short failed take), or the next launch's `purgeLeftovers(createdBefore:)` deletes what an earlier run left (`retire(_:afterSaving:)` is the one rule for a finished take: delete the WAV only when its transcript saved)
- `DictationStoppedAudioCheckpointSignal.swift` — marks checkpoint completion, with bounded cancellation-aware waits for Quit and retry admission; completion alone does not prove persistence
- `DictationStopCheckpoint.swift` — the first stage of stopping a dictation: stop the mic, play the stop click, then write the private recovery WAV off the main actor before anything waits on the model, re-checking the session after each step. `DictationSessionController` runs it with the real router, sound and store; `Tests/DictationStopCheckpointTests.swift` runs it with fakes
- `DictationPostStopModelWait.swift` — the second stage of stopping: after the checkpoint, wait for the voice model if it isn't loaded (kick a load nobody started, join one in flight, give up on a failed load right away, stop at the budget). Unlike the start path's wait it never retries a failed load, because the audio is already saved. Clock and router are injected; `Tests/DictationPostStopModelWaitTests.swift` runs it on a fake clock
- `DictationEmptyTranscriptPolicy.swift` — what a take with no text does, first match wins: a mis-tap closes like a cancel; no speech shows the note and drops the audio; a wrong-language guess with held-back text offers Paste Anyway; a saved recording from a take of 30 s or more (`DictationFailedTakePolicy`) is offered through Transcribe It, and a shorter one is dropped with the error; unsaved audio that needs recovery offers the checkpoint retry; anything else just says why
- `DictationTerminationAdmissionPolicy.swift` — prevents Quit, new capture, or consuming inference from discarding the only native recording when no durable WAV exists; fences same-session Retry Saving
- `DictationStoragePaths.swift` — capture-library-backed storage root for dictation artifacts
- `DictationTranscriptWriter.swift` — groups completed dictations into one markdown file per day; serializes day-file writes through `DictationTranscriptMutationLock`
- `DictationTranscriptStore.swift` — shared seam for saving dictation markdown and reading the newest saved dictation back out
- `DictationTranscriptPersistence.swift` — `DictationTranscriptPersistenceResult` (times the writer itself and carries the plain-words save-failure message), the session-publish guard (`DictationSessionCompletionPolicy`), and the cap-completion delivery/failure telemetry snapshot
- `DictationStopFinalizationPolicy.swift` — chooses whether the Markdown save runs before or after the optional Auto Enter keystroke; the default is `saveBeforeAutoEnter`
- `DictationStopBenchmarkRunner.swift` — env-gated in-app benchmark for stop-to-text, stop-to-saved, and stop-to-delivery timing on synthetic audio fixtures; its `production` variant also measures the real snapshot/resample and durable recovery-checkpoint path without touching the real clipboard or focused app

## Flow

1. `DictationSessionController` (stop path in `Sources/UI/Overlay/DictationSessionController+Stop.swift`) transcribes audio with `STTRouter`.
2. The session tries to paste the text back into the target app (`DictationSessionController+PasteBack.swift`).
3. The session records whether delivery was `pasted`, `copied`, or `failed`.
4. `DictationStopFinalizationPolicy.order` decides whether the session saves before or after the optional Auto Enter keystroke. The current default starts the save before Auto Enter, then awaits the save result.
5. `DictationTranscriptStore.save(...)` appends a new section to that day's markdown file, with mutations serialized through `DictationTranscriptMutationLock`.

## Storage

- default capture library: `~/Library/Application Support/Transcripted/captures/`
- root: `<capture-library>/dictations/`
- transcript folder: same as the dictation root
- file shape: one `Dictations_YYYY-MM-DD.md` file per day, with multiple timestamped sections
- stopped-audio recovery: `~/Library/Application Support/Transcripted/state/dictation-audio-recovery/`

Stopped-audio recovery is intentionally bounded and local. A saved recording is
only offered while its own take's message is on screen, never later: a failed
dictation is usually quicker to say again than to recover. When a take of 30 s
or more (`DictationFailedTakePolicy`) comes back empty after its WAV was
written (empty text over real audio, or a model failure), the message offers
Transcribe It, which sends the WAV through the normal local imported-audio
pipeline (the same as Capture -> Transcribe Audio File), so the transcript
lands in Meetings; the importer deletes the WAV once that transcript is saved.
A shorter take's WAV is deleted with the error, unless the model never
consumed the take and its audio is still in memory (deleting the WAV then
would block the next take and Quit; launch removes it instead). A model that
never loaded after the stop always offers Transcribe It, whatever the length,
because the wait told the user their recording was safe. Launch never asks
about saved audio: `AppLaunchSteps` runs
`DictationStoppedAudioRecoveryStore.purgeLeftovers(createdBefore:)` with the
launch time, deleting every `dictation_*` WAV and metadata file from an earlier
run (an ignored Transcribe It, a Quit, or a crash), and keeping anything newer.
It is skipped when `TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD=1`, since a
second copy on the same container could delete a file the first copy is
offering.

Empty ASR output is not automatically silence: after a focused retry, captured
audio with measurable speech-like activity is reported as
`audio_needs_recovery` ("Didn't catch that. Try again.", or Transcribe It for a
long take) rather than "No speech heard". This signal heuristic does not
certify that spoken words were present. Truly quiet or too-short audio keeps
the normal no-speech/explicit-discard flow. Repeated Stop requests for the
same session are fenced before the loading/recording stop decision, so a second
request cannot cancel or overwrite the first durable checkpoint.

If checkpoint conversion or writing fails while native audio remains, inference
and new capture must not consume or overwrite that only copy. `Retry Saving`
re-enters the existing stop/checkpoint flow for the same session without starting
the microphone or automatically pasting. Quit waits for normal finalization, then
uses a bounded checkpoint wait; an unsafe Quit is declined visibly. The WAV Quit
keeps is removed by the next launch's cleanup. This does
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
- `Tests/DictationSessionCapTimerTests.swift`
- `Tests/DictationStoppedAudioRecoveryTests.swift`
- `Tests/DictationStopCheckpointTests.swift`
- `Tests/DictationEmptyTranscriptPolicyTests.swift`
- `Tests/DictationPostStopModelWaitTests.swift`
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
- This directory owns dictation persistence plus the newest-saved-dictation lookup seam. Recording lifecycle changes still belong in `Sources/UI/Overlay/DictationSessionController.swift` (start in `+RecordingStart.swift`, stop in `+Stop.swift`, saving in `+Persistence.swift`) and `Sources/Speech/`.
