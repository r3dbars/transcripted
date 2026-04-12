# Privacy-First Observability

This repo now uses three separate observability lanes:

- Sparkle for app updates
- Sentry for crash and reliability diagnostics
- PostHog for anonymous usage statistics

The point of splitting them is to keep product analytics, crash triage, and
release delivery from bleeding into each other.

## Privacy contract

- never send transcript text
- never send audio data or audio file references
- never send meeting titles
- never send speaker names
- never send source app names or bundle IDs
- never send absolute file paths
- never send emails, tokens, or raw URLs
- keep analytics to allowlisted events and coarse buckets only
- keep crash reporting separately user-controllable from anonymous analytics

## Current rollout checklist

- [x] Keep Sparkle as the in-app updater path
- [x] Keep Sparkle wired into `build.sh` and `build-beta.sh`
- [x] Use the official Sentry Cocoa SDK for stronger crash capture
- [x] Keep Sentry scrubbing and allowlisted non-fatal forwarding in app code
- [x] Add a separate anonymous analytics preference
- [x] Replace TelemetryDeck-specific analytics with PostHog-backed transport
- [x] Restrict analytics to explicit, privacy-reviewed events and properties
- [x] Add fast tests for analytics and Sentry sanitization policy

## Setup checklist

1. Create a PostHog project.
2. Copy the project API key into `Info.plist` under `TranscriptedPostHogAPIKey`.
3. Keep `TranscriptedPostHogHost` at `https://us.i.posthog.com` unless you are
   using EU or self-hosted PostHog.
4. Run `bash build-deps.sh --force` once to download the pinned Sentry and
   Sparkle frameworks.
5. Run `bash build.sh` and `bash run-tests.sh`.
6. In the app, verify Settings shows separate toggles for:
   - crash and error reports
   - anonymous usage statistics
7. Use `Send Test Sentry Event` to verify Sentry wiring.
8. Turn on anonymous usage statistics and verify only allowlisted events arrive
   in PostHog.

## Allowlisted analytics events

- `app_launched`
- `onboarding_completed`
- `dictation_started`
- `dictation_completed`
- `dictation_cancelled`
- `meeting_recording_started`
- `meeting_recording_stopped`
- `meeting_transcript_saved`
- `meeting_transcript_failed`

## Allowed property style

- booleans as `"true"` / `"false"`
- coarse buckets like `10_29s`, `50_149`, `4_plus`
- stable trigger enums like `hotkey`, `menu`, `detected_prompt`
- normalized failure kinds like `system_audio`, `recording_too_short`, `other`

Anything richer than that should stay local unless there is a new explicit
privacy review and a matching allowlist change.
