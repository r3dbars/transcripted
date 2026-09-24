# Reliability hardening audit — 2026-09-15

> **Historical record.** This is a point-in-time write-up. Its status lines and file references reflect when it was written, not current `main`. For current behavior, read the source and the nearest `CLAUDE.md`.

Status: implemented; final local automated gate passed; not release-ready.

Integration PR: https://github.com/r3dbars/transcripted/pull/1740. Hosted CI and
merge state are tracked there separately from the local evidence below.

The C920 report exposed a shared input-startup problem, not evidence for a
device-name-specific workaround. A successful AUHAL command is asynchronous;
readiness requires the requested device ID and usable formats. This audit also
found separate risks in stop admission, empty-transcription recovery, blocked
route lookups, and initial meeting-journal durability. These are source findings
with deterministic coverage, not reproduced customer incidents.

## Scope and evidence

- Baseline: main `65bf93aee460a937de8ed9c3e7bcdd66ad95b294`; source changes isolated
  from the user's checkout. Public release remains 1.1.59. The 1.1.60 version
  preparation is separate from this audit and is not a published release.
- Reviewed open issue #1734 and merged/superseded USB PRs #1736/#1735; previous
  light-mode and fresh Swift 6.4 dependency-build repairs are already on main.
- Support clusters reviewed: C920 startup, AirPods startup, Bluetooth/Zoom/Meet
  coexistence, pasteback/ordinary Cmd+V, permission-review UI, M1 meeting startup,
  speaker finalization, imported audio, and long-meeting retention/recovery.
  A fix announcement or closed issue is not confirmation from the reporter.
- Local log inventory: app 1,902 valid JSONL records; current events 8,679;
  rotated events 12,725; reliability 4,530. The reliability log is derived from
  events and is not independent evidence. Logs contain local development/use,
  not a representative customer sample. No private recordings or transcript
  contents were exported. The latest local logs predate the new fixes.
- Local 1.1.59 warnings include 25 readiness-refresh timeouts, 16 route-not-settled
  records and 13 engine rebuilds. These are event counts, not distinct failures
  or affected people, and do not establish a C920 cause.
- PostHog: live schema verified, project 378427, UTC 2026-09-10 through the
  audit-time partial day 2026-09-15; filters `app_version=1.1.59` and
  `build_channel=release`. Dictation startup failures: 21 events, consisting of
  Bluetooth mic timeout 10, built-in timeout 4, Bluetooth start failure 2,
  external timeout 2, unknown-input timeout 2, and Bluetooth/model-load timeout 1.
  No meeting-start-failure events were returned for these same filters. Neither
  zero events nor the startup distribution proves all installations are healthy.
- Sentry: blocked; no callable connector or configured read authentication.
  Crash-free rate and release symbolication have not been established.
- Hardware: no C920 attached. The local host is macOS 27; the C920 report concerns
  macOS 26.4.1. Physical C920, cross-app audio and exact-candidate manual proof
  remain unknown. No customer email or release was sent by this audit.

## Instrumentation trust

`dictation_started` is emitted after a successful recording start, not at the
initial key press. `dictation_start_failed` includes failures that never become
started sessions. Dividing these unrelated totals would not give a valid failure
rate. `dictation_completed` is a terminal event with separate delivery metadata;
it must not be equated with confirmed paste. Sample flow is separately reported.
Meeting-start failure records carry stage and failure kind after the capture
start gate rejects the attempt. Privacy allowlists expose coarse input classes,
not device models: the two external-input events cannot be called C920 events.

The earlier USB merge moved selection-success reporting after strict binding
verification. This audit retains that ordering. Cancelled or stale operations
must never publish readiness merely because native work eventually returns.

The empty-ASR recovery and existing model-failure event names are now explicitly
registered in the privacy allowlist, including a regression check for dynamic
event names that literal-call scanning cannot discover. A session-cap Markdown
save failure now reports `delivery=failed` and `failure_kind=markdown_save_failed`,
not `saved_without_paste`. `dictation_completed` still counts terminal processing
outcomes, including failures; saved artifacts and confirmed delivery remain
separate measures. These changes have local policy coverage, not post-release
ingestion proof.

## Prioritized source findings

