# Dictation persistence

`Sources/Dictation/` owns what happens to a dictation once recording stops: the recovery WAV, the Markdown day files, kept audio, Transcribe again, and the stop/finalize policies. It does no audio capture and no STT of its own. Capture and the STT call live in `Sources/Speech/AGENTS.md`; the session lifecycle (start, stop, paste-back, persistence calls) is `DictationSessionController` and its `+*.swift` extensions in `Sources/UI/Overlay/`.

## Module

`Dictation` in `.agents/modules.json`.

- **Public surface:** `DictationTranscriptStore`, `DictationTranscriptWriter`, `DictationTranscriptPersistenceResult`, `SavedDictation*`, `DictationStoppedAudioRecovery*`, `DictationAudioArchive`, `DictationEntryTextRewrite`, `DictationRetranscription`, `DictationStopFinalizationPolicy`, `DictationStoragePaths`.
- **May depend on:** Speech, Support, Observability, Core `core-vocab`.
- **Cap warning:** `DictationSessionCapTimer` and `DictationSessionCapWarningPolicy` own the final-30-second countdown; the overlay consumes the policy.
- **Entry points:** `DictationTranscriptStore.save(...)`, `DictationStopCheckpoint`.
- **Tests:** `bash run-tests.sh --filter Dictation`.

## Rules

- Day-file writes go through `DictationTranscriptMutationLock`. Day files are append-only by day; never assume one file per session.
- Nothing here records audio. The only STT call is Transcribe again's injected transcriber over a saved file.
- **The only copy of a take must survive.** If checkpoint conversion or writing fails while native audio remains, inference and new capture must not consume or overwrite it. `Retry Saving` re-enters the stop/checkpoint flow for the same session without starting the mic or pasting. Repeated Stop requests are fenced before the loading/recording stop decision, so a second one can't cancel or overwrite the first checkpoint. Quit waits for normal finalization, then a bounded checkpoint wait; an unsafe Quit is declined visibly. This does not protect RAM from force quit, crashes, or power loss, or recover a blocked native audio driver.
- **A failed save always leaves the WAV in recovery.** `saveTranscriptAndRetire` is the one rule for a finished take.
- **Text success is not audio success.** A checkpoint records requested retention before inference. Before Markdown commits its `Audio:` line, an owner-only receipt identifies the original library and audio path; only a second synced marker after successful text save authorizes generic audio repair or retention deletion. Failed archival leaves that WAV protected from the short-take purge and returns `pendingAudioRetention`; the overlay offers **Retry Saving Audio**. Retry archives audio only, never appends the transcript again. A write-ahead receipt failure refuses text commit. A failed text save, or interruption before the committed-text marker, keeps the original recovery WAV and manual-recovery identity; launch, Off and expiry must not convert or erase an uncommitted take. If text succeeded but its marker failed, the in-process result proves that exact take and allows its Retry Saving Audio action to establish the marker without resaving words. After restart that proof is unavailable, so the crash-gap recovery remains conservative rather than guessing commitment from a UUID. File and directory synchronization precede destructive audio handoff; this is not a claim of hardware power-loss certification.
- Pending-audio warnings never replace Copy/Paste recovery controls or the cap's Paste It action. A successful paste can offer Retry Saving Audio; other delivery notices explain that the audio is safe locally but needs repair, without promising restart promotion when a commit marker is unavailable. One storage-mutation owner serializes publication, deletion and pruning (not the stop checkpoint's own fresh files, which paste waits on); production save/retry reads the current retention preference under that owner, so a queued old Forever value cannot undo Off. Escape detaches only its captured checkpoint cleanup instead of blocking the main actor on a slow archive.
- **Pending-receipt relocation limitation:** a receipt targets the original library and never silently falls back to a new root. Moving the capture library while archival is pending does not migrate that receipt; the moved entry may not resolve or erase its pending checkpoint by its new location. Off/expiry still erases it globally, and original-target retry remains available. Do not loosen this to UUID-only deletion; a future verified library-move transaction must migrate receipts too.
- **Empty ASR output is not silence.** After a focused retry, audio with measurable speech-like activity is `audio_needs_recovery` ("Didn't catch that. Try again.", or Transcribe It for a long take), not "No speech heard". The signal heuristic doesn't prove words were spoken. Quiet or too-short audio keeps the no-speech flow.
- Changing the Markdown layout means updating the tests, the parser in `Tools/TranscriptedCaptureKit` (standalone tools read these files), and the spec in `docs/capture-format.md`. Keep new frontmatter keys flat.

