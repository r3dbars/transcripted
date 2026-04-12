# API

## Current status

`Sources/API/` currently contains only beta-build configuration.

## Important file

- `BetaConfig.swift` — `#if BETA_BUILD` constants for proxy token, proxy base URL, app version, and update URL

## Notes

- the core dictation and meeting flows do not depend on a live app-side API client here
- networked beta behavior lives mostly in `Sources/Observability/`
- older docs mentioning `GeminiEngine`, keychain helpers, or chat-drafting HTTP paths do not match the current tree
