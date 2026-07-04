# Issue #825 — "Long meetings (~2h) don't show": root-cause map and fix plan

Date: 2026-06-11. Evidence gathered by multi-agent investigation against 81ff54c1
plus targeted verification.

> **Status:** Phases 0–2 shipped via PR #1074 (merged 2026-06-11): `WAVHeaderRepair`,
> merger salvage, failed-queue heal-on-load, explicit writer `close()`, diarization
> init dedup, `MeetingRecordingJournal` + launch recovery scan. Phase 3 (section 4)
> and the open items in section 6 remain the live backlog.
>
> **2026-07-03 update:** GitHub issue #825 shows closed, but it was auto-closed by
> PR #1074's merge (2026-06-12), not by an explicit human sign-off — the owner's
> last comment on the thread (2026-05-21) said the issue would stay open for the
> larger save-as-recorded/chunked-processing follow-up. That follow-up (Phase 3
> below, and the section 6 open items) has not landed. Phase 0–2 shipped to real
> users in `v1.1.48` (2026-06-13) and has had ~3 weeks of production usage with no
> reopened "meeting disappeared" reports so far — a reasonable but informal signal,
> not a confirmed validation (no Sentry/PostHog check of stop-timeout frequency has
> been run, per the section 6 caveat, and no manual long-meeting QA pass is on
> record).
>
> Since then, three more meeting-reliability PRs merged to `main` (none yet in a
> shipped release — `v1.1.48` is still the latest tag): **#1398** "Fix meeting
> capture failure recovery" (SCK mid-recording failure detection, system-audio
> disk-write-failure handling, mic-only recovery with `system_audio_missing`
> metadata), **#1402** "Improve audio recovery and failed archive handling", and
> **#1406** "Fix audit performance hotspots" (unrelated perf work, bundled here only
> because it touches the same test suites). All three are automated-test-only —
> PR #1398 says so explicitly: "Deterministic/local proof only. No live meeting,
> hardware, or real ScreenCaptureKit failure injection was performed." A fourth PR,
> **#1404** "Preserve dictation recovery audio", is still an **open draft**, not
> merged — it addresses dictation audio recovery, not meeting long-recording
> recovery, and should not be counted as landed reliability work for this issue.
>
> None of the Phase 3 backlog below (auto-retry-once, moving merge off the stop
> path, sleep-gap insertion, Home fallback for unparseable transcripts) or the
> section 6 open items (AVAudioFile header semantics on macOS 26, merge wall-time
> on low-power machines, real-world stop-timeout frequency) appear to have shipped
> yet — `meeting_recovered_at_launch`-style auto-retry logic is not present in
> `FailedTranscriptionManager` as of this update.

## 1. Where the issue actually stands

The six gaps redpanda77 reported in the issue thread were checked adversarially
against current main. Five verdicts came back with file:line evidence:

| Claim | Verdict | Key evidence |
|---|---|---|
| C1: fixed 30s stop timeout | **fixed** | `TranscriptedConstants.meetingStopTimeout(forRecordingDuration:)` — 30s base + 30s/recorded hour, 120s cap (TranscriptedConstants.swift:59-78). 2h → 90s. Timeout never interrupts teardown; late completion repairs the failed entry via `promoteFinalizedFailedTranscriptionAudio` (TranscriptionTaskManager.swift:681-726). |
| C2: 35s termination timeout orphans audio | **fixed** | Quit wait is now 125s, deliberately above the 120s stop cap, test-guarded (TranscriptedConstantsTests.swift:46-53). Every quit branch preserves to the failed queue before `terminateLater` replies (MeetingSessionController.swift:1080-1193; TranscriptedApp.swift:294-308). |
| C3: WAV header race at stop | **unverified by agent, bounded by code** | The writer-lifetime hazard is acknowledged in MeetingCaptureSupport.swift:3-6. Consequence is bounded (retry fails cleanly, late promotion repairs), but the underlying mechanism is real — see P0-B and P1-D. |
| C4: linear-memory merge | **fixed** | d0b50c17 rewrote `MicRecordingFileMerger` to streaming 30s chunks, ~10MB peak regardless of length (MicRecordingFileMerger.swift:5-7, 62-235). Runs off-main. |
| C5: model download orphans queued jobs | **misread** | Engines dedup in-flight downloads (ParakeetEngine.swift:283-286, 361-366); `failQueuedTranscriptionJobAfterModelRecovery` is reached only on genuine load failure and writes a visible, durable, retryable entry. Real kernel: DiarizationService lacks init dedup (P1-F) and there is no auto-retry (P1-G). |
| C6: cleanup deletes audio before retry | **fixed** | `staleTemporaryAudioAge` is 6h (was 10min), mtime-based, refreshed during export (MeetingAudioStorageManager.swift:458, 1131-1144). `pruneRetainedAudio` is transcript-gated and structurally cannot see `Failed_*` audio dirs; pinned by fast test (MeetingAudioStorageManagerTests.swift:625-650). |

