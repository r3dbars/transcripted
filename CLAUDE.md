# Transcripted in `r3dbars/transcripted`

## What This Repo Is

`main` builds the current **Transcripted** macOS menubar app:

- dictation
- meeting capture and transcription
- local transcript artifacts for agent workflows

The codebase still contains many `Draft*` symbols and file names. Those are compatibility leftovers from the takeover, not a second product line inside this branch.

Legacy standalone references live on:

- branch: `legacy/transcripted-standalone`
- tag: `pre-draft-takeover-2026-04-06`

## High-Level Layout

```text
Sources/
|- DraftApp.swift                 <- @main app entry
|- DraftAppState.swift           <- shared engine ownership
|- DraftPaths.swift              <- Application Support paths + compatibility alias
|- DraftConstants.swift
|- HotkeyPreferences.swift
|- Accessibility/
|- API/                          <- beta-only config
|- Capture/                      <- Carbon hotkeys + right-option dictation tap
|- Dictation/                    <- dictation storage + markdown writer
|- Draft/                        <- pure diff/refusal helpers
|- Meeting/                      <- Transcripted ↔ TranscriptedCore bridge
|- Observability/                <- debug log, JSONL events, beta telemetry, updates
|- Reliability/                  <- wake recovery
|- Speech/                       <- Parakeet STT + router
|- Style/                        <- pure style helper utilities
|- TranscriptedCore/             <- shared transcription/diarization library
`- UI/                           <- floating dictation overlay, meeting overlay, menubar UI
Tests/
SmokeTests/
Tools/TranscriptedQA/
Tools/TranscriptedMCP/
backend/
build-deps.sh
build.sh
run-tests.sh
run-integration-smoke.sh
Package.swift
```

## Build And Test

```bash
bash build-deps.sh
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
swift test
```

Rules:

1. Run `bash build.sh` and `bash run-tests.sh` after Swift changes.
2. Also run `bash run-integration-smoke.sh` for changes in `Sources/Meeting/`, `Sources/TranscriptedCore/`, or `Sources/Reliability/`.
3. `build.sh` compiles the app from `Sources/` while excluding `Sources/TranscriptedCore/`.
4. `Package.swift` and `swift test` cover the standalone `TranscriptedCore` library surface.

## Current Product Shape

- Dictation is the active overlay flow.
- Meetings run through `MeetingSessionController` plus a separate non-activating meeting overlay.
- The old screenshot-to-draft workflow is no longer the live product path; some compatibility code and naming remain.
- Several folders such as `Sources/Analysis/`, `Sources/Feedback/`, `Sources/Local/`, and `Sources/Prompts/` are currently placeholders/documentation-only rather than active subsystems.

## Paths And Boundaries

- Fresh installs use `~/Library/Application Support/Transcripted/`.
- If `~/Library/Application Support/Draft/` already exists, `DraftPaths.swift` keeps using it.
- Meeting artifacts are isolated under `.../meetings/`.
- Dictation artifacts are isolated under `.../dictations/`.
- `Sources/TranscriptedCore/` must stay a library boundary. App-facing UI types should not leak into it.

## Tooling Notes

- `Tools/TranscriptedQA` is a separate Swift package for artifact/database validation.
- `Tools/TranscriptedMCP` is a separate Swift package that serves transcript data over MCP.
- `build-deps.sh` builds the unified dependency archive used by both the app and the co-hosted `TranscriptedCore` library surface.
