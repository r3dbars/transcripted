# Transcripted 1.1.48 Release Candidate Notes

**Status: draft — not yet a release candidate build, compiled from merged main.**
Nothing in this document has shipped. It is a working summary of everything
merged into `main` since the `1.1.47` candidate notes were written, so it can
serve as the starting point for the next real candidate. See the version-number
caveat below before treating "1.1.48" as this batch's eventual release number.

## Candidate Summary

This draft covers 298 merged pull requests on `main` between the `v1.1.47` tag
(June 8, 2026) and today (July 3, 2026)[^range]. The biggest through-lines are a
Home screen rebuild (content-first layout, filtering, in-transcript find),
a speaker-identity overhaul (simplified Speakers section, reversible merges,
a new voiceprint model), continued meeting/dictation reliability and recovery
work, a first opt-in beta speech model (Nemotron streaming), new agent/MCP
tooling for querying meeting history, and a broad accessibility and UI-polish
pass. A large, still-in-progress "Dayflow-style timeline" home-screen concept
is also landing in phases but is not user-facing yet. Underneath all of that
sits a very large volume of internal telemetry, testing, and process work.

[^range]: `git log v1.1.47..main --merges`.

## User-Visible Changes

- Rebuilt Home around a content-first, editorial layout with tabbed settings.
- Added a meeting-list filter and in-transcript find on Home.
- Fixed several Home bugs: dead delete confirmations, row/hover menu actions,
  action-button target retention, and a stats/greeting layout clipping issue.
- Made meeting rename discoverable from Home, and sped up Home's initial load
  by caching recent meeting metadata and dictation-history stats.
- Home now warns when it detects a damaged capture-library scan, with
  retry/reveal/dismiss options instead of failing silently.
- Simplified the Speakers section: added a play/pause toggle, a 3-dot overflow
  menu, and name autocomplete.
- Speaker merges are now reversible — un-merge with provenance, instead of a
  one-way action.
- Added a confirmation step before merging speaker profiles, and low-confidence
  "ghost" speaker matches now stay separate and reviewable instead of silently
  collapsing into an existing voice.
- Landed a new voiceprint model (ERes2Net) aimed at more accurate
  who's-speaking identification.
- Added a "paste last dictation" keyboard shortcut.
- Custom dictionary entries now apply on the Whisper transcription path too,
  not just the other model paths.
- A dictation that hits the 5-minute timeout now finalizes and saves instead
  of being discarded.
- Dictation warmup and clipboard-fallback states now show clear status copy
  (what happened and what to do) instead of dropping the state silently or
  just saying something failed.
- Fixed an audio-engine rebuild loop that could occur when switching
  Bluetooth/AirPods routes mid-dictation.
- Fixed pasteback clipboard reliability, and added a visible confirmation state
  for Auto Enter.
- Improved hotkey event-tap recovery so global shortcuts keep working
  reliably.
- Meeting prompts wait longer and detect real calls more accurately, including
  listen-only meetings, with a missed-call nudge and launch-at-login on by
  default.
- Fixed meeting capture failure recovery, including salvaging recordings
  orphaned by a crash (root-caused to a stuck `AVAudioFile` writer leaving a
  WAV header that claims zero data size while the audio is actually intact on
  disk).
- Fixed the meeting overlay reading as frozen/done mid-recording when it was
  actually still in progress.
- Added a live transcript drawer, a Dynamic Island-style recording pill during
  meetings, and a separate floating capture pill.
- Menu bar: recording indicator, adaptive appearance, a quick menu, and a
  timer.
- Transcripted's overlay and app windows are now excluded from screen sharing.
- The Sparkle update prompt is now clearly versioned and unmistakably says an
  update is available (previously easy to miss or misread).
- Broad accessibility pass: VoiceOver labels, honoring Reduce Motion/Reduce
  Transparency, larger click/tap targets across Home, Settings, onboarding,
  and meeting/speaker UI, tabular digits, and better contrast on stats and
  status text.
- Polished first-run onboarding: clearer model-failure recovery copy, balanced
  headings, and a skip path for existing installs.
- Continued local-summary (Gemma) reliability fixes — setup stalls and prompt
  tightening. This remains an opt-in beta feature; default summary behavior is
  unchanged.
- New opt-in beta speech model: NVIDIA Nemotron streaming ASR (40
  locales), available from Settings behind a default-off toggle. Default
  transcription model (Parakeet TDT v3) is unchanged unless a user opts in.
