# API directory

## Current status

`Sources/API/` currently contains only `BetaConfig.swift`.

The older `GeminiEngine` / `KeychainHelper` documentation that used to live here does not match the current tree on `main`.

## Current file

- `BetaConfig.swift` — `#if BETA_BUILD` constants for the beta proxy token and proxy base URL

## Agent notes

- Core dictation and meeting flows on `main` do not depend on a live app-side API client in this directory.
- The current app no longer consumes `/config`-driven version/update fields from the archived beta worker.
- If you need network or beta-backend context, read `archive/backend-beta-worker/README.md` and the beta-only files under `Sources/Observability/`.
- Verify any old references to `GeminiEngine`, API keys, or chat-drafting HTTP paths against the actual source tree before changing code.