So the *reported* mechanisms are mostly closed. But the investigation surfaced a
different set of still-real failure modes — including the one that most plausibly
explains "meetings disappear" reports that postdate the fixes.

## 2. Remaining failure modes, ranked

### P0-A. Crash-orphaned audio: no meeting recovery scan exists (the real remaining "disappear")
The ONLY durable record of an in-flight meeting is `failed_transcriptions.json`,
written by preservation code paths (FailedTranscriptionManager.swift:40-44). A hard
crash, force-kill, kernel panic, power loss, or OOM kill at any point between
recording start and preservation leaves scratch WAVs in
`~/Library/Application Support/Transcripted/tmp/recordings/` with **no queue entry,
no Home item, no recovery scan, and no cleanup**. They sit there invisibly forever.

Long meetings maximize exposure: ~2h of wall-clock crash window, then a
post-processing phase that materializes ~0.92–1.4GB transient RAM
(`AudioResampler.loadAndResample` builds the full 16k float buffer + an equal-size
Array copy; both mic and system arrays alive simultaneously —
AudioResampler.swift:156-220, TranscriptionPipeline.swift:59-68) on top of STT +
Sortformer + optional Gemma summary. On 8–16GB machines that is a credible jetsam.

Dictation already solved this pattern — `Sources/Speech/DictationAudioRecovery.swift`
exists. Meetings have no equivalent.

### P0-B. Silent merge fallback drops everything after the first device switch
`MicRecordingFileMerger.merge` throws for ANY single empty/unreadable segment
(MicRecordingFileMerger.swift:70-71). `finalizeMicRecording` catches, logs, and
falls back to **primaryURL — the first segment only**
(AudioFileManager.swift:416-422). The meeting then transcribes "successfully": a
complete-looking transcript silently missing all audio after the first AirPods
connect / dock change. Recovery-segment WAVs are orphaned on disk.

A narrow writer-lifetime race makes this more likely: stop() drains writes on the
serial queue, but the strong `micAudioFileRef` snapshot (Audio.swift:972) can keep
the AVAudioFile alive past the close blocks; if merge opens a segment whose header
isn't finalized, it sees a zero/stale length → emptyAudioFile → whole merge fails →
silent fallback.

### P0-C. Promotion/delete ordering: failed entry can point at a deleted file
On stop-timeout, the failed entry initially points at the **pre-merge** primary mic
WAV (MeetingCaptureBridge.swift:265-271). Late merge success **deletes all original
segments** (MicRecordingFileMerger.swift:52-54), then
`refreshTimedOutFailedMeetingAudio` repoints the entry. Crash/quit between the
delete and the persisted repoint → queue entry references a deleted WAV (retry
fails) while `*_merged.wav` sits orphaned. Same shape as the C6 residual:
`cleanupOldFailedTranscriptions` deletes audio before persisting entry removal
(FailedTranscriptionManager.swift:296-309).

### P1-D. Quit-during-stop-timeout preserves a possibly-unfinalized WAV, forever
When quit interrupts a timed-out stop, the preserved entry references scratch WAVs
whose headers the killed background finalize never patched. **Nothing on next launch
re-runs finalization**, so retry can fail cleanly every time — visible but never
succeeding. (C2 residual.)

### P1-E. Multi-segment preservation captures one segment only
`audio.micAudioFileURL` can point at the newest recovery segment, not the full
recording (Audio.swift:974-977). A timed-out quit preserves only that segment; a
later retry transcribes partial mic audio with no warning. (C2/C1 residual.)

### P1-F. DiarizationService.initialize() has no in-flight dedup
Concurrent warmup + queued-job init can run `initializeOffline()` twice (duplicate
multi-hundred-MB load); a losing duplicate that throws overwrites `modelState` to
`.failed` even though the manager is loaded, spuriously failing one meeting into
the failed queue (DiarizationService.swift:66-94). Mirror
`ParakeetEngine.modelInitializationTask`.

