# API Folder

## Current Scope

This folder is no longer the home of a live cloud drafting client.

Today it contains one source file:

- `BetaConfig.swift` — beta-build-only constants for proxy auth, versioning, and update URL

## `BetaConfig.swift`

Compiled only under `#if BETA_BUILD`.

Fields currently provided:

- `userToken` — placeholder replaced by `build-beta.sh`
- `proxyBaseURL` — beta telemetry/update proxy base
- `appVersion` — build version string used by beta update logic
- `updateURL` — download URL shown to beta users

## What Is Not Here Anymore

- no Gemini client
- no keychain helper
- no general-purpose API abstraction
- no active runtime inference code

If a new network service is added, document it here and keep beta config separated from reusable client logic.

## Verification

- `bash build.sh`
- if changing beta-only behavior, also validate a beta build path with `build-beta.sh`
