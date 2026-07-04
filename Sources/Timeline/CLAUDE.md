# Timeline

## What This Directory Owns

`Sources/Timeline/` owns the Dayflow-style timeline engine: capture plumbing
(screenshot cadence, display selection, foreground-app metadata, idle
snapshots, local screenshot writes, and pause/resume state exposed for future
UI), the app-owned timeline database and storage-cap retention cleanup,
deterministic analysis seams (batching, observation building, card
generation, category normalization, provider stubs, and scheduling),
projection logic that joins saved meeting/dictation artifacts into timeline
card records, pure weekly aggregation helpers, and local-first read-only
chat tools over timeline cards, observations, meeting Markdown, and vetted
SQL. It is app-side code, not part of `Sources/TranscriptedCore/`, and
should stay off-main for capture, analysis, and database work, and UI-free.
Chat should ask the timeline store for already-derived cards and summaries
instead of reading raw screenshots.

## Files

- `ScreenCaptureEngine.swift` - serial-queue capture loop, state machine, local JPEG writer, and `TimelineEngineController`
- `ActiveDisplayTracker.swift` - display selection and even-dimension scaling helpers
- `InputIdleSnapshot.swift` - local input-idle sampling
- `ForegroundAppSampler.swift` - frontmost app plus best-effort window title
- `TimelineDatabase.swift` - raw SQLite3 storage for screenshots, batches, observations, timeline cards, LLM call logs, and future timeline chat rows
- `TimelineRetentionManager.swift` - storage-cap cleanup for timeline screenshots
- `TimelineModels.swift` - shared screenshots, observations, cards, and provider metadata
- `TimelineDayBoundary.swift` - 4 AM logical-day assignment
- `BatchPlanner.swift` - pure screenshot batching rules
- `ObservationBuilder.swift` - observation-building protocol seam and text condenser
- `CardGenerator.swift` - pure card validation and normalization rules
- `TimelineCategoryStore.swift` - category defaults and normalization
- `TimelineLLMProvider.swift` - provider protocol and safe inert stubs
- `AnalysisScheduler.swift` - single-flight in-memory scheduler harness for the pure pipeline
- `TimelineCaptureJoiner.swift` - projects saved meeting and dictation artifacts into timeline card records without changing the capture source of truth
- `WeeklyStatsBuilder.swift` - pure weekly aggregation helpers used by the week grid and dashboard sample/protocol views
- `TimelineChatModels.swift` - shared value types for chat context, messages, tools, and privacy mode
- `ChatToolExecutor.swift` - read-only tool dispatch plus SQL guardrails
- `ChatPromptBuilder.swift` - local prompt assembly and cloud privacy gate
- `ChatService.swift` - small orchestration seam for provider-backed chat answers

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
- Keep screenshots, OCR text, app names, URLs, and window titles local unless a later user-facing preference explicitly enables a cloud provider.
- Provider stubs must not make network calls by default.
- Pure rules need fast tests before being wired into capture, storage, or UI.
- Keep analytics-facing values bucketed or enum-like. Raw titles, transcript text, app names, URLs, file paths, and screenshot-derived text stay local UI data only.
- Do not send screenshot text, app/window titles, transcript text, or timeline summaries to a cloud provider unless the user has explicitly accepted the cloud notice for the configured provider.
- SQL tooling is read-only. Keep the statement vetting strict.
- UI, cards-facing OCR, and full LLM provider wiring belong to later phases.

## Verify

```bash
python3 scripts/dev/check-build-source-lists.py
bash build.sh --no-open
bash run-tests.sh --filter TimelineAnalysis
bash run-tests.sh
```