| ID | Impact / confidence | Finding and intended correction |
| --- | --- | --- |
| R1 | High startup reliability / confirmed source with synthetic driver | A driver taking longer than the single 300 ms check can be repeatedly reset by retry writes. Poll the one accepted command within a monotonic deadline; pass shrinking budgets to native probes. Preserve selected-ID and format checks. |
| R2 | Wrong-mic risk / confirmed conditional source | Selection lookup failure became nil, allowing an old pinned graph's valid format to bypass selection verification. Fail closed before accessing that graph. |
| R3 | Lost recovery audio / confirmed conditional source | Empty ASR after usable captured signal was classified as no speech and its checkpoint discarded. Preserve recoverable audio in both Parakeet and the external-model router and provide an actionable recovery path; true silence/intentional short clips retain their existing policy. |
| R4 | Overlapping finalization / confirmed conditional source | A second Stop during asynchronous checkpointing could cancel the first owner and race writes/deletion for the same session. Admit finalization once per session and serialize retry ownership. |
| R5 | UI/recovery hang / confirmed conditional source | Default-input notification reads could enter blocking HAL on main; mailbox lookup could wait forever before the recovery timeout started. Move notification lookup off main and bound serialized recovery lookups, preserving notification ordering and worker limits. |
| R6 | Unrecoverable meeting scratch / confirmed conditional source | Initial journal persistence swallowed write/sync errors and still let recording begin. Require durable initial journal creation before installing capture; fail visibly and clean up only the new owned writer on failure. |
| R7 | Lost complete recording / reproduced with synthetic codec fixtures | A valid shortened AAC file could authorize deletion of the full WAV. Compare duration and channels and decode the tail before promotion; reject symlinks. Apply the same checks to retry-queue audio. |
| R8 | Concurrent startup churn / confirmed conditional source | Overlapping prewarms advanced graph generation and restarted the same binding. Coalesce by native engine/queue, join the active probe with a bounded cancellable wait, and permit a replacement graph to escape an old blocked stop. |
| R9 | Misleading success measurement / confirmed conditional source | Session-cap Markdown persistence failures were labeled saved-without-paste. Report failed delivery and the categorical save-failure reason; preserve recoverable audio and the visible storage error. |
| R10 | Startup invalidated by its own notification / confirmed source and delayed-callback fixture | HAL lookup latency could age out a self-induced notification's suppression window; a cached route could also omit the window despite a real native setter. Carry callback arrival and the actual setter's bounded, success-confirmed ownership through the mailbox; unknown or changed routes do not qualify as that setter's echo. |
| R11 | Stopped audio lost or transcription stuck / confirmed conditional source and ownership-barrier fixture | A graph-only route change could reject detached conversion of already captured samples, skip the durable checkpoint, and leave a stale transcription busy flag. Separate recorded-audio ownership from graph readiness while fencing new recordings, cancellation and successor work. Prepared snapshots now carry sample ownership; stale conversion completion cannot clear another recording. |
| R12 | Unbounded Quit and only-copy loss / confirmed conditional source and policy tests | Quit waited indefinitely for checkpoint completion after a native stop stalled. A failed snapshot/write could also let inference consume, or new capture overwrite, the only native recording. Bound the Quit wait and decline unsafe termination visibly; fence consuming inference and new capture, and offer same-session no-paste Retry Saving after a failed checkpoint. Checkpoint completion alone is not persistence. |

These priorities describe reachable harm, not measured incidence. In particular,
the synthetic reset-on-write driver in R1 does not establish C920 driver behavior.

## Remaining review findings

- A permanently blocked native stop is not repaired by the Quit safeguard. The
  app now declines unsafe termination and preserves its only in-memory recording,
  but force quit, a crash, power loss, or explicit discard can still lose RAM.
  Actual OS-termination and storage-fault behavior require manual verification.
- Faster Bluetooth dictation was explicit opt-in. Its persistent-input controller
  still has synchronous HAL preference/restore paths. Moving notification reads
  alone does not prove all possible driver-induced main-thread hangs are fixed.
  Update 2026-09-23: the toggle was removed from Settings and the preference is
  switched off at launch. The controller still runs its restore path (including
  these synchronous HAL calls) for one release, then gets deleted. The finding
  is retired only once it's deleted.
- The legacy system-default-input restore suppression window remains 2.5 seconds.
  A genuine default-input-only change inside that window can still be suppressed;
  the new actual-setter token specifically hardens audio-engine notifications.
  Physical disconnect/reconnect and cross-app route verification remain required.
- Imported old recordings with 7/30-day retained-audio cleanup can be pruned
  immediately because retention uses the original recording date. Default Never
  is unaffected. The existing tests deliberately encode recording-date semantics;
  an archive-age policy needs explicit treatment of new imports and legacy data.
- Meeting journal startup errors still use the existing `microphone_file` stage,
  which maps to `mic_unavailable` in fleet classification. The new user-facing
  error distinguishes local-storage failure, but that coarse fleet category must
  not be interpreted exclusively as a physical microphone fault.
- The old Cmd+V report is not evidence of stale TCC. Current physical binding
  validation rejects Cmd+V/Shift-Cmd+V, including unsafe persisted shortcuts, and
  matches modifiers exactly. The reported improvement after reset/reinstall does
  not identify the cause.
- Speaker-finalization issue #1681 has current repair paths for re-transcribing
  pending review, stable-ID re-resolution and durable retry audio. This is source
  and test evidence, not a customer retest.

## Preserved strengths

Local-first transcription and categorical telemetry remain intact. Dictation
uses app-local input binding rather than changing the Mac-wide input per session.
Device ID zero and stale selections remain failures. Existing queue ownership,
bounded worker admission, separate capture/saving/delivery states, durable stopped
audio, failed-import retries, and clipboard ownership protection remain required.

## Verification ledger

- Baseline exact-main full QA: 15/15 lanes, 13,670 fast assertions; this is only
  baseline evidence and does not validate the changes above.
- R1 focused deterministic binding-settle tests: initial 30/30 passed; includes
  old-pattern starvation control, 800 ms success after one write, zero/stale ID,
  deadline consumption, native error and stale-owner/cancellation cases.
