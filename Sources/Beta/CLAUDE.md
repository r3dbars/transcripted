# Beta

## Current status

`Sources/Beta/` currently contains only the `BETA_BUILD` compile-time
configuration shell. There is no embedded beta token or beta proxy client in
the app target.

## Important file

- `BetaConfig.swift` — intentionally empty `#if BETA_BUILD` enum. The old
  per-user bearer token used by the archived proxy worker has been removed; see
  the file header for rationale and the keychain-based path if beta-only auth
  ever comes back.

## Notes

- the core dictation and meeting flows do not depend on a live app-side API client here
- the current app no longer consumes `/config`, `/events`, or `/logs` from the archived beta worker; Sparkle handles updates, Sentry handles crash and non-fatal reports, and PostHog handles anonymous analytics
- `build-beta.sh` still accepts a positional beta-token argument for backwards-compatible invocations, but the value is not injected into the binary
- if you need beta distribution or backend context, read `archive/backend-beta-worker/README.md`
- older docs mentioning `GeminiEngine`, keychain helpers, or chat-drafting HTTP paths do not match the current tree