- New: AI agents/tools can query Transcripted meeting history and search or
  read transcripts through MCP, including a CLI `transcribe` command for
  agent-driven audio/video file transcription.
- In progress, not yet user-facing: a multi-phase "Dayflow-style timeline"
  home-screen concept has several phases merged (phase 0 scaffold, a screen
  capture engine skeleton, database retention storage) with more phases still
  open (see Known Caveats). Nothing from this has shipped to users yet.

## Reliability And Ops Changes

- Hardened CI/build: fixed a sandboxed launch-smoke crash and a launch-smoke
  timeout cleanup bug, and pushed Testing/CI hardening broadly. One change
  (moving AppKit out of the core audio boundary) had to be shipped, reverted
  when it broke main, and then re-landed with an initializer fix — main is
  green again.
- Fixed several crashes: a dictation-engine audio-tap crash on stop, a wedged
  audio-engine queue hang on device change, a CaptureKit title-extraction
  crash with dropped speaker metadata, and a batch of residual fatal crashes
  (`objc_release` / `NSButton` selector / `TdtDecoder`).
- Speaker-ID reliability: added a write-time contamination gate and a minimum
  similarity floor for auto-merge, added self-healing demotion and lifeline
  metrics for the speaker-recognition pipeline, and built a headless
  speaker-naming evaluation harness scored against AMI ground-truth data
  across multiple corpora.
- Storage/recovery hardening: guarded meeting recording-journal writes with a
  per-session ownership token, fixed a stale Home cache after WAV→M4A
  recompression and transcript rename, tightened storage artifact writes, and
  fixed failed-meeting queue preservation so failed meetings survive cleanup
  passes.
- Fixed a set of "audit" fixes merged today for permission/storage UX,
  performance hotspots, and audio-recovery/failed-archive handling — grouped
  under a same-day "execution ledger" the agents used to track a swarm of
  concurrent fix PRs.
- Performance: moved meeting-prompt calendar queries and transcript-restyle
  analytics off the main actor; fixed hot-path latency, UI churn, and memory
  pressure across dictation and meetings; fixed a live-sidecar transcript
  scalability issue for long meetings.
- Security/privacy: added a forbidden-entitlement privacy guardrail and a
  post-DMG release-audit guardrail.
- Refactors: extracted a shared `TranscriptedCaptureKit` for CLI/MCP tooling,
  consolidated speaker vector math, deduped cross-boundary copy-paste flagged
  by a code audit, and extracted settings support views and a dictation-stop
  finalizer out of larger files.
- A large volume of internal PostHog telemetry landed: activation funnels,
  retention-cohort and habit-retention reports, friction analytics, release
  health by app version, an analytics-taxonomy guardrail (plus a merge-cascade
  fix for it), and a delivery-retry buffer for analytics events. None of this
  is user-visible.
- Testing: synthetic meeting-prompt suites, per-board QA accuracy scorecards,
  imported-audio QA smoke, UI-automation contract fixes (several rounds of
  flaky duplicate-binding fixes), and capture-format parser/format-sync
  hardening tests.
- Docs/process: refreshed release guardrails, agent/workflow orchestration
  guidance, and several product/UX audit docs (a June UX audit, an
  "abundance-mindset" product audit, a `CLAUDE.md` refresh, and a fix
  roadmap).

## Known Caveats

- **Version-number mismatch — read this first.** `v1.1.48` already shipped as
  a real GitHub release on June 13, 2026, and the live Sparkle appcast and
  Homebrew cask both still point at `1.1.48` today. That release covered only
  the first ~9 PRs after `1.1.47` (through the version-bump PR itself). The
  other ~290 PRs described in this document landed on `main` *after* that
  release, with no version bump since — `Info.plist` still reads `1.1.48`.
  This document is titled to match the current source string, but whoever
  actually builds the next candidate will need to pick and bump a real next
  version (likely `1.1.49` or later) — that decision does not belong to this
  document.
- **Five items look like they should be here but aren't merged yet.** As of
  this writing these are open PRs on `main`, not part of this candidate:
  - #1395 — meeting prompt detector polling/efficiency fix
  - #1400 — overlay placement and focus handling fix
  - #1403 — video meeting recording import support
  - #1404 — preserve dictation recovery audio
  - #1408 — feedback surface recovery UX fix

  If any of these are expected in the actual release, they need to merge
  first and this document needs updating.
