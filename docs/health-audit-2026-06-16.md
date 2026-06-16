# Transcripted Health Audit — 2026-06-16

Read-only audit toward "super clean." Goal: a concrete, prioritized list of everything
keeping Transcripted from being polished, grouped by severity, each with a `file:line`
and a one-line fix direction. Each item is intended to become its own fix thread.

**Audit baseline:** `origin/main` @ `ca17a0aa` (line numbers are accurate as of that commit;
later commits may have shifted a few). Method: five parallel read-only passes over
interactive controls, file/data robustness, error handling, test coverage, and loose ends,
with the load-bearing P1 claims verified directly against source.

**Headline:** the codebase is in good shape — zero `TODO/FIXME/HACK` markers, disciplined
error handling (no empty `catch {}`, every `fatalError` is unreachable `init?(coder:)`
boilerplate), and ~196 test files. The items below are the real gaps.

Counts: **2 P1 / 6 P2 / 8 P3.**

---

## P1 — User-facing broken

### P1.1 — Home's cached audio/transcript URLs go stale after background WAV→M4A recompression

"Show audio in Finder" silently no-ops and playback falsely reports "Unavailable" for a
freshly-saved meeting.

Root cause: `restyleSavedTranscriptInBackground` fires a detached
`MeetingAudioStorageManager.processSavedTranscript`
(`Sources/Meeting/MeetingSessionController.swift:1680`), which calls `compressWAVAudio` →
converts to `.m4a` and `removeItem(at: sourceURL)` deleting the `.wav`
(`Sources/Meeting/MeetingAudioStorageManager.swift`). **No `refreshRecentCaptures` is hooked
to compression completion**, so the just-saved `RecentMeetingItem` keeps URLs pointing at the
deleted `.wav`.

- `audioRevealURLs` returns the cached first URL with no existence check
  (`Sources/UI/Shared/HomeMeetingRowActionTargets.swift:13`) → Finder opens the parent folder
  with nothing selected.
- Playback loads the stale `.wav`, fails, and shows "Unavailable" + beep even though the
  `.m4a` / `playback.wav` exist (`Sources/UI/Shared/RecentCaptureScanners.swift:404` →
  `Sources/UI/Shared/MeetingAudioPlayback.swift:65`).

**Fix:** emit a "captures changed" signal at the end of `processSavedTranscript`/restyle and
`refreshRecentCaptures(force: true)` on it; add a defensive re-resolve via
`MeetingAudioArchiveResolver` + beep in `audioRevealURLs`. (One fix here also closes P2.3.)

### P1.2 — Mic device-change recovery is untested and has a data-loss failure mode

`AudioDeviceRecovery.recoverFromDeviceChange` (`Sources/TranscriptedCore/Audio/AudioDeviceRecovery.swift`,
~280 lines) closes the active mic WAV, appends a `_mic_recovery.wav` segment, and a `defer`
deletes it unless `shouldKeepRecoverySegment` is set — a bookkeeping bug silently drops part
of the recording. Only "covered" by property-propagation snapshot tests and a structural
shell-script contract (`AudioAutomationCoverageContractTests`) that by its own header
"exercises no runtime audio logic."

**Fix:** seam test driving the sample-rate-changed branch — assert prior segment finalized +
new segment appended exactly once, recovery segment removed on restart failure, and
`recoveryAttemptCount >= max` triggers `stop()` + user error.

---

## P2 — Fragile / silent failure

### P2.1 — Whisper dictation failure is mislabeled to the user as "no speech"

`STTRouter.transcribe`'s Whisper path does `catch { print(...); return nil }`
(`Sources/Speech/STTRouter.swift:174`); the caller treats `nil` identically to silence and
shows "no speech" (`Sources/UI/Overlay/DictationSessionController.swift:858,873`). Real
failures discard the user's speech with a misleading message, logged only via `print`.
**Fix:** distinguish throw from empty; surface a real error toast.

### P2.2 — SpeakerDatabase write failures logged "CRITICAL" but never surfaced; returns a stale profile

On `sqlite3_step != SQLITE_DONE` it logs then returns a populated non-optional `SpeakerProfile`
anyway (`Sources/TranscriptedCore/Speaker/SpeakerDatabase.swift:281-282,324-325`);
`transaction` continues after a failed `BEGIN EXCLUSIVE`/`COMMIT`
(`Sources/TranscriptedCore/Speaker/SpeakerDatabase.swift:198-213`). Named-speaker work is lost
on next launch with no feedback. **Fix:** make writes failable / have `transaction` throw on
BEGIN/COMMIT failure.