## Flow

1. `DictationSessionController` (stop path in `DictationSessionController+Stop.swift`) runs `DictationStopCheckpoint`: stop the mic, play the stop click, write the private recovery WAV off the main actor. Then `DictationPostStopModelWait` if the model isn't loaded.
2. `STTRouter` transcribes. The session pastes back (`+PasteBack.swift`) and records delivery as `pasted`, `copied`, or `failed`.
3. `DictationStopFinalizer` always starts the save before the Auto Enter keystroke, then awaits it. `DictationStopFinalizationPolicy.order` and `saveAfterAutoEnter` exist only for the stop benchmark, the Lab and `dictation-stop-autoeval.sh`; the app never saves after Auto Enter.
4. `DictationTranscriptStore.save(...)` appends a section to that day's file.
5. The WAV is retired: kept in `dictations/audio/` or deleted, per Settings -> Storage -> Keep dictation audio (default 30 days; Off, 7 days, 30 days, Forever). A failed requested archive stays in recovery. `DictationAudioArchive.prune` runs at launch and when the setting changes; it first repairs committed-text pending archives or removes those when Off/expired. Uncommitted takes remain original transcription recoveries, erased only by their explicit discard policy, not saved-audio maintenance. A committed pending entry plays from its verified private checkpoint until repair. Deleting that entry after Undo's window erases its pending audio too, so retry cannot resurrect it.

## Storage

- Capture library default: `~/Library/Application Support/Transcripted/captures/`. Dictation root: `<capture-library>/dictations/`, one `Dictations_YYYY-MM-DD.md` per day, many timestamped sections.
- Each section has: generated title, source app name and bundle id, delivery outcome, timestamp, word and character counts, the `Audio:` relative path when audio is kept, and the text.
- Kept audio: `<capture-library>/dictations/audio/<uuid>.m4a` (`.wav` until compressed). It may have aged out, so resolve through `DictationAudioArchive.resolveURL` and treat nil as normal.
- Stopped-audio recovery: `~/Library/Application Support/Transcripted/state/dictation-audio-recovery/`.

## Recovery behavior

A saved recording is offered only while its own take's message is on screen, never later; a failed dictation is usually quicker to say again. `DictationEmptyTranscriptPolicy` decides what an empty take does, first match wins: a mis-tap closes like a cancel; no speech shows the note and drops the audio; a wrong-language guess with held-back text offers Paste Anyway; a saved WAV from a take of 30 s or more (`DictationFailedTakePolicy`) offers Transcribe It; a shorter one is dropped with the error; unsaved audio needing recovery offers the checkpoint retry; anything else says why.

- Transcribe It sends the WAV through the imported-audio pipeline (same as Capture -> Transcribe Audio File); the transcript lands in Meetings and the importer deletes the WAV once it's saved.
- A short take's WAV is deleted with the error, unless the model never consumed the take and the audio is still in memory. Deleting the WAV then would block the next take and Quit, so launch removes it instead.
- A model that never loaded after the stop always offers Transcribe It, whatever the length, because the wait told the user their recording was safe.
- Launch never asks about failed-take audio. `AppLaunchSteps` calls `DictationSessionController.purgeLeftoverStoppedAudio`, which runs `DictationStoppedAudioRecoveryStore.purgeLeftovers(createdBefore:)` with the launch time. From earlier runs it deletes unclaimed `dictation_*` WAVs under 30 s with their metadata. Checkpoints carrying requested-retention ownership or an archive intent are never deleted by this short-take rule, even when text saving also failed. Storage maintenance honors the current audio retention window only for committed-text receipts; uncommitted recoveries stay at their original URL. A non-owned WAV of 30 s or more, or one whose length can't be read, stays quietly for Capture -> Transcribe Audio File. Anything newer than launch is kept. It's skipped when `TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD=1`, since a second copy could delete a file the first is offering.

## Files