- **The timeline/"Dayflow" work is scaffolding, not a feature.** Phases 0–2
  (planning, phase-0 scaffold, capture-engine skeleton, DB retention storage)
  are merged; phases covering QA hardening, a chat seam, a week dashboard,
  onboarding settings, and analytics are still open PRs. Someone needs to
  decide whether this ships partially, stays behind a flag, or waits for a
  later release before it's included in a real candidate.
- **This is a git-history and PR-description synthesis, not a line-by-line
  code review of all 298 merges.** I cross-checked the specific items named
  in the task against actual merge state (that's how the five open PRs above
  were caught) and spot-checked several PR descriptions for detail, but I
  cannot personally attest that every change here has been manually verified
  on real hardware/audio routes. Nothing in this document should be read as
  QA sign-off.
- CI on `main`'s current tip is green on the last completed, non-cancelled
  run. Several very recent runs show `cancelled` — that's newer merges
  superseding an in-flight run before it finished, not a failure.
- No appcast, Homebrew, or release-surface changes are made or proposed by
  this document. This is docs-only, consistent with `docs/release-guardrails.md`.

## Release Verification Reference

- `bash build-deps.sh --force`
- `bash build.sh --no-open`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash run-tests.sh`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash run-integration-smoke.sh`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test`
- `bash scripts/release/verify-sparkle-release.sh <actual-next-version>` —
  version not yet decided, see Known Caveats.
- `python3 scripts/ops/nightly-security-check.py --write-report <path>`
- `python3 scripts/release/post-dmg-release-audit.py` in read-only mode, per
  `docs/release-guardrails.md`.
- Confirm Sentry has no unresolved production issues scoped to whatever
  version tag this actually ships as.
- Confirm PostHog release-health snapshots show no new unrecovered failure
  clusters for meeting capture, dictation timeout-save, or speaker
  merge/un-merge.

## Manual QA Shrink

This checklist is a starting proposal built from what changed, not a report of
QA already performed — nobody has run it yet, and I have no way to confirm any
of this from a docs-only pass. Treat times as rough estimates. Run this only
once a real release candidate build exists:

1. Speaker merges, 3 minutes:
   - Merge two speaker profiles, then un-merge.
   - Pass: un-merge restores both speakers with their original clips intact,
     no data loss.
2. Dictation timeout + Bluetooth/AirPods route, 4 minutes:
   - Start a dictation on a Bluetooth/AirPods route, let it run past 5
     minutes.
   - Pass: dictation finalizes and saves instead of being discarded, and the
     audio engine doesn't loop/rebuild repeatedly on route changes.
3. Pasteback and Auto Enter, 3 minutes:
   - Dictate into a slow-to-accept target app with Auto Enter on, then off.
   - Pass: fresh text pastes (no stale clipboard), a visible confirmation
     state appears for Auto Enter, and it only fires in the intended target.
4. Hotkey recovery, 2 minutes:
   - Trigger the dictation/meeting hotkey repeatedly, including after the Mac
     wakes from sleep or after another app grabs focus.
   - Pass: the hotkey keeps firing reliably; no dead hotkey state.
5. Meeting capture failure recovery, 5 minutes:
   - Force-quit Transcripted mid-meeting-recording, then relaunch.
   - Pass: the orphaned recording is recovered/salvaged rather than showing
     as a zero-length or missing file.
6. Screen-share privacy, 2 minutes:
   - Start a meeting recording and the live overlay, then share your screen
     in a video call.
   - Pass: Transcripted's overlay and app windows do not appear in the shared
     screen.
7. Home redesign smoke, 4 minutes:
   - Browse Home, use the meeting-list filter and in-transcript find, rename a
     meeting, delete a meeting.
   - Pass: all actions work from the redesigned layout with no dead menu
     items or stale confirmations.
8. Update prompt, 2 minutes:
   - Trigger a Sparkle update check against a build with a pending update.
   - Pass: the prompt clearly states a specific version is available and
     reads unambiguously as "update available."
9. Accessibility spot check, 3 minutes:
   - Enable VoiceOver and Reduce Motion, navigate onboarding, Home, and the
     meeting overlay.
   - Pass: controls are labeled, animations are suppressed, and tap targets
     are usable.

Capture one evidence row per item: pass/fail, app/route, and a screenshot or
`events.jsonl` reference where relevant. Block this candidate if any item
fails, and re-run once the five open PRs in Known Caveats are resolved one way
or the other.
