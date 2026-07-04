# Timeline

## What This Directory Owns

`Sources/Timeline/` owns the Dayflow-style timeline engine: capture plumbing
(screenshot cadence, display selection, foreground-app metadata, idle
snapshots, local screenshot writes, and pause/resume state exposed for future
UI), the app-owned timeline database and storage-cap retention cleanup, and
projection logic that joins saved meeting/dictation artifacts into timeline
card records. It is app-side code, not part of `Sources/TranscriptedCore/`.

## Files

- `ScreenCaptureEngine.swift` - serial-queue capture loop, state machine, local JPEG writer, and `TimelineEngineController`
- `ActiveDisplayTracker.swift` - display selection and even-dimension scaling helpers
- `InputIdleSnapshot.swift` - local input-idle sampling
- `ForegroundAppSampler.swift` - frontmost app plus best-effort window title
- `TimelineDatabase.swift` - raw SQLite3 storage for screenshots, batches, observations, timeline cards, LLM call logs, and future timeline chat rows
- `TimelineRetentionManager.swift` - storage-cap cleanup for timeline screenshots
- `TimelineDayBoundary.swift` - 4 AM logical-day assignment.
- `TimelineCaptureJoiner.swift` - projects saved meeting and dictation artifacts
  into timeline card records without changing the capture source of truth.

## Guardrails

- Screenshots and screen-derived metadata stay local.
- Do not send app names, window titles, screenshot paths, OCR text, or screen content to Sentry/PostHog.
- Keep ScreenCaptureKit work off the main thread.
- Fast tests must stay deterministic and must not require Screen Recording permission.
- Keep timeline state under `~/Library/Application Support/Transcripted/`.
- Keep screenshots in app-owned storage, not the relocatable capture library.
- Keep human/agent-readable timeline Markdown in the capture library when that future phase exists.
- Do not put timeline code in `Sources/TranscriptedCore/`; Core remains the meeting transcription library boundary.
- Meeting and dictation Markdown remain the source of truth; timeline rows are projections and must tolerate missing, moved, or renamed artifacts.
- Do not change meeting capture or dictation save behavior from this subsystem.
- UI, analysis, cards, OCR, and LLM providers belong to later phases.

## Verify

```bash
python3 scripts/dev/check-build-source-lists.py
bash build.sh --no-open
bash run-tests.sh
```