### P1-G. No automatic retry, ever
`retryFailedMeeting` is only invoked from Home UI. A network blip during model
recovery means the meeting sits until the user notices. Auto-retry-once when models
become ready (plus once on launch, capped) removes the manual step.

### P2-H. 30-day failed-audio expiry is silent and crash-unsafe
`failedMeetingAudioRetentionDays = 30`: audio + entry hard-deleted at launch; a user
who waits loses the meeting silently; deletion order (audio before entry persist)
can leave dangling non-retryable entries (FailedTranscriptionManager.swift:287-312).

### P2-I. Home scanner silently skips unparseable transcripts
`RecentMeetingsScanner.loadRecent` drops any transcript where
`displayTranscriptPreview` returns nil — read failure or bad frontmatter
(RecentCaptureScanners.swift, MeetingTranscriptStyler.swift:38-58). A
partially-written transcript (crash during save) exists on disk but never shows.

### P2-J. Pipeline memory profile for 2h audio
~0.92GB transient per file load, ~1.4GB with both alive; the 16k-mono short-circuit
(`loadWAV`) reads the whole file in one shot. Feeds P0-A via memory pressure.

### P2-K. Sleep gaps never enter the merged mic timeline
Sleep duration is recorded only as an AudioGap; merged mic vs system timelines
diverge by the sleep length → speaker attribution skew after wake
(Audio.swift:626-634, MicRecordingSegment.swift:17-25).

### P2-L. Observability gaps (reporter's explicit complaint)
No merge duration telemetry; no event distinguishing audio-save vs processing
failure; no visibility into the rescue/promotion process.

## 3. The durable fix: recording journal + crash recovery

The architecture answer to "save-as-recorded / chunked processing" that kills the
failure class with the least risk. Invariant to enforce:

> From the moment recording starts, there is never a moment where meeting audio
> exists on disk without a durable, discoverable record that the app can act on at
> next launch.

### 3.1 Meeting recording journal (new, `Sources/TranscriptedCore/Audio/` or `Storage/`)
A per-meeting JSON sidecar in the scratch dir, written atomically + fsynced on each
transition:

```
{ id, startedAt, state,            // recording → stopping → finalized → enqueued → done/failed
  micSegments: [{url, format, gapBefore}],
  systemAudioURL, lastCheckpointAt }
```

Written at: recording start, each segment rotation, stop entry, finalize completion,
queue handoff, terminal state (then deleted). Cheap — a few writes per meeting plus
one per checkpoint tick.

### 3.2 Launch recovery scan (new, mirrors DictationAudioRecovery)
On startup, scan `tmp/recordings/` for journals in non-terminal states:
- repair WAV headers (walk RIFF chunks, patch RIFF/data sizes from actual file size — valid because PCM data is append-only),
- run/finish the segment merge if needed,
- insert a retryable entry into the failed queue (or auto-enqueue transcription),
- emit `meeting_recovered_at_launch` event.

This single feature closes P0-A, P1-D (header repair), P1-E (journal holds ALL
segment URLs), and the crash half of P0-C (journal records merged URL before
deletes).

### 3.3 Periodic WAV header checkpoint (small, `AudioFileManager`)
Every ~60s on the existing serial file queues, patch the RIFF/data size fields via
FileHandle. Any crash then leaves near-valid WAVs even before recovery-scan repair
runs. (Considered CAF instead — headerless-safe by design — but it changes every
downstream consumer; WAV checkpointing is ~30 lines and zero migration.)

### 3.4 Move merge off the stop path
Stop becomes: close handles + journal "finalized" — O(seconds), independent of
length. Segment merge moves into the queued transcription job as a pipeline
pre-step (the queued path already exists and is durable-on-shutdown). The
90–120s stop timeout stops being a cliff entirely; the meeting appears on Home as
"processing" immediately, backed by on-disk state.

### Why not the alternatives
- **Chunk rotation every N minutes**: stronger guarantee but touches every consumer
  (merger, archiver, resolver, retry, M4A compression) — the journal gets the same
  user-visible guarantee at a fraction of the blast radius. Revisit as Phase 4.
