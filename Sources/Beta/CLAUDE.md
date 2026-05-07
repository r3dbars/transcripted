# Beta

## Current status

`Sources/Beta/` no longer contains runtime Swift configuration. Beta builds are
handled by `build-beta.sh`, release entitlements, signing, and notarization.

## Important file

- none currently

## Notes

- the core dictation and meeting flows do not depend on a live app-side API client here
- the current app no longer consumes `/config`-driven version or update fields from the archived beta worker
- beta builds no longer inject per-user tokens or compile with `BETA_BUILD`
- if you need beta distribution or backend context, read `archive/backend-beta-worker/README.md`
- older docs mentioning `GeminiEngine`, keychain helpers, or chat-drafting HTTP paths do not match the current tree
