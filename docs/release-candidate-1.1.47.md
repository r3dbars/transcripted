# Transcripted 1.1.47 Release Candidate Notes

Status: draft candidate prep only. Do not publish from this file alone.

Current shipped version remains `1.1.46`. `Info.plist`, `docs/appcast.xml`,
`Casks/transcripted.rb`, and the live download website should stay on `1.1.46`
until a real `1.1.47` release artifact is approved, built, published, and
verified.

## Candidate Summary

This candidate would focus on meeting-audio reliability and recovery after
`1.1.46`, especially quiet-mic/attenuation handling and long-meeting retry
visibility.

## User-Visible Changes

- Preserve retry audio for long meetings so failed long recordings have a better
  chance of showing up for recovery.
- Avoid prompting to record Zoom app-only activity when it is not a real meeting.
- Give meeting prompts a longer window before timing out.
- Clarify the dictation model-loading overlay while local speech models prepare.
- Improve delayed dictation paste-back when the target app is slow to accept text.

## Reliability And Ops Changes

- Fix a meeting mic downmix path that could make one-sided or uneven channel
  input too quiet.
- Improve realtime mic gain recovery for quiet meeting input.
- Add issue 500 guardrail tests around downmix and meeting mic recovery.
- Add clipboard restore wait guardrails.
- Count activation events in health probes so the release read can see first-value
  progress more clearly.
- Refresh agent workflow docs and preflight guidance for repo workers.

## Known Caveats

- `1.1.46` is still a recent release, published on June 3, 2026.
- The issue 500 fixes need real route coverage after shipping, especially USB
  and Bluetooth output routes.
- Open issues #500 and #825 remain open until the fixes are validated in use.
- This file does not update Sparkle or Homebrew. Existing installs will not see a
  `1.1.47` update until a real release artifact exists and the appcast is updated.

## Suggested Verification Before Publish

- `bash build-deps.sh --force`
- `bash build.sh`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash run-tests.sh`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash run-integration-smoke.sh`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test`
- `bash scripts/release/verify-sparkle-release.sh 1.1.46`
- `python3 scripts/ops/nightly-security-check.py --write-report <path>`
- Confirm Sentry has no unresolved production issues scoped to
  `transcripted@1.1.46`.
- Confirm PostHog latest-release meeting health snapshots do not show unrecovered
  quiet mic or output-ducking clusters.