- **Streaming-first (live transcriber checkpoints)**: attractive long-term and
  pairs with the live-sidecar beta, but model memory/thermals over 2h are unproven
  and diarization still needs full audio. Not the reliability fix.

## 4. Phased implementation

### Phase 0 — verify + instrument (small PR, do first)
1. Spike test for C3: write a WAV via the production path, SIGKILL mid-write,
   inspect header on macOS 26; determines how aggressive 3.3 must be.
2. Telemetry: finalize/merge duration + segment count on `recording_stop_*` events;
   `merge_fallback_primary_only` event (P0-B detection in the wild); promotion
   success/failure events. Update both payload sanitizers in the same change.
3. Check Sentry meeting-health rollups (b28d7771) for stop-timeout frequency to
   size real-world impact.

### Phase 1 — P0 correctness patches (one PR series, independent of architecture)
1. **Ordering** (P0-C): merge writes `*_merged.wav` → journal/queue repoint persists
   → THEN delete source segments. Same fix in `cleanupOldFailedTranscriptions`
   (persist entry removal before deleting audio).
2. **Merge salvage** (P0-B): per-segment try/catch — skip unreadable/empty segments,
   insert their gap as silence, count them; only abort if ALL segments fail. Surface
   `audio_health: degraded (lost N segments)` in transcript frontmatter + event.
   Stop deleting segments on partial salvage.
3. **Writer-lifetime**: explicitly release/close segment writers before
   `cleanupGroup.notify` fires the merge (close API if available on macOS 26,
   else verify deinit ordering on the serial queues), plus a one-retry-on-zero-length
   guard in the merger.
4. **DiarizationService dedup** (P1-F): mirror ParakeetEngine's task dedup.

### Phase 2 — journal + recovery scan (the headline PR for #825)
Implement 3.1 + 3.2 + 3.3. Wire scan into `TranscriptedAppState` startup after
FailedTranscriptionManager load. Comment on #825 with before/after behavior.

### Phase 3 — follow-ups
- Move merge into queued job (3.4); stop timeout becomes close-only.
- Auto-retry-once on models-ready + on launch (P1-G).
- Home: render unparseable transcripts as a fallback "needs repair" row (P2-I);
  "expiring in N days" notice for failed entries near the 30-day cutoff (P2-H).
- Sleep-gap insertion into merged timeline or pipeline alignment metadata (P2-K).

### Phase 4 (optional, beta-gated)
Chunk rotation + live transcript checkpoints — the full save-as-recorded vision,
pairs with the live-sidecar/agent story.

## 5. Test plan (no 2h recordings needed)
- **Synthetic fixtures**: generate long WAVs fast (silence/sine via AVAudioFile
  writes); truncate/zero headers for repair tests; zero-length segment fixtures for
  salvage tests.
- **Fast tests** (register in `Tests/FastTests.manifest`!): journal state machine;
  recovery scan (orphan journal+WAV → failed-queue entry); WAV header repair;
  merge salvage (bad middle segment → others survive + gap inserted); ordering
  (entry persisted before deletes — assert via injected FileManager spy);
  DiarizationService concurrent-init dedup.
- **SPM tests** (`swift test`): merger/resampler/TaskManager pieces in
  Tests/TranscriptedCoreTests.
- **Integration smoke** already covers MicRecordingFileMerger — extend with the
  salvage case.
- **Time-compressed E2E**: constants seam to scale per-minute instead of per-hour;
  record 60–90s in `run-live-capture-smoke.sh` to exercise the scaled path live.
- Gates per `.agents/test-matrix.yml` (Sources/Meeting + TranscriptedCore +
  Tests/Integration touched): `build-deps.sh --force` → `build.sh --no-open` →
  `run-tests.sh` → `run-integration-smoke.sh` → `swift test`. Run bare, no pipes.

## 6. Open items / honesty notes
- C3's exact AVAudioFile header semantics on macOS 26 are unverified (Phase 0.1).
- Merge wall-time at .utility QoS on low-power machines is unmeasured (Phase 0.2).
- Real-world stop-timeout frequency unknown until the Sentry check (Phase 0.3).
- The multi-agent design panel + 3 of 9 subsystem readers died on the session usage
  limit (resets 7pm CT); workflow run `wf_d9082f72-374` can be resumed for the full
  panel, but the salvaged evidence (5/6 verdicts + complete merge-subsystem map)
  already determines the direction above.
