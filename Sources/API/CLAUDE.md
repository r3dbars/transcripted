# API Directory (Legacy)

## What This Is

This directory previously contained the Anthropic API client layer (AnthropicAPI, AuthCredential, KeychainHelper, StreamingChatEngine, ChatMessage, AnthropicAPITypes). All of those files have been removed. The app is now fully local -- all inference runs on-device via MLXEngine (see `Sources/Local/`).

The only remaining file is `BetaConfig.swift`, which is unrelated to AI inference.

## Key Files

- `BetaConfig.swift` (~25 lines) -- `#if BETA_BUILD` gated config: per-user token (placeholder replaced by `build-beta.sh`), proxy URL, app version, update URL. Only compiled into beta builds.

## BetaConfig

Provides build-time constants for the beta distribution pipeline:

- `userToken` -- Per-user beta token, injected by `build-beta.sh` via sed (replaces `BETA_TOKEN_PLACEHOLDER`)
- `proxyBaseURL` -- Cloudflare Worker URL for telemetry and log shipping
- `appVersion` -- Semantic version string, compared against `/config` endpoint for update prompts
- `updateURL` -- GitHub Releases URL for latest DMG download

This file is only compiled when `-DBETA_BUILD` is passed to `swiftc`. Regular builds exclude it entirely.

## What Was Removed

The following files were deleted when the app moved to fully local inference:

- `AnthropicAPI.swift` -- URLSession HTTP client for the Anthropic Messages API
- `AnthropicAPITypes.swift` -- Error enum and Codable request/response structs
- `AuthCredential.swift` -- API key / subscription token abstraction with Keychain storage
- `KeychainHelper.swift` -- macOS Keychain wrapper (save/load/delete)
- `StreamingChatEngine.swift` -- Multi-turn streaming chat engine for the Agent tab
- `ChatMessage.swift` -- Chat message model (user/assistant/tool roles)

All inference now goes through `MLXEngine` (`Sources/Local/MLXEngine.swift`), which runs the `mlx-community/Qwen3.5-4B-4bit` model on-device via mlx-swift-lm. No API keys, subscription tokens, or network calls are needed for AI functionality.