- `DictationStopCheckpoint.swift`: first stop stage. Re-checks the session after each step. Fast-tested with fakes in `Tests/DictationStopCheckpointTests.swift`.
- `DictationStoppedAudioCheckpointSignal.swift`: marks checkpoint completion, with bounded cancellation-aware waits for Quit and retry admission. Completion alone doesn't prove persistence.
- `DictationPostStopModelWait.swift`: second stop stage. Kicks a load nobody started, joins one in flight, gives up on a failed load at once, stops at the budget. Unlike the start path it never retries a failed load, because the audio is already saved. Clock and router are injected.
- `DictationStoppedAudioRecovery.swift`: private recovery WAV plus metadata, requested-retention ownership, original-library archive receipts, audio-only retry and verified pending playback/deletion. Also `saveTranscriptAndRetire`, `retire(_:afterSaving:keptAudioRelativePath:)`, and the unclaimed short-take `purgeLeftovers`.
- `DictationAudioArchive.swift`: `keep` stages, compares and synchronizes a copy before retiring its checkpoint; a same-named different file is never replaced. `compress` makes the M4A in the background and deletes the WAV only after a checked M4A is in place; `resolveURL` maps `Audio:` to M4A, else WAV, else a matching pending receipt when a recovery directory is supplied. `prune` maintains pending retention then deletes archived files past the window. `deleteKeptAudio(for:)` erases pending and archived audio once Home's undo window closes. Everything checks names and refuses symlinks and unrelated paths.
- `DictationEntryTextRewrite.swift`: `replaceEntryText(entryID:in:with:createdAt:)` rewrites one entry under the lock. Only the heading title, `Words:`, `Characters:`, and the body change; everything else stays byte for byte. An unknown ID or empty text throws and leaves the file alone.
- `DictationRetranscription.swift`: Transcribe again. Decodes a kept take with `AVAudioFile` + `AVAudioConverter` to 16 kHz mono, hands samples to an injected transcriber (the Dictations page passes `STTRouter.transcribeSegment`), applies the live-take filler cleanup, then `replaceEntryText`. File-based only: no `AVAudioEngine` or input node, so AirPods are never opened. No words keeps the old text.
- `DictationEmptyTranscriptPolicy.swift`: the empty-take rules above, plus `DictationFailedTakePolicy`.
- `DictationTerminationAdmissionPolicy.swift`: stops Quit, new capture, or inference from discarding the only native recording when no durable WAV exists; fences same-session Retry Saving.
- `DictationSessionCapTimer.swift`: the 15-minute cap clock (`TranscriptedConstants.dictationSessionMaxDuration`). Sleeps to the last 30 s, then ticks each second so the pill counts down (VoiceOver is told once), returns at the cap or on cancel. `DictationSessionController+SessionCap.swift` runs it on the real uptime clock; `Tests/DictationSessionCapTimerTests.swift` uses a fake one.
- `DictationSessionTimeout.swift`: uptime-based timeout so sleep doesn't consume a session's record window.
- `DictationStoragePaths.swift`: capture-library-backed root for dictation artifacts.
- `DictationTranscriptWriter.swift`: one Markdown file per day; serializes writes through the lock.
- `DictationTranscriptStore.swift`: the seam for saving and for reading the newest saved dictation back.
- `DictationTranscriptPersistence.swift`: `DictationTranscriptPersistenceResult` (times the writer, carries the plain-words failure message), the session-publish guard `DictationSessionCompletionPolicy`, and the cap-completion telemetry snapshot.
- `DictationStopFinalizationPolicy.swift`: save-before-Auto-Enter finalization, plus the benchmark-only order setting.
- `DictationStopBenchmarkRunner.swift`: env-gated in-app benchmark of stop-to-text, stop-to-saved, stop-to-delivery on synthetic audio. Its `production` variant also times the real snapshot/resample and recovery checkpoint without touching the clipboard or the focused app.

## Tests and checks

Tests are `Tests/Dictation*Tests.swift` (archive, entry rewrite, session timeout and cap timer, stopped-audio recovery and interleaving, stop checkpoint, termination checkpoint, empty-transcript policy, post-stop model wait, transcript store and writer).

```bash
bash build.sh --no-open
bash run-tests.sh --filter Dictation
```