- R7 real codec regression: baseline failed three assertions because both a new
  shortened M4A and a preexisting shortened M4A permitted WAV deletion. The first
  fixed suite passed 132/132, including normal AAC conversion. Additional symlink
  and failed-queue checks are included in the combined run.
- Fresh dependency rebuild from final journal source `79fcca3d`: exit 0;
  dependency-input digest `db0e7638bf63b0423fef4c1e54ec2a9f9996e64ab8fdae5483006595cc1b87c3`.
- Core `swift test`: 1,097 cases, zero failures, 13 opt-in skips; exit 0.
  The skipped cases remain unverified, not passed hardware checks.
- Combined source at `52e9a38b`: full QA passed 15/15 lanes, including the app
  build, 13,819 fast assertions, integration, deterministic E2E, slow-pasteback,
  core package tests, QA tools, imported-artifact and synthetic-audio fixtures.
  This does not certify hardware or distribution. Run: `qa-20260915-210926`.
- Independent full-diff and follow-up cross-review identified a remaining
  delayed-notification suppression interaction, stopped-audio ownership coupled
  to route changes, and an unbounded quit/checkpoint wait. These were corrected,
  including failed-checkpoint new-capture and nil-snapshot inference safeguards.
  The follow-up source at `bd873f0a` built successfully. Its full fast suite found
  two obsolete source-string assertions (old binding-call signature and inline
  suppression-window expression), not failing behavioral fixtures. The contracts
  were updated to assert the exact engine/intent ordering and Zoom bypass of the
  replacement suppression policy. Independent review of those test updates was
  green; the final combined rerun below passed. Hosted CI is tracked in PR #1740.
  No hardware/fleet finding was dismissed as resolved by local tests.
- Native AppKit component fixtures for retained audio, startup recovery,
  missing-recovery and model-failure copy fit their actual panel-body bounds.
  The injected Show Audio target fires in the component. Corrected recovery
  text matches the actual Capture -> Transcribe Audio File menu command.
  This is not live panel, Finder, ASR, Accessibility or hardware proof. See
  `.agent-review/visuals/reliability-2026-09-15/README.md`. Final generic recovery
  and missing-recovery copy was re-rendered at source `bd873f0a`; older images
  are explicitly labeled historical. Safe-Quit and Retry Saving fixtures are in
  `.agent-review/visuals/termination-quit/README.md`; the injected retry action
  fires, but the fixture does not exercise an actual driver or storage failure.
- R10 callback-arrival/binding-ownership follow-up: 147/147 focused assertions.
  Independent review required an asynchronous bounded wait when notification
  delivery precedes setter completion; successful, failed, hung, and late native
  completions are now distinguished. App/combined verification remains pending
  the other review follow-ups.
- R11 recorded-audio ownership follow-up: app build passed; focused ownership
  137/137, recovery 42/42, and presentation 7/7. Root review caught and corrected
  an external-model error path whose cleanup ran before error classification.
  The final implementation releases its transcription owner after classification
  and protects successor state on both successful and failed model responses.
  These are source/policy and synthetic barrier checks, not a live hardware/model
  reproduction.
- R12 safe-Quit/checkpoint follow-up: focused termination/retry 43/43 and stopped
  audio recovery 36/36; source-list validation and parse checks passed. The final
  integration contains additional R11 recovery checks and was tested below.
- Final combined application/test source `7c93e16b` (documentation commit
  `40d745ff`): full QA passed **15/15 lanes**, exit 0, with **13,928/13,928 fast
  assertions**, app build, deterministic E2E, slow pasteback, integration, core,
  QA package/round-trip/stress, imported artifacts, synthetic audio and fixture
  release-health/PostHog checks. Run: `qa-20260915-215832`. Core remains 1,097
  cases, zero failures and 13 opt-in skips. Source-list, duplicate-declaration,
  touched shell syntax and diff checks passed. Final changes after this run are
  documentation-only. The QA operator verdict explicitly remains HOLD for
  manual proof; fixture release health is not a sealed 1.1.60 distribution test.
- Final independent integration review: GREEN for the stopped-audio ownership,
  failed-checkpoint inference/new-capture guards, safe Quit and same-session
  retry. Review did not exercise native OS termination, denied/full storage,
  physical C920 or live Sentry. Auxiliary model/Windows lanes were not used;
  the work used Codex source review and direct local macOS verification.

## Exact-candidate manual gates

Before calling 1.1.60 release-ready, verify a sealed candidate on physical C920
(including reporter OS), built-in and AirPods routes: cold start, repeated
dictation, reconnect/default-input changes, sleep/wake, and changes during
capture. Confirm usable samples, saved text and retained recovery audio—not only
a ready indicator. Exercise Zoom and browser meetings with system and microphone
audio, then long recording stop/restart/recovery. Verify real target-app paste,
clipboard restoration and ordinary Cmd+V. Packaging/updater, signing/notarization,
Sentry release health and distribution remain separate gates.

The current conclusion is implemented and locally verified hardening, not guaranteed
hardware resolution, zero failures, or a released build.
