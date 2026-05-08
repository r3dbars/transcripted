# Beta

## Current status

`Sources/Beta/` currently contains only beta-build token configuration.

## Important file

- `BetaConfig.swift` — `#if BETA_BUILD` token placeholder replaced by `build-beta.sh`

## Notes

- the core dictation and meeting flows do not depend on a live app-side API client here
- the current app no longer consumes `/config`-driven version or update fields from the archived beta worker
- if you need beta distribution or backend context, read `archive/backend-beta-worker/README.md`
- older docs mentioning `GeminiEngine`, keychain helpers, or chat-drafting HTTP paths do not match the current tree
