# API directory

## Current status

`Sources/API/` currently contains only `BetaConfig.swift`.

The older `GeminiEngine` / `KeychainHelper` documentation that used to live here does not match the current tree on `main`.

## Current file

- `BetaConfig.swift` — `#if BETA_BUILD` constants for the beta proxy token, proxy base URL, app version, and update URL

## Agent notes

- Core dictation and meeting flows on `main` do not depend on a live app-side API client in this directory.
- If you need network or beta-backend context, read `backend/README.md` and the beta-only files under `Sources/Observability/`.
- Verify any old references to `GeminiEngine`, API keys, or chat-drafting HTTP paths against the actual source tree before changing code.
