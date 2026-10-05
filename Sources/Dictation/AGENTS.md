# Dictation persistence

## What this directory does

`Sources/Dictation/` owns the small persistence helpers behind completed dictation sessions. It does not handle audio capture or STT itself; that stays in `DictationSessionController` and `Speech/`.

## Module

`Dictation` in `.agents/modules.json`.

- **Owns:** saving finished dictations to the day files, the stop checkpoint and stopped-audio recovery, stop and finalize policies, the session cap clock, dictation storage paths.
- **Public surface:** `DictationTranscriptStore`, `DictationTranscriptWriter`, `DictationTranscriptPersistenceResult`, `SavedDictation*`, `DictationStoppedAudioRecovery*`, `DictationAudioArchive`, `DictationStopFinalizationPolicy`, `DictationStoragePaths`.
- **May depend on:** Speech, Support, Observability, Core `core-vocab`.
- **Grandfathered crossing:** `DictationSessionCapTimer.swift` names `DictationSessionCapWarningPolicy` from `UI/Overlay`; moving that policy file here fixes it after #1946.
- **Entry points:** `DictationTranscriptStore.save(...)`, `DictationStopCheckpoint`.
- **Tests:** `bash run-tests.sh --filter Dictation`.
- **Rules:** writes go through `DictationTranscriptMutationLock`; nothing here records audio or runs STT.

## Files

- `DictationSessionTimeout.swift` — uptime-based timeout helper so sleep does not consume a session's remaining record window
- `DictationSessionCapTimer.swift` — the clock behind the 15-minute cap: sleep until the last 30 seconds, then tick every second so the pill counts down (telling VoiceOver once, the first time the countdown shows), and return at the cap or on cancel. `DictationSessionController.installSessionTimeout` runs it on the real uptime clock and then finalizes the take; `Tests/DictationSessionCapTimerTests.swift` runs it on a fake clock
- `DictationStoppedAudioRecovery.swift` — writes a private recovery WAV plus restart-discovery metadata immediately after recording stops and retains both until transcript persistence succeeds or the user explicitly discards the session. `saveTranscriptAndRetire` is the one rule for a finished take, shared by the async and synchronous saves: decide whether audio is kept (Settings → Storage → Keep dictation audio), save the transcript with its `Audio:` path when kept, then `retire(_:afterSaving:keptAudioRelativePath:)` moves the WAV into the archive (or deletes it when not kept). A failed save always leaves the WAV in recovery
- `DictationAudioArchive.swift` — kept dictation audio in `<capture-library>/dictations/audio/<uuid>.m4a|.wav`: `keep` moves a saved take's recovery WAV in and drops its recovery metadata, `compress` turns it into an M4A in the background (the WAV is deleted only after a checked M4A is in place), `resolveURL` maps a day file's relative `Audio:` path to the M4A, else the WAV, else nil, `prune` deletes files older than the keep window, and `deleteKeptAudio(for:)` removes a deleted entry's audio once Home's undo window closes (the store's delete functions leave audio alone so the storage smokes compile them without the archive). Everything checks names and refuses symlinks and paths outside the audio folder
- `DictationStoppedAudioCheckpointSignal.swift` — marks checkpoint completion, with bounded cancellation-aware waits for Quit and retry admission; completion alone does not prove persistence
- `DictationStopCheckpoint.swift` — the first stage of stopping a dictation: stop the mic, play the stop click, then write the private recovery WAV off the main actor before anything waits on the model, re-checking the session after each step. `DictationSessionController` runs it with the real router, sound and store; `Tests/DictationStopCheckpointTests.swift` runs it with fakes
- `DictationPostStopModelWait.swift` — the second stage of stopping: after the checkpoint, wait for the voice model if it isn't loaded (kick a load nobody started, join one in flight, give up on a failed load right away, stop at the budget). Unlike the start path's wait it never retries a failed load, because the audio is already saved. Clock and router are injected; `Tests/DictationPostStopModelWaitTests.swift` runs it on a fake clock
- `DictationEmptyTranscriptPolicy.swift` — what a take with no text does, first match wins: a mis-tap closes like a cancel; no speech shows the note and drops the audio; a wrong-language guess with held-back text offers Paste Anyway; a saved recording is offered again (audio the model heard nothing in keeps its launch reminder); unsaved audio that needs recovery offers the checkpoint retry; anything else just says why
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
6. The checkpoint WAV is retired: kept in `dictations/audio/` (default, 30 days) or deleted, per the Keep dictation audio setting. Pruning runs at launch and when the setting changes.

## Storage

- default capture library: `~/Library/Application Support/Transcripted/captures/`
- root: `<capture-library>/dictations/`
- transcript folder: same as the dictation root
- file shape: one `Dictations_YYYY-MM-DD.md` file per day, with multiple timestamped sections
- stopped-audio recovery: `~/Library/Application Support/Transcripted/state/dictation-audio-recovery/`
- kept audio: `<capture-library>/dictations/audio/<uuid>.m4a` (or `.wav` before compression); the entry's `Audio:` line holds the relative path. It may have aged out, so callers resolve through `DictationAudioArchive.resolveURL` and treat nil as normal

Stopped-audio recovery is intentionally bounded and local. Launch scans at most
one pending metadata record for presentation, then `Show Audio` reveals the WAV
in Finder. The operational recovery path is Transcripted's Capture menu ->
Transcribe Audio File -> select that WAV; this uses the normal local imported-audio transcription pipeline. Reveal or
restart never deletes the checkpoint. Closing a "Transcribe It" message (the launch
reminder, or the one shown when a take's transcription came back empty) with X
or Esc, not a timeout or a newer message, sets `dismissed` in its metadata: the launch reminder skips it
(`pendingRecoveries(excludingDismissed: true)`), but the WAV stays and importers
still find it. This stops an empty take from nagging on every launch.

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
- the kept audio's relative path (`Audio:`), when audio is kept
- final dictated text

## Test coverage

- `Tests/DictationAudioArchiveTests.swift`
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
