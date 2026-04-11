# Transcripted in `r3dbars/transcripted`

## What this repo is

`main` is the current Transcripted app: a local macOS menu bar app for:

- dictation
- meeting capture and transcription

The older drafting / ghostwriting flow is not the active product path here.
Compatibility stubs remain in a few places, but they are not the center of the
runtime.

## First reads

1. `README.md`
2. `AGENTS.md`
3. `docs/agent-onboarding.md`
4. `docs/storage-paths.md`
5. `Sources/CLAUDE.md`
6. `Sources/Dictation/CLAUDE.md`
7. `Sources/Meeting/CLAUDE.md`
8. `Sources/TranscriptedCore/CLAUDE.md`
9. `Sources/Reliability/CLAUDE.md`
10. `Tests/README.md`

## Build and test

```bash
bash build-deps.sh
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
swift test
```

Rules:

1. After changing Swift source, run `bash build.sh` and `bash run-tests.sh`.
2. If you change `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run `bash run-integration-smoke.sh`.
3. If you change `Package.swift` or the public `TranscriptedCore` seam, also run `swift test`.
4. `Sources/TranscriptedCore/` is a library boundary. Do not compile it directly into the app target.

## Current architecture

- `Sources/TranscriptedApp.swift` wires the menu bar app, overlays, popover, onboarding, and detected-meeting prompts.
- `Sources/TranscriptedAppState.swift` owns shared runtime services: `ContextCaptureEngine`, `STTRouter`, wake recovery, and the lazy `MeetingSessionController`.
- `Sources/UI/DictationSessionController.swift` handles dictation orchestration only; removed draft-mode entry points now surface a fixed message.
- `Sources/Meeting/` adapts app-owned pieces like `ParakeetEngine`, capture storage, and UI state into `TranscriptedCore`.
- `Sources/TranscriptedCore/` contains the reusable meeting transcription pipeline.
- `Tools/TranscriptedMCP/` and `Tools/TranscriptedCLI/` expose saved captures outside the app.

## Storage reality

Transcripted now separates user captures from app-owned state.

Default root:

- `~/Library/Application Support/Transcripted/`

Default captures:

- `~/Library/Application Support/Transcripted/captures/meetings/`
- `~/Library/Application Support/Transcripted/captures/dictations/`

App-owned state:

- `~/Library/Application Support/Transcripted/state/`
- `~/Library/Application Support/Transcripted/cache/`
- `~/Library/Application Support/Transcripted/logs/`
- `~/Library/Application Support/Transcripted/tmp/recordings/`

The capture library can be relocated in Settings. Legacy `Draft` and
`~/Documents/Transcripted` paths are compatibility inputs for some tools, not
the default app layout on `main`.

## Documentation status

Repo-level and local `CLAUDE.md` files are intended to match the live tree.
Historical planning and merge material lives under `docs/archive/`.
