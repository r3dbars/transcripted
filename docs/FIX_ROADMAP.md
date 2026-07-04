# Transcripted Fix Roadmap

_Last updated: 2026-06-20. Source: verified engineering audit of the current tree, cross-checked against in-flight branches. Findings here exclude work already underway (meeting-capture prompting, speaker-naming ladder, ERes2Net #1175, telemetry/triage PRs) except where noted._

## State of the product (honest)

Transcripted works, but it leaks trust and quietly drops content at the edges. The core capture-and-transcribe loop is solid and the model now ships bundled (no first-run download race). The real problems are threefold: (1) **a serious privacy regression** — the live overlay and transcript drawer are screen-share-visible, so during a recorded call the other party's just-spoken words can get broadcast back onto the shared screen with no macOS warning; (2) **silent data loss** in a handful of paths — a system-audio tap that installs but never streams is marked "recording," a >5-minute dictation is discarded on timeout, and non-disk-full write stalls keep the duration timer ticking while audio dies; and (3) **activation gaps** — the meetings-first onboarding never records a real meeting, never teaches the default-on auto-detect, and there's no terminal event for the permission-bounce drop-off. The speaker-identity subsystem has two real-but-bounded accuracy holes (write-time voiceprint contamination, sub-naming-bar cluster fusion) that should ride behind the existing eval harness. Nothing here is a rewrite. Most of the highest-value fixes are small.

---

## NOW — highest impact-to-effort, not in flight

### 1. Stop broadcasting the call's overlay + transcript onto screen share — `sharingType = .none`
**Impact 9 · Effort S**
For a tool whose entire premise is privately recording a call, painting the *other* party's transcribed speech (labeled "Them:") back onto the same screen you're sharing — silently, no OS warning — is the worst-case trust failure. `grep -rn sharingType Sources/ Tests/` returns zero hits: all floating panels default to `.readOnly` and are captured by ScreenCaptureKit. Fix is one line per panel in three NSPanel inits.
- `Sources/UI/Overlay/FloatingOverlayPanel.swift:6-33`
- `Sources/UI/Overlay/MeetingOverlayController.swift:21-51` (MeetingOverlayPanel) and `:55` (MeetingOverlayTooltipPanel — the third panel, easy to miss)
- On-screen render path: `MeetingOverlayController.swift:1609-1610` → `MeetingLiveTranscriptDrawerView.update(transcript:)` `:188`
- Set `self.sharingType = .none` in all three inits + add a guard test.

### 2. Whisper engine silently drops the user's custom dictionary
**Impact 5 · Effort S**
A user who teaches the app their proper nouns expects those corrections everywhere. Whisper ignores them; Parakeet applies them. Pure correctness/trust break, double-gated (must select Whisper *and* have a populated dictionary) so it's not catastrophic, but the fix is essentially one line mirroring Parakeet.
- `WhisperEngine.swift:141` returns `trimmed` with no `CustomDictionary` reference (shared by dictation + meeting-segment routes, `:129`)
- Parakeet applies `CustomDictionaryTextProcessor.apply` at `ParakeetEngine.swift:2920` (and `:2726`, `:2765`)
- Router sends Whisper to the skipping engine at `STTRouter.swift:168`, `:192-197`
- Fix: wrap `WhisperEngine.swift:141` in `apply(to:)` (pure, default-args, no-op on empty dict).

> These two are the only true "NOW" items: trivial effort, no branch overlap, and each closes a live trust/correctness hole. The remaining high-value work needs the eval harness or sequencing behind in-flight surfaces, so it lands in NEXT.

---

## NEXT — do these right after NOW

### 3. Meetings-first onboarding never records a real meeting (no time-to-first-meeting aha)
**Impact 8 · Effort M**
The default onboarding path is meetings, but every meeting step is a mock: a static menu picture and a hardcoded fake transcript. The dictation path, by contrast, wires a live demo and fires a real "first dictation saved" event. The activation moment was even specced into telemetry (`onboarding_meeting_dry_run_clicked`, `meeting_dry_run_completed`) and never built. **Sequence behind** the in-flight meeting-capture prompting work so the onboarding step teaches the final one-tap gesture, not one about to change.
- Default: `PermissionsOnboardingView.swift:42` (`selectedUseCase = .meetings`)
- Mock steps: `.meetingStart` `:247-259` + `MeetingStartPathCard` `:1661-1696`; `.meeting` `:279-287` + `MeetingDemoCard` `:1628-1659`
- Dictation does it right: `DemoPasteTarget` `:230`, real event `DictationSessionController.swift:1562-1569`
- Unbuilt telemetry: `AnalyticsEventPolicy.swift:294-300`, `:326`, `:337`

### 4. System-audio tap that installs but never streams is marked "recording," never recovered
**Impact 6 · Effort M**
Readiness goes green on "I/O proc started + file URL assigned," not "first buffer arrived," so a silent-death tap loses the entire remote side of a meeting with no recovery — only a passive `.silent` badge after 10s. Hard permission failures already throw cleanly; this is the narrower silent case.
- `AudioCaptureStartState.swift:23` (`.ready` on `isRecording && systemAudioFileURL != nil`); URL assigned at `AudioFileManager.swift:226`
- Watchdog can't help: guarded on `hasReceivedFirstBuffer` (`SystemAudioBufferWriter.swift:24`, set at `SystemAudioProcessTap.swift:129-131`)
- Fix: gate start outcome/timeout on a first-buffer-arrival deadline; let the watchdog fail/recover.

### 5. Dictation past 5 minutes is discarded on timeout instead of finalized
**Impact 6 · Effort S**
A >5-min dictation loses 100% of its content with only a cancel chime. The timeout calls `cancelDictation()` (which discards the buffer) instead of finalizing. A graceful finalize already exists; the only nuance is suppressing auto-paste (the cap exists to recover *walked-away* sessions).
- `DictationSessionController.swift:67` (5-min cap), `:1334-1340` (timeout → `cancelDictation()`), `:1063`/`:1380` (discards buffer)
- Reuse `stopDictationAndPaste` `:714` (empty-transcript already handled `:889`) → finalize-and-save, suppress auto-paste.

### 6. Matched profiles EMA-blended on every match with no write-time quality gate
**Impact 7 · Effort M**
A mature, named profile accepting a 0.70 cosine match from an under-segmented cluster blends contaminated audio into the persisted voiceprint — permanent, compounding, invisible. The match step rejects immature and ambiguous matches, so the residual hole is narrower than "every match," but real. **Ride the same eval harness as the naming-ladder sweep**; ship just behind it.
- Write-back fires at `TranscriptionPipeline.swift:309` and `:731`; blend at `SpeakerDatabase.swift:250-262` (alpha=0.15)
- No quality/margin gate at write time; the certified ladder is consumed only for display naming (`TranscriptionPipelineRunner.swift:192-284`)

### 7. Auto-detect calls is default-ON but onboarding teaches the manual path instead
**Impact 6 · Effort S**
The strongest zero-effort capture lever is on by default and never taught; onboarding teaches the manual menu path and frames detection as calendar-only. Ship a minimal copy fix now (prime the auto-prompt in `.meetingStart`, stop the calendar-only framing) since that copy is safe regardless of how the in-flight prompting redesign resolves.
- Default ON: `AutoCallDetectionPreferences.swift:9-10,21-24`
- Manual-path copy: `PermissionsOnboardingView.swift:251`; calendar-only framing `:288-318`
- Feature is real and wired: `MicActivityMonitor.swift` → `MeetingPromptDetector`, gated at `TranscriptedApp.swift:237-244`

### 8. ~~Adaptive 0.70 match floor binds + merges clusters below the 0.92 naming bar, no per-utterance unmerge~~ — RESOLVED
**Verified fixed 2026-07-03 (re-audit; this doc was stale).** The link/merge floor is decoupled from the per-utterance attach floor exactly as prescribed below, and per-utterance unmerge shipped separately:
- `SpeakerWritePathPolicy.crossClusterLinkFloor` (0.78) + `Transcription.planCrossClusterLinks` fuse same-profile clusters only when directly similar to *each other*, spinning distinct voices off to a fresh profile — [#1236](https://github.com/r3dbars/transcripted/pull/1236) (merged 2026-06-22). Wired in both pipeline paths: `TranscriptionPipeline.swift:343-410` (system), `:936-964` (mic); planner at `SpeakerMatchingService.swift:111-196`.
- Per-utterance/per-contribution unmerge (`reassignContribution`, `unmergeMostRecent`) — [#1330](https://github.com/r3dbars/transcripted/pull/1330) (merged 2026-07-01), `SpeakerProfileProvenance.swift`.
- Coverage: `SpeakerWritePathPolicyTests` (13 tests incl. the exact two-distinct-people-one-profile case), `SpeakerProvenanceTests` (8), `SpeakerWriteBackGateTests` (3) — all pass on current `main`. Independent codex-reviewer pass on #1236 (PASS, follow-up hardening applied same PR).
- **Residual gap, not this item:** validated so far only on synthetic controlled-geometry corpora (`scripts/gen_synthetic_speaker_eval.py`); a real AMI/VoxCeleb sweep of `crossClusterLinkFloor=0.78` specifically (flagged as outstanding in #1236 itself) has not been run.

### 9. Disk-full / write errors silently kill audio while recording keeps "running"
**Impact 5 · Effort S**
After 10 consecutive write errors the writer drops every later buffer, but `isRecording` stays true and the duration timer keeps counting. The common case (full disk) is *already* handled by a 30s disk-space check; the residual gap is non-disk-full stalls (permission/sandbox loss, file deleted under the handle).
- `AudioFileManager.swift:383`, `:399-405` (cap, no external consumer)
- Fix: mirror the existing disk-full pattern (`:487-491`) — at the cap, hop to main, set `self.error`, call `stop()`.

### 10. Permission-bounce drop-off has no stage-attributed terminal event
**Impact 5.5 · Effort S**
The permission-cliff cohort is *derivable* today (cta_clicked fired, no status_changed, no completed) but there's no single clean terminal event, and a backgrounded-vs-window-closed exit isn't captured. **Read why PR #1192 was closed first** — it built nearly this exact fix (`onboarding_exited`/`trackExitIfNeeded`) and was declined. Don't re-ship a rejected idea blind; scope the rebuild to the resign-while-on-permission-step case #1192 still missed.
- `PermissionsOnboardingView.swift:122` (only `trackAbandonmentIfNeeded` call), `:644` (bounce, no exit event)
- Existing signals: `onboarding_permission_cta_clicked` `:634`, `onboarding_permission_status_changed` `:582`

### 11. No second-session re-engagement mechanism — return is measured, never driven
**Impact 6 · Effort L**
Return is purely observational (`trackReturnProxyIfEligible`); nothing *causes* a second session. A win-back nudge for a privacy-first menu-bar app is a blunt instrument with real annoyance ceilings, and a streak surface + `MeetingPromptDetector` already capture some in-the-moment pull. **Land the measurement PRs (#1221, #1211, both open) first** so a nudge can be evaluated against the return-proxy baseline.
- Observational only: `ActivationTelemetry.swift:250-306`, consumed at `HomeView.swift:182-203`
- Effort L: needs notification-permission UX, scheduled notifier, frequency-capping, analytics.

---

## LATER / nice-to-have

- **Local AI summary path skips OwnFileResolver** (Impact 3, Effort S). Real inconsistency — summary uses raw `transcriptURL` while copy/open/reveal resolve — but the premise that resolution "fixes" the restyle-rename case is wrong (rename changes the stem; the resolver returns nil there too). The broadcast→refresh loop keeps the URL fresh sub-second, so this is a narrow race that mostly upgrades an ugly error to a friendly one. Mirror the `resolveExistingFile` guard. `TranscriptedSettingsView.swift:929,935-941,969-977`, `LocalMeetingSummarizer.swift:1075,1250`.
- **No unsupervised within-cluster split** (Impact 6, Effort L). Under-segmentation is only recoverable when both speakers are pre-enrolled; `dbInformedSplit` is the sole splitter (`DiarizationService.swift`, `TranscriptionPipeline.swift:151-155`). But the codebase's *documented, repeatedly-mitigated* failure mode is the opposite (over-segmentation), and `SpeakerNamingSimulationMergeIndicator` already scores this exact failure. **Quantify the merge-indicator rate on the sim corpus before committing** to a large, regression-risky split.

---

## Already in flight (covered — don't duplicate)

- **Meeting capture: calendar pre-arm + browser detection + one-tap** — `docs/MEETING_CAPTURE_PROMPTING.md` (design doc, commit e79cc462). Targets the *production* detection problem (off-by-default auto-record, browser blind spot, late start). Adjacent to onboarding #3/#7 but a different surface — sequence onboarding behind it.
- **Recording-consent / disclosure model** — folded into the meeting-capture prompting design (section 4: all-party consent, per-recording verbal disclosure, consent log, Otter-case-aware). The standalone one-time-banner idea is the *weak* fix this work explicitly rejects. Do **not** spin up a parallel task.
- **Speaker-naming certified ladder** (0.92/0.12 auto-name bar) + **ERes2Net #1175** (embedding-model swap, superseded/rebased as #1346). Both touch the matching surface that #6 and #8 ride behind. The ladder raises only the auto-*name* bar, not the upstream link/merge floor — but #6 and #8 are both now closed separately, by [#1236](https://github.com/r3dbars/transcripted/pull/1236) (write-path gate + link/merge floor decouple) and [#1330](https://github.com/r3dbars/transcripted/pull/1330) (per-utterance unmerge). See #8 above.
- **Telemetry / triage PRs** (#1177, #1218, #1169, #1221, #1211). Measurement, not fixes. #11 depends on #1221/#1211 landing.
- **Config-change audio-engine teardown hardening** — active workstream (commit 804617e7, AirPods/BT wedge). The teardown-timeout finding is **dropped**: no beachball (awaits suspend, not block the MainActor), a 4s watchdog already recovers, in-flight audio is snapshotted. File as a small follow-up to that line if at all.

### Dropped (verified not worth doing)

- **~600 MB model download stalls first meeting** — false for the shipped product. Distribution builds bundle the model and hard-fail without it; only `--thin`/local-dev builds skip it, and users never receive those.
- **Config-change teardown timeout** — see above; impact ~3 not 7, already backstopped.
- **Recording-consent standalone banner** — superseded by the in-flight design.

---

## The single highest-leverage thing to do next

**Ship #1 — set `sharingType = .none` on all three overlay panels.** It is the only Impact-9 item, it is genuinely Effort-S (three one-liners plus a guard test), it has zero overlap with any in-flight branch, and it closes a silent privacy regression that directly contradicts the product's core promise: that recording a call is private. Everything else is correctness or activation polish that can wait a day; this is a trust failure that fires on the exact happy path Transcripted is built for. Do it first, today.
