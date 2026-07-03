# Timeline Directory

## What this directory does

`Sources/Timeline/` owns the non-UI timeline engine for the future Dayflow-style
Transcripted timeline. This subsystem will capture screen-activity snapshots,
store app-owned timeline state, analyze activity locally first, and project
meetings and dictations into one day view.

Phase 0 is scaffolding only. Do not add capture, database, scheduler, or LLM
runtime code here until the matching implementation phase.

## Planned files

- `ScreenCaptureEngine.swift` — future ScreenCaptureKit screenshot loop and pause/resume state machine
- `TimelineEngineController.swift` — future main-actor facade owned by app state
- `TimelineDatabase.swift` — future raw SQLite3 app-state store under Application Support
- `TimelineRetentionManager.swift` — future storage-cap and screenshot cleanup policy
- `AnalysisScheduler.swift` — future off-main analysis scheduler
- `BatchPlanner.swift` — future pure batching rules
- `ObservationBuilder.swift` — future local OCR/app metadata observation builder
- `CardGenerator.swift` — future activity-card generation and validation
- `TimelineLLMProvider.swift` — future provider protocol and shared provider plumbing
- `TimelineCaptureJoiner.swift` — future meeting/dictation projection into timeline entries
- `TimelineMarkdownWriter.swift` — future daily timeline Markdown writer
- `TimelineDayBoundary.swift` — future 4 AM logical-day helper

## Current notes

- Keep this directory engine-only. UI belongs in `Sources/UI/Timeline/`.
- Keep `Sources/TranscriptedCore/` out of this feature; timeline state is app-owned.
- Screenshot capture, encoding, SQLite writes, and LLM work must run off the main thread.
- Screen-derived text and images stay local unless the user explicitly opts into a cloud timeline provider.

## Verification

After changing timeline source:

```bash
bash build.sh --no-open
bash run-tests.sh
```