### P2.3 — Title rename races background compression; restyle moves the transcript out from under the cached Home item

`MeetingArtifactRenamer.renameAudioDirectoryIfNeeded`
(`Sources/Meeting/MeetingArtifactRenamer.swift:144-166`) moves `<stem>_audio/` while the
detached compression task rewrites files inside it; restyle moves `X.md`→`Y.md`
(`Sources/Meeting/MeetingSessionController.swift:1672`) but Home keeps `transcriptURL=X.md`.
Same root cause as P1.1 (no refresh). **Fix:** serialize rename vs. audio-maintenance;
refresh after restyle.

### P2.4 — Playback holds `NSSound(byReference:)` across deletion; time-based pruning doesn't stop active playback

`Sources/UI/Shared/MeetingAudioPlayback.swift:233`. The explicit delete path stops playback
(`Sources/UI/Settings/TranscriptedSettingsView.swift:1298,1326`) but retention-window pruning
does not → playback reads a deleted inode and stalls silently. **Fix:** call `stopIfActive`
from the prune path.

### P2.5 — System-audio output-change recovery give-up + reentrancy guard untested

`SystemAudioBufferWriter.recoverFromOutputChange` tears down/rebuilds the tap and, at max
attempts, silently ends capture; the `isRecovering` guard prevents a beachball; the
generation-counter stale-cleanup skip in `SystemAudioCapture.stop()` protects a live tap.
Zero behavioral coverage. **Fix:** extract the generation comparison + give-up transition
into testable helpers and assert them.

### P2.6 — Menu-bar "Start Dictation" silently no-ops if `sessionController` is nil

`guard let session = … else { return }` with no beep/log
(`Sources/UI/MenuBar/MenuBarPanelController.swift:248`), while the sibling paste path beeps on
its nil branch. Row enablement isn't gated on `sessionController != nil`. **Fix:** beep+log on
nil, or gate enablement.

---

## P3 — Cleanup

### P3.1 — Dead views: `MenuBarSettingsView` + `MenuBarShortcutsView` are never instantiated

Only referenced in docs; their closures `onOpenAgentConnect` / `onImportAudioFile` have zero
assignments repo-wide. The live menu uses `MenuBarPrimaryActionsView` /
`MenuBarUtilityActionsView`. **Fix:** delete or wire up.

### P3.2 — Dead EOU "live display" subsystem (~150 lines) gated by hardcoded `liveDisplayEnabled = false`

`Sources/Speech/ParakeetEngine.swift:44`. `StreamingEouAsrManager` is a no-op shim
(`process()` always returns `""`, `Sources/Speech/ParakeetAudioEngineSupport.swift:29`).
Documented dormant scaffolding — keep-or-cut is a product call.

### P3.3 — Entire `Sources/Speech/` module bypasses `AppLogger`

44 raw `print(...)` calls (vs 455 `AppLogger` sites elsewhere), several emitting device names
/ model paths, skipping file logging, rotation, Sentry, and redaction. **Fix:** migrate to
`AppLogger`; optionally add a grep guard in CI.

### P3.4 — "Submit feedback" ignores `NSWorkspace.shared.open`'s return

`Sources/UI/Shared/TranscriptedSupportActions.swift:8` → silent if there is no default mail
client. **Fix:** fall back to copy-address / alert on `false`.

### P3.5 — "Show Config" disabled with no tooltip

`Sources/UI/Settings/AgentConnectionSettingsPage.swift:396` is disabled with nothing
explaining why. **Fix:** add `.help("Config file not created yet")`.

### P3.6 — Permissions onboarding "System audio enabled" state still re-opens System Settings on click

`Sources/UI/Settings/PermissionsOnboardingView.swift:264`, inconsistent with the calendar row
which disables. **Fix:** make the granted state non-interactive.

### P3.7 — `MeetingAudioPlayback` player state machine untested

Unavailable-ID/beep fallback + seek/skip clamping have no test (hard to unit-test `NSSound`).
Low priority.

### P3.8 — `RecordingAudioArchiver` trusts source extension

`Sources/TranscriptedCore/Storage/RecordingAudioArchiver.swift:67` — imported `.mp3`/`.aiff`
is archived as-is and never compressed (only `.wav` is). Benign inconsistency with the
"compress to m4a" contract.

---

## Highest-leverage move

One fix — emit captures-changed → `refreshRecentCaptures(force: true)` after background
compression/restyle/rename — closes **P1.1 and P2.3** together. Pair it with the defensive
re-resolve in `audioRevealURLs` so the Finder action fails loudly instead of silently.
