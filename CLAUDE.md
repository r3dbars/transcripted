# Draft in `r3dbars/transcripted`

## What This Repo Is

This public repo now carries the **Draft** product on `main` while preserving the
old standalone Transcripted app on:

- tag: `pre-draft-takeover-2026-04-06`
- branch: `legacy/transcripted-standalone`

`main` is Draft-first. The legacy Transcripted app does **not** live on `main`.

## High-Level Layout

```
Sources/
├── DraftApp.swift
├── DraftAppState.swift
├── DraftPaths.swift
├── DraftConstants.swift
├── HotkeyPreferences.swift
├── API/
├── Accessibility/
├── Analysis/
├── Capture/
├── Dictation/
├── Draft/
├── Feedback/
├── Local/
├── Meeting/
├── Observability/
├── Prompts/
├── Speech/
├── Style/
├── TranscriptedCore/    ← shared meeting/transcription core kept in-repo
└── UI/
Tests/
SmokeTests/
backend/
build.sh
build-deps.sh
run-tests.sh
run-integration-smoke.sh
Package.swift            ← SPM package for TranscriptedCore smoke tests only
```

## Build and Test

```bash
bash build-deps.sh
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
```

Rules:

1. After changing Swift source, run `bash build.sh` and `bash run-tests.sh`.
2. If you change `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run `bash run-integration-smoke.sh`.
3. `build.sh` builds the Draft app.
4. `Package.swift` exists only so `Sources/TranscriptedCore/` can still be tested as a standalone library surface.

## TranscriptedCore

`Sources/TranscriptedCore/` is the shared meeting/transcription core extracted from
Transcripted and now co-hosted in this repo. Draft consumes it through
`Sources/Meeting/`.

Important implications:

1. `Sources/TranscriptedCore/` is a library boundary. Do not couple it to Draft UI types.
2. `build.sh` must **not** compile `Sources/TranscriptedCore/` directly into the Draft app target.
3. `build-deps.sh` builds a unified dependency archive and inlines `TranscriptedCore` from this repo when present.

## Cutover Notes

This repo takeover uses the **manual migration** path:

- existing Transcripted installs do **not** auto-upgrade into Draft
- Draft remains `com.justinbetker.draft`
- old Transcripted release/update plumbing is intentionally disabled on `main`

If you need the old standalone Transcripted app, use the legacy branch or tag above.
