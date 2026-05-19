# Privacy-First Observability

This repo now uses three separate observability lanes:

- Sparkle for app updates
- Sentry for crash and reliability diagnostics
- PostHog for anonymous usage statistics

The point of splitting them is to keep product analytics, crash triage, and
release delivery from bleeding into each other.

There is no separate beta-only off-device telemetry path anymore. Beta builds
keep the updater flow, but diagnostics still go through the same Sentry and
PostHog controls described below.

Sentry DSNs should stay on `https://`. Non-HTTPS overrides are ignored so local
or bundled config cannot silently downgrade crash reports to plaintext
transport.
Sentry release registration is limited to build metadata: release name, dist,
and commit refs. It must not include transcript text, audio
references, meeting titles, speaker names, local paths, or user identifiers.

## Privacy contract

- never send transcript text
- never send audio data or audio file references
- never send meeting titles
- never send speaker names
- never send source app names or bundle IDs
- never send absolute file paths
- never send free-form context strings
- never send emails, tokens, or raw URLs
- keep analytics to allowlisted events and coarse buckets only
- keep crash reporting separately user-controllable from anonymous analytics
- keep Sentry automatic app-hang tracking off by default; modal macOS update,
  permission, and confirmation dialogs can otherwise be misreported as hangs

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
2. Keep the release PostHog project API key in `Info.plist` under `TranscriptedPostHogAPIKey`.
3. Keep `TranscriptedPostHogHost` at `https://us.i.posthog.com` unless you are
   using EU or self-hosted PostHog.
4. For local-only secrets, you can instead create
   `~/Library/Application Support/Transcripted/observability-overrides.plist`
   and set `TranscriptedPostHogAPIKey` there so the token never lands in git
   history. The app still falls back to the legacy Draft path if you already
   have `~/Library/Application Support/Draft/observability-overrides.plist`.
5. Run `bash build-deps.sh --force` once to download the pinned Sentry and
   Sparkle frameworks.
6. Run `bash build.sh` and `bash run-tests.sh`.
7. In the app, verify onboarding shows two separate default-on questions for:
   - crash and error reports
   - anonymous usage statistics
8. Verify Settings also shows separate toggles for:
   - crash and error reports
   - anonymous usage statistics
9. Use `Send Test Sentry Event` to verify Sentry wiring.
10. Leave anonymous usage statistics on and verify only allowlisted events arrive
   in PostHog.
11. If intentionally testing Sentry app-hang tracking, launch locally with
    `SENTRY_ENABLE_APP_HANG_TRACKING=true`. Do not enable it in release builds
    without a specific review of modal dialog false positives.

## Allowlisted analytics events

This list should match `Sources/Observability/AnalyticsEventPolicy.swift`.

- `app_launched`
- `app_unclean_shutdown_detected`
- `app_session_stall_detected`
- `support_diagnostics_copied`
- `support_diagnostic_event_sent`
- `onboarding_shown`
- `onboarding_step_viewed`
- `onboarding_permission_cta_clicked`
- `onboarding_permission_status_changed`
- `onboarding_model_state_changed`
- `onboarding_primary_cta_clicked`
- `onboarding_first_dictation_started`
- `onboarding_first_dictation_saved`
- `onboarding_first_dictation_stop_clicked`
- `onboarding_first_dictation_empty`
- `onboarding_meeting_dry_run_clicked`
- `onboarding_agent_cta_clicked`
- `onboarding_reporting_toggle_changed`
- `onboarding_completed`
- `onboarding_dismissed`
- `menu_bar_opened`
- `menu_bar_action_clicked`
- `update_action_clicked`
- `update_setting_changed`
- `update_check_finished`
- `update_download_started`
- `update_download_finished`
- `update_ready_to_install`
- `update_relaunching`
- `settings_opened`
- `settings_page_viewed`
- `settings_action_clicked`
- `settings_toggle_changed`
- `settings_permission_cta_clicked`
- `settings_capture_library_changed`
- `dictation_started`
- `dictation_start_failed`
- `dictation_completed`
- `dictation_cancelled`
- `dictation_no_speech`
- `dictation_audio_route_changed`
- `dictation_audio_route_recovery_finished`
- `dictation_audio_route_recovery_timeout`
- `meeting_recording_started`
- `meeting_recording_start_failed`
- `meeting_prompt_shown`
- `meeting_prompt_dismissed`
- `meeting_prompt_record_selected`
- `meeting_recording_stopped`
- `meeting_capture_health_snapshot`
- `meeting_recording_cancelled`
- `meeting_file_imported`
- `meeting_file_import_failed`
- `meeting_transcript_saved`
- `meeting_transcript_failed`
- `meeting_speaker_finalization_failed`
- `meeting_transcript_skipped`

## Allowed property style

- booleans as `"true"` / `"false"`
- coarse buckets like `10_29s`, `50_149`, `4_plus`
- stable trigger enums like `hotkey`, `menu`, `detected_prompt`
- normalized failure kinds like `system_audio`, `recording_too_short`, `other`

Meeting workflow analytics should keep that same stable `trigger` enum on later
stop/save/fail events so product and reliability reviews can attribute outcomes
without joining against any sensitive context.

Anything richer than that should stay local unless there is a new explicit
privacy review and a matching allowlist change.

## Nightly guardrail sweep

The nightly security automation should start with the deterministic checker:

```bash
python3 scripts/ops/nightly-security-check.py --write-report build/nightly-security-report.json
```

That report is the first pass, not the whole job. It should score the current
state, flag repo/release/privacy drift, and only then hand the run off to agent
judgment for a small high-confidence patch or a findings note.

When `Info.plist` has been bumped one patch version ahead for a release
candidate but the matching Git tag does not exist yet, the appcast should stay
on the latest published release. The checker reports that as a watch item, not
a release-integrity failure.

If the run built a fresh app or needs build-output verification, rerun it with:

```bash
python3 scripts/ops/nightly-security-check.py --app-bundle build/Transcripted.app --write-report build/nightly-security-report.json
```

The shared regression corpus for off-device scrubbers lives at
`Tests/Fixtures/ObservabilitySanitizerCorpus.json`. Both the Sentry and
analytics sanitizer tests should stay pinned to that same corpus so privacy
coverage does not drift quietly between the two lanes.
