# Draft in `r3dbars/transcripted`

## Repo Truth

`main` is the **Draft** product.

The old standalone Transcripted app is preserved on:

- `legacy/transcripted-standalone`
- `pre-draft-takeover-2026-04-06`

Do not treat `main` as a dual-app repo.

## Main Areas

- `Sources/` — Draft app code
- `Sources/Meeting/` — Draft-to-TranscriptedCore bridge
- `Sources/TranscriptedCore/` — shared meeting/transcription library
- `Tests/` — Draft fast test suite
- `SmokeTests/` — TranscriptedCore integration smoke
- `backend/` — Draft beta backend

## Build Commands

```bash
bash build-deps.sh
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
```

Rules:

1. After changing Swift source, run `bash build.sh` and `bash run-tests.sh`.
2. If you touch `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run `bash run-integration-smoke.sh`.
3. `build.sh` builds the Draft app only.
4. `Sources/TranscriptedCore/` must stay a library boundary; do not compile it directly into the Draft app target.

## Migration Assumption

This repo takeover uses the **manual migration** path:

- existing Transcripted installs do not auto-upgrade into Draft
- Draft remains `com.justinbetker.draft`
- legacy Transcripted update/release plumbing is intentionally not active on `main`
