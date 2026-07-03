# Timeline

## What This Directory Owns

`Sources/Timeline/` owns the Dayflow-style timeline engine. Phase 1 is capture
plumbing only: screenshot cadence, display selection, foreground-app metadata,
idle snapshots, local screenshot writes, and the pause/resume state exposed for
future UI.

## Files

- `ScreenCaptureEngine.swift` - serial-queue capture loop, state machine, local JPEG writer, and `TimelineEngineController`
- `ActiveDisplayTracker.swift` - display selection and even-dimension scaling helpers
- `InputIdleSnapshot.swift` - local input-idle sampling
- `ForegroundAppSampler.swift` - frontmost app plus best-effort window title

## Guardrails

- Screenshots and screen-derived metadata stay local.
- Do not send app names, window titles, screenshot paths, OCR text, or screen content to Sentry/PostHog.
- Keep ScreenCaptureKit work off the main thread.
- Fast tests must stay deterministic and must not require Screen Recording permission.
- UI, analysis, cards, OCR, LLM providers, and SQLite belong to later phases.

## Verify

```bash
python3 scripts/dev/check-build-source-lists.py
bash build.sh --no-open
bash run-tests.sh
```
