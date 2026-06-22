# Transcripted Unknown Proof Checklist

This checklist tracks the 50 user stories that were still `UNKNOWN` after the
feature/user-story matrix pass on 2026-06-21.

Use synthetic speech and privacy-safe notes only. Do not record transcript text,
audio references, meeting titles, speaker names, raw paths, raw URLs, device
names, emails, tokens, or identities in this file or the matrix.

Status key:

- `[ ]` not proven yet
- `[x]` proven enough to update the matrix to `PASS` or `RETEST PASS`
- `[!]` attempted, still manual-only or blocked by the local environment

## App UI And File Pickers

- [!] Row 6: Menu Bar / Import audio entry point - prove native file picker and real audio import UX.
- [!] Row 20: Home / Open and reveal saved artifacts - prove Finder/open behavior in app.
- [!] Row 21: Home / Delete meeting confirmation - prove actual menu/alert interaction.
- [!] Row 22: Home / Rename meeting artifact - prove real row title edit UX.
- [!] Row 23: Home / Failed meeting recovery row - prove real failed-row actions.
- [!] Row 44: Settings / Storage relocation - prove real folder picker and migration/relocation UX.
- [!] Row 46: Settings / Transcription model selection - prove actual model download/cache/use.
- [!] Row 48: Settings / Launch at login - prove macOS login item registration.
- [!] Row 49: Settings / Quit safety - prove real app quit while recording.
- [!] Row 50: Agent Integration / Connect agents to captures - prove real local agent config writes.
- [!] Row 52: Support / Feedback and diagnostics - prove real copied diagnostics UI.
- [!] Row 54: Privacy / Local-first capture boundary - prove Settings privacy toggles visible.
- [!] Row 56: Observability / Crash reporting toggle - prove Settings toggle and Send Test Sentry Event with configured DSN.
- [!] Row 57: Observability / Anonymous analytics toggle - prove Settings toggle visibility.
- [!] Row 59: Updates / Check for updates - prove real Sparkle update check/install without publishing anything.

## Dictation And Pasteback

- [!] Row 7: Dictation / Start and stop dictation - prove real microphone and spoken dictation.
- [!] Row 8: Dictation / Push-to-talk trigger - prove physical key timing on macOS.
- [!] Row 9: Dictation / Hands-free trigger - prove physical trigger feel.
- [!] Row 10: Dictation / Paste-last-dictation shortcut - prove real focused-app paste behavior.
- [!] Row 11: Dictation / No-speech handling - prove real short/silent recording UX.
- [!] Row 14: Dictation / Waveform and overlay state - prove real overlay placement and animation.
- [!] Row 16: Dictation / Auto Enter after paste - prove real target-app send behavior.
- [!] Row 17: Pasteback / Clipboard-safe paste - prove real TextEdit/Notes/browser/Obsidian paste feel.
- [!] Row 18: Pasteback / Focused editor fallback - prove real AX permission and secure-field behavior.
- [!] Row 71: Pasteback / Secure input fallback - prove real secure/password field behavior.

## Meetings And Audio

- [!] Row 24: Meetings / Detected meeting prompt - prove real Calendar and meeting-app behavior.
- [x] Row 25: Meetings / Meeting permission preflight - current-grant permission status and onboarding permission UI passed; deny/regrant/revoke stays separate on row 79.
- [x] Row 26: Meetings / Start and stop live meeting recording - direct live mic plus system-audio capture smoke passed on this Mac.
- [!] Row 27: Meetings / Cancel/discard recording - prove real overlay discard confirmation.
- [!] Row 28: Meetings / Queued transcription state - prove real long transcription UI.
- [!] Row 29: Meetings / Imported audio transcription - prove real imported media files through UX.
- [!] Row 30: Meetings / Retained meeting audio - prove real playback from retained audio.
- [!] Row 31: Meetings / Meeting transcript Markdown - prove real saved meeting from app capture.
- [!] Row 32: Meetings / Failure and retry - prove real failed-transcription retry from app UI.
- [!] Row 33: Meetings / Quiet mic and mic boost prompt - prove real quiet mic/WebRTC behavior.
- [!] Row 34: Meetings / Audio inactivity warning - prove real live levels in a quiet meeting.
- [!] Row 35: Meetings / Audio route recovery - prove real Bluetooth/AirPods/USB/monitor route churn.
- [!] Row 36: Meetings / Live meeting sidecar - prove real live sidecar during active recording.
- [!] Row 74: Meetings / Discard/save race safety - prove real fast user stop/discard interaction.
- [!] Row 78: Meetings / Meeting prompt false positives - prove real apps/media/browser negative cases.

## Speaker Names And Summaries

- [!] Row 37: Speaker Names / Default speaker safety - prove real multi-speaker audio identity quality.
- [!] Row 38: Speaker Names / Post-meeting speaker review - prove full review sheet UI and audio clip playback.
- [!] Row 39: Speaker Names / Keep local mic as You - prove real review UI behavior.
- [!] Row 40: Speaker Names / People settings manage speakers - prove real People page UI and persisted DB changes.
- [!] Row 41: Speaker Names / Retroactive speaker updates - prove real old-transcript update flow from UI.
- [!] Row 42: Local Summary / Opt-in local meeting summaries - deterministic fixture passed, but real local model runtime is still unproven because `mlx` / `mlx_vlm` are not installed in this Python environment.

## Permissions And Recovery

- [!] Row 60: Reliability / Wake recovery - prove real sleep/wake with hotkeys and capture.
- [!] Row 61: Reliability / Dictation audio recovery - prove real bad route/noisy mic recovery.
- [!] Row 62: Reliability / Recording journal and relaunch recovery - prove crash/relaunch during active recording.
- [!] Row 79: Onboarding / Permission denial and revoke paths - current grants are ready, but real deny/regrant/revoke still needs manual TCC manipulation; System Events Automation probe warned with OSStatus -600.

## Proof Log

- 2026-06-21: Checklist created from the 50 `UNKNOWN` rows in
  `docs/qa/transcripted-feature-user-story-matrix.csv`.
- 2026-06-21: Fresh live bench `qa-20260621-202408` passed build, fast tests,
  E2E, pasteback synthetic, local summary fixture, integration, Core `swift
  test`, QA CLI tests, artifact checks, synthetic audio, release-health fixture,
  and PostHog fixture, but stayed `INCOMPLETE` because System Events Automation
  warned and live smoke was skipped by the bench preflight.
- 2026-06-21: Direct `bash run-live-capture-smoke.sh --skip-build` passed
  `LiveCaptureSmokeTests`, proving real mic plus system-audio capture start/stop
  and scratch-file output on this Mac.
- 2026-06-21: UI bench `qa-20260621-202731` passed onboarding, menu bar, Home,
  Settings navigation, and General controls. Same-second temp run-id collision
  also includes a passing pasteback-synthetic log in that artifact directory.
- 2026-06-21: Artifact bench `qa-20260621-202732` passed health and current
  artifact validation cleanly.
- 2026-06-21: Remaining unchecked rows were reclassified from `UNKNOWN` to
  `BLOCKED` with concrete blocker reasons. This removes ambiguity without
  counting manual/hardware/native-app proof as passed. Final matrix status:
  `PASS` 29, `RETEST PASS` 3, `BLOCKED` 48, `UNKNOWN` 0.
