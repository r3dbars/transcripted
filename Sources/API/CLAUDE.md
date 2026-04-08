# API Directory — Beta Build Configuration

## What This Directory Is

On current `main`, this directory is small and beta-only.

It does **not** hold the active drafting/runtime API implementation. The main
app is local-first for dictation and meetings. This directory currently exists
to hold `BETA_BUILD` configuration that points beta-only code at the backend
worker.

## Current Files

- `BetaConfig.swift`
  Baked-in beta constants such as the per-user token placeholder, proxy base
  URL, and app version string.

## How It Fits Together

- `Sources/API/BetaConfig.swift` provides compile-time constants for beta code
  paths.
- `backend/src/index.ts` implements the worker those paths talk to.
- Local dictation and local meeting transcription do not depend on this
  directory in non-beta builds.

## Important Constraints

- treat this directory as beta/distribution plumbing, not core product logic
- keep `#if BETA_BUILD` boundaries intact for beta-only settings
- if you change any backend contract value here, verify the corresponding
  behavior in `backend/CLAUDE.md` and `backend/src/index.ts`

## Verification

After modifying files in this directory:

```bash
bash build.sh
bash run-tests.sh
```

For beta-specific contract changes, also inspect:

```bash
sed -n '1,260p' backend/src/index.ts
```
