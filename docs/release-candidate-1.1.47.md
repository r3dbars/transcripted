# Transcripted 1.1.47 Release Candidate Notes

Status: shipped. GitHub release `v1.1.47` is published, and source release
metadata now points at `1.1.47`.

These notes are kept as the pre-release candidate record. Treat the published
release metadata and `git` history as source of truth for what actually shipped.

## Candidate Summary

This candidate would focus on meeting-audio reliability, recovery, and speaker
identity trust after `1.1.46`, especially quiet-mic/attenuation handling,
long-meeting retry visibility, and the reported speaker-collapse fix.

## User-Visible Changes

- Preserve retry audio for long meetings so failed long recordings have a better
  chance of showing up for recovery.
- Avoid prompting to record Zoom app-only activity when it is not a real meeting.
- Give meeting prompts a longer window before timing out.
- Clarify the dictation model-loading overlay while local speech models prepare.
- Improve delayed dictation paste-back when the target app is slow to accept text.
- Keep weak ghost-speaker matches as separate reviewable speakers instead of
  collapsing them into the nearest existing voice.

## Reliability And Ops Changes

- Fix a meeting mic downmix path that could make one-sided or uneven channel
  input too quiet.
- Improve realtime mic gain recovery for quiet meeting input.
- Add a minimum similarity floor for ghost-speaker auto-merge so low-confidence
  diarization fragments do not collapse distinct speakers.
- Add issue 500 guardrail tests around downmix and meeting mic recovery.
- Add regression coverage for the ghost-speaker merge floor.
- Add clipboard restore wait guardrails.
- Count activation events in health probes so the release read can see first-value
  progress more clearly.
- Refresh agent workflow docs and preflight guidance for repo workers.

## Known Caveats

- `1.1.46` was the previous release, published on June 3, 2026.
- The issue 500 fixes need real route coverage after shipping, especially USB
  and Bluetooth output routes.
- The speaker-collapse fix is in this candidate, but support should not tell
  affected users it shipped unless the user is on `1.1.47` or newer.
- Open issues #500 and #825 remain open until the fixes are validated in use.
- The `1.1.47` appcast entry and Homebrew cask metadata are now committed.

### 2026-07-03 status update

Both GitHub issues are now closed (#500 closed 2026-06-12, #825 closed
2026-06-12 — the latter auto-closed by the merge of PR #1074, not by an
explicit human confirmation that the bigger follow-up work was done). Closure
is not the same as real-world validation; see
[`docs/qa-issue-500-meeting-audio.md`](qa-issue-500-meeting-audio.md) and
[`docs/issue-825-long-meetings-investigation-2026-06-11.md`](issue-825-long-meetings-investigation-2026-06-11.md)
for the current, honest read on each: real hardware/manual QA is still
outstanding for both, even though the core architectural fixes have now had
about three weeks of real usage in `v1.1.48` (released 2026-06-13) with no
reopened reports.

## Release Verification Reference

- `bash build-deps.sh --force`
- `bash build.sh --no-open`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash run-tests.sh`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash run-integration-smoke.sh`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test`
- `bash scripts/release/verify-sparkle-release.sh 1.1.47`
- `python3 scripts/ops/nightly-security-check.py --write-report <path>`
- Confirm Sentry has no unresolved production issues scoped to
  `transcripted@1.1.47`.
- Confirm PostHog latest-release meeting health snapshots do not show unrecovered
  quiet mic or output-ducking clusters.

## Manual QA Shrink

Run this only after the release-candidate build and automated gate are ready.
Keep the pass short and use synthetic speech only:

```text
Transcripted release QA test one two three.
```

1. Pasteback feel, 2 minutes:
   - Dictate into Notes or TextEdit, then a browser text area.
   - Try Auto Enter off, then on in the safe text area.
   - Pass: fresh text appears, no stale clipboard paste, and Auto Enter only
     fires in the intended target.
2. Real WebRTC route, 4 minutes:
   - Run Chrome Meet with built-in mic and speakers.
   - Start meeting recording, speak the phrase, play meeting or system audio,
     then stop.
   - Pass: the meeting stays audible, saved Markdown exists, mic audio is
     usable, and system audio is present or clearly unavailable.
3. Zoom plus AirPods/Bluetooth route, 4 minutes:
   - Run Zoom with AirPods or a Bluetooth route.
   - Repeat the short recording.
   - Pass: output does not get quieter, recording stops cleanly, saved Markdown
     exists, and a second attempt works if route settling delays the first.
4. Local Gemma beta workflow, 3-5 minutes:
   - On the saved synthetic meeting, enable the beta summary path and trigger a
     summary from Home.
   - Pass: the UI stays responsive, the summary attaches to the right meeting,
     Markdown is not corrupted, and any missing-model/runtime failure is clear.

Capture one short evidence row for each item: pass/fail, app and route, saved
Markdown path, screenshot if useful, and relevant `events.jsonl` fields such as
`mic_processed_peak`, `system_peak`, volume before/during/after, and
`output_ducking_detected`.

This checklist intentionally stays smaller than the full issue 500 matrix. The
automated gate already covers build/tests, E2E artifacts, synthetic slow
pasteback, local summary fixture shape, mocked meeting-route fixtures, mocked
Bluetooth/AirPods contracts, permission-state gates, UI harness, and release
reporting.

Block `1.1.47` if any real meeting gets quieter, Zoom/WebRTC lacks usable saved
audio or Markdown, AirPods/Bluetooth gets stuck, pasteback inserts stale text or
Auto Enter fires in the wrong target, or Gemma corrupts the wrong transcript or
freezes Home.

If follow-up QA automation PRs merge before the release candidate is built,
rerun the release-candidate gate, but keep this same human checklist unless one
of those PRs changes release packaging or the user-facing manual flow itself.
