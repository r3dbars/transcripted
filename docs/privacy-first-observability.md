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
- keep analytics to allowlisted events and coarse buckets only (the reviewed
  exceptions are dictation and meeting speed timings, rounded to 10 ms; see below)
- keep crash reporting separately user-controllable from anonymous analytics
- Sentry automatic app-hang tracking is on in shipped builds (Info.plist
  `TranscriptedSentryAppHangTrackingEnabled`), but only reports a main thread
  stuck 5+ seconds, and `AppHangReportPolicy` drops any hang while a modal
  popup or Sparkle update window is on screen (those don't drain the main
  queue, so they used to be misreported as hangs). The code default with no
  Info.plist key stays off

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
6. Run `bash build.sh --no-open` and `bash run-tests.sh`.
7. In the app, verify onboarding shows two separate default-on questions for:
   - crash and error reports
   - anonymous usage statistics
8. Verify Settings also shows separate toggles for:
   - crash and error reports
   - anonymous usage statistics
9. Use About > `Send diagnostics` to verify Sentry wiring (the dedicated
   `Send Test Sentry Event` settings row was removed in the settings
   simplification).
10. Leave anonymous usage statistics on and verify only allowlisted events arrive
   in PostHog.
11. App-hang tracking is on in release builds (reviewed 2026-09-25, with the
    popup filter). `SENTRY_ENABLE_APP_HANG_TRACKING=false` turns it off for a
    local run. To check the popup filter, open an alert or the update window,
    leave it up for 10+ seconds, and confirm no "App Hanging" event arrives.

## Allowlisted analytics events

This list should match `Resources/analytics-events.psv`, which
`Sources/Observability/AnalyticsEventPolicy.swift` compiles into the runtime
allowlist.

- `usage_digest`
- `reliability_failure_observed`
- `app_launched`
- `app_unclean_shutdown_detected`
- `app_session_stall_detected`
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
- `activation_artifact_action_clicked`
- `activation_first_artifact_saved`
- `activation_second_artifact_saved`
- `activation_habit_loop_actioned`
- `activation_agent_prompt_action_clicked`
- `activation_agent_setup_cta_clicked`
- `agent_setup_lifecycle_observed`
- `agent_capture_query_observed`
- `activation_return_proxy_observed`
- `workflow_abandoned`
- `workflow_recovery_attempted`
- `workflow_recovery_failed`
- `workflow_recovery_finished`
- `product_friction_observed`
- `menu_bar_opened`
- `menu_bar_action_clicked`
- `update_action_clicked`
- `update_setting_changed`
- `update_check_finished`
- `update_download_started`
- `update_download_finished`
- `update_ready_to_install`
- `update_relaunching`
- `update_installed`
- `settings_opened`
- `settings_page_viewed`
- `settings_feature_discovered`
- `settings_action_clicked`
- `settings_toggle_changed`
- `settings_permission_cta_clicked`
- `settings_capture_library_changed`
- `launch_models_warmed`
- `dictation_start_requested`
- `dictation_started`
- `dictation_start_failed`
- `dictation_start_dropped_for_modifier_combo`
- `dictation_completed`
- `dictation_paste_retry_completed`
- `dictation_artifact_saved`
- `dictation_stop_latency_measured`
- `dictation_cancelled`
- `dictation_no_speech`
- `dictation_audio_needs_recovery`
- `dictation_other_language`
- `dictation_transcription_failed`
- `dictation_recording_too_short`
- `dictation_audio_route_changed`
- `dictation_audio_route_recovery_finished`
- `dictation_audio_route_recovery_timeout`
- `dictation_zombie_recovery_finished`
- `dictation_pinned_microphone_recording_started`
- `dictation_pinned_microphone_restarted`
- `dictation_pinned_microphone_device_switched`
- `dictation_pinned_microphone_fell_back_to_engine`
- `dictation_pinned_microphone_silent_input`
- `meeting_recording_started`
- `meeting_recording_start_failed`
- `meeting_system_audio_prompt_answered`
- `meeting_detected_call_ended`
- `meeting_prompt_shown`
- `meeting_prompt_choice_made`
- `meeting_prompt_dismissed`
- `meeting_prompt_outcome_recorded`
- `meeting_prompt_record_selected`
- `meeting_prompt_suppressed`
- `meeting_mic_boost_prompt_shown`
- `meeting_mic_boost_prompt_actioned`
- `meeting_missed_call_nudge`
- `meeting_recording_stopped`
- `meeting_capture_health_snapshot`
- `meeting_capture_route_warning_shown`
- `meeting_capture_stopped_under_controller`
- `meeting_recording_cancelled`
- `meeting_file_imported`
- `meeting_file_import_failed`
- `meeting_transcript_saved`
- `meeting_transcript_failed`
- `meeting_speaker_auto_recognized`
- `meeting_speaker_finalization_failed`
- `meeting_speaker_match_reviewed`
- `meeting_speaker_review_shown`
- `meeting_speaker_review_submitted`
- `meeting_transcript_skipped`
- `meeting_saved_audio_retranscription_requested`

## Allowed property style

- booleans as `"true"` / `"false"`
- coarse buckets like `10_29s`, `50_149`, `4_plus`
- stable trigger enums like `hotkey`, `menu`, `detected_prompt`
- retry attempt buckets like `start_attempt_bucket`, not raw retry counts
- normalized failure kinds like `system_audio`, `recording_too_short`, `other`
- normalized failure-code buckets like `url_-1009`, `sparkle_2003`, `other_42`
- feature discovery enums like `agent_setup`, `capture_library`,
  `permissions`, `speaker_review`, and `update_settings`
- workflow recovery fields limited to `workflow_kind`, `failure_kind`,
  `retry_source`, `recovery_attempt_bucket`, `surface`, `artifact_retained`,
  `result`, and `elapsed_bucket`
- product friction fields limited to `surface`, `stage`, `result`,
  `failure_kind`, `elapsed_bucket`, `route_shape`, and `model_state`
- meeting prompt decision/outcome fields limited to `prompt_reason`, `source`,
  `provider`, `call_state`, `route_ready`, `calendar_confidence`,
  `choice_kind`, `outcome_kind`, `elapsed_bucket`, and `suppression_reason`
- artifact-action analytics limited to `artifact_kind`, `action_kind`,
  `surface`, `artifact_age_bucket`, `result`, `trigger`,
  `word_count_bucket`, and `duration_bucket`
- paste retry analytics limited to `result` and a coarse `reason`; never text,
  capture identifiers, or target-app identifiers
- agent capture-query analytics limited to one terminal event with
  `client_family`, `tool_kind`, `capture_kind`, `result`,
  `source_count_bucket`, `result_count_bucket`, `latency_bucket`, and validated
  owning-app build identity; never
  query text, capture IDs, titles, names, transcript text, paths, or user IDs
- pinned-device mic rollout fields limited to `mic_backend`
  (`pinned_ioproc` / `av_audio_engine`), `selection_reason`,
  `selected_input_class`, `selection_overrode_default`, `start_latency_bucket`,
  `restart_trigger`, `stage`, `action`, and the meeting-only
  `pinned_mic_restart_bucket`, `pinned_mic_gap_bucket`,
  `pinned_mic_padded_bucket`, and `pinned_mic_dropped_callback_bucket`. The
  `dictation_pinned_microphone_*` events are forwarded from local
  `EventReporter` events by `AnalyticsEventForwardingPolicy`, which rebuilds
  every value from a fixed set; raw pinned counts stay in local logs
Meeting workflow analytics should keep that same stable `trigger` enum on later
stop/save/fail events so product and reliability reviews can attribute outcomes
without joining against any sensitive context.

Anything richer than that should stay local unless there is a new explicit
privacy review and a matching allowlist change.

## Analytics taxonomy review checklist

Every analytics change should update `Resources/analytics-events.psv`,
`Resources/analytics-reviewed-properties.psv` when new non-bucket properties
are introduced, and this doc in the same PR. `Tests/AnalyticsEventPolicyTests.swift`
machine-checks the event-name list above and the compiled property taxonomy.

For each new or changed event:

- document the event name in "Allowlisted analytics events"
- keep the registry normalized with
  `python3 scripts/ops/normalize-analytics-taxonomy.py --check`
- keep event names stable once released; add a new event instead of changing the
  meaning of an old one
- use enum, bucket, boolean, or count-bucket properties whenever possible
- use raw numeric diagnostics only for reviewed audio-health shape, such as
  sample rate, channel count, scalar volume, or peak buckets needed to debug
  capture reliability
- dictation speed is the other reviewed raw-number case: `dictation_started`
  carries `start_latency_ms`, and `dictation_stop_latency_measured` carries
  `first_sound_latency_ms` (key press to first audio buffer),
  `decode_latency_ms`, and `stop_to_paste_latency_ms`, all rounded to 10 ms
  by `MachineClassTelemetry.roundedMilliseconds`. Both events, and
  `dictation_start_requested` so the attempt funnel stays comparable, also carry
  `stt_model` (the `TranscriptionModelChoice` raw value), `mac_chip` (chip
  family and tier from the CPU brand string, such as `m2_pro`, else
  `unknown`), and `memory_gb_bucket`. These let PostHog compute P50/P95/P99
  per model and per kind of Mac; none of them identifies a user or a machine
- meeting processing speed is the third: `meeting_transcript_saved` carries
  `processing_ms` (job start to saved, wall clock), `sleep_ms` (the part the
  Mac slept), and the stage times `models_ready_ms`, `resample_ms`,
  `diarize_ms`, and `stt_ms`, all rounded to 10 ms; `stt_calls` (speech-to-text
  calls, one per speech segment) and `stt_input_seconds` (audio seconds fed to
  them, whole seconds); `recording_minutes` (whole minutes); plus `stt_model`,
  `mac_chip`, and `memory_gb_bucket`. `MeetingPipelineTimings` collects them in
  Core and `MeetingProcessingTelemetry` formats them. Durations and counts only
- route activation and return-loop events through `ActivationTelemetry` when
  possible so saved-artifact and agent-payoff signals stay coarse
- verify `bash run-tests.sh --filter AnalyticsEventPolicy` and
  `bash run-tests.sh --filter AnalyticsPayloadSanitizer`

Never add analytics properties for:

- transcript text or prompt text
- audio data, audio paths, or audio references
- meeting titles
- speaker names or invitee names
- absolute file paths or filenames derived from user content
- source app names or bundle IDs
- screen content, screenshots, OCR text, app names, window titles, or raw
  bundle IDs
- emails, tokens, authorization values, or credentials
- raw URLs or referrers
- raw device IDs, advertising IDs, person IDs, user IDs, distinct IDs, or
  identity-stitching fields
- free-form error strings or free-form context blobs

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

For a focused local privacy sweep, run:

```bash
python3 scripts/ops/privacy-leak-sweep.py --write-report build/privacy-leak-sweep-report.json
```

That command uses synthetic values only. It covers logs/events/reliability
JSONL, Sentry/PostHog payloads, QA and local report text, PR/release text, and
the scanner handoff summary shape.

The shared regression corpus for off-device scrubbers lives at
`Tests/Fixtures/ObservabilitySanitizerCorpus.json`. Both the Sentry and
analytics sanitizer tests should stay pinned to that same corpus so privacy
coverage does not drift quietly between the two lanes.

## Meeting measurement scope

Meeting capture diagnostics add three fixed, non-identifying descriptors:

- `capture_health_scope=own_capture`: health describes Transcripted's captured buffers and artifacts.
- `cross_app_capture_status=unmeasured`: no observation of another app's microphone transmission is made.
- `output_ducking_measurement=hardware_volume_scalars`: the legacy `output_ducking_detected` flag compares sampled hardware volume scalars; it does not measure software attenuation or another app's output.

Existing events, grades, and the legacy flag keep their semantics. An excellent
capture with `output_ducking_detected=false` cannot certify another app's audio.
Missing descriptors on older events mean legacy data, not measured compatibility.
These descriptors accompany existing capture diagnostics in local logs, support
packets and the already-allowlisted meeting analytics/failure events. They add no
process identity, audio content, hardware reads, or newly forwarded events. Live audio
compatibility requires the receiving-participant checks in
[Meeting Audio QA](qa-issue-500-meeting-audio.md).

## Shared install and failure metadata

The app reuses its persisted anonymous install UUID as PostHog `distinct_id` and
Sentry `user.id`. The Sentry sanitizer replaces the full user object with this ID
only. Analytics-enabled captures update a PostHog person through a fixed `$set`
object: `analytics_opt_in`, `app_version`, `build_revision`, `os_major`,
`install_channel`, and `first_launch_at` (UTC day). For existing installs the first
launch day means first observed by this version, not the original installation.
No email is collected. GeoIP enrichment is disabled on new PostHog requests.

Every app analytics event can carry the common `TelemetryContext.keys` allowlist:
`session_id`, `correlation_id`, `app_version`, `build_revision`, `os_major`,
`input_device_class`, `output_device_class`, `selection_reason`, `trigger`, and
microphone/screen/accessibility permission booleans. Session and correlation IDs
must be app-generated UUIDs. Missing route observations are explicitly `unknown`;
a missing observation is not evidence of a healthy route or a denied permission.
Screen permission reflects the app's cached System Audio Recording grant.

Failure, friction, and health events also carry `failure_kind` and `failure_stage`.
Health snapshots always carry `quality_reason` and `capture_outcome`; cancelled
captures have their own outcome, and a "Record Just My Mic" meeting reports
`mic_only_by_choice` rather than `complete`. `none` means no failure; `unknown` means missing
measurement. Every allowlisted Sentry hard failure has a matching
`reliability_failure_observed` PostHog record using the exact same correlation ID
and taxonomy, even when the low-level failure has no product lifecycle event.
Product lifecycle failures remain available for funnel analysis; do not sum them
with their canonical reliability counterparts. Meeting start, transcription,
speaker finalization, and dictation microphone timeout preserve the same operation
ID across their existing lifecycle reports too.

Capture degradation is a local warning and a PostHog health observation. It is
never a Sentry error, even if an old producer accidentally requests error level.
Hard start, transcript, audio-loss, stop-timeout, and engine-loop failures keep
their existing Sentry path. No audio-quality or routing policy changes here.

## Support diagnostics and daily digest

The existing Usage stats toggle controls analytics collection. A local metadata
ledger supplies the daily digest and recent failure details for support diagnostics.
`fair` capture grades join degraded; discarded captures do not count as successful
quality outcomes. Missing quality measurements remain explicitly unknown.

The local ledger retains at most 14 local days and three failure summaries in
preferences. It consumes reviewed lifecycle metadata, not capture files or logs.
It stores aggregate rounded minutes and a histogram of dictation duration buckets,
not individual durations. Matching failure kind + correlation ID is counted once
across the canonical and lifecycle reports. Copy diagnostics and support drafts
include install UUID, release, OS, permissions, coarse runtime/route state, and
last failure taxonomy; they no longer append raw event or reliability-log text.

`usage_digest` is emitted for closed local days on launch or the minute timer,
and for an unsent current day on normal quit. A quit snapshot has
`digest_is_partial=true`: later activity after a same-day relaunch is still visible
in lifecycle events and the local ledger but does not generate a second digest.
`digest_day` identifies the activity's local date; timestamps identify delivery.
Calendar arithmetic handles local midnight and DST rather than adding 24 hours.

Digest fields `meetings_started`, `meetings_completed`, `dictations_completed`,
and values inside `failures_by_kind` / `capture_quality_counts` use the shared
count buckets `0`, `1`, `2_3`, `4_9`, `10_plus`. `meeting_minutes_bucket` uses
`0`, `1_14m`, `15_59m`, `1_2h`, `3_9h`, `10h_plus`.
`dictation_median_duration_bucket` is the lower median bin of the duration
histogram, or `none` when no dictations completed. No exact count or duration is
sent by the digest. This deliberately follows the brief's bucket-only hard rule.
The two aggregate maps are encoded as JSON objects, never free-form JSON strings.

Each digest is persisted in the existing bounded retry buffer before its day is
marked enqueued. Retries keep the same top-level `uuid`, event, timestamp, and distinct ID, so a retry after an uncertain
HTTP response does not intentionally count the rollup twice. Transport remains
best effort: digests expire after 14 days, ordinary events after 24 hours.
Up to 14 digests receive priority over lifecycle traffic within the same
100-record / 64 KiB file bound. Off disables new events/person properties/digests,
purges unsent captures, and clears the local usage ledger. Up to 14 date-only
enqueue receipts remain to prevent duplicate same-day digests after re-enabling;
they contain no IDs or activity counts. Crash reporting retains its separate
preference. No vendor, recording behavior, or release configuration changes.

## Verify the candidate

- Exercise a failure with a controlled test install. Match Sentry `user.id` to
  PostHog `distinct_id`, and `correlation_id` + `failure_kind` on the Sentry event,
  `reliability_failure_observed`, and the corresponding lifecycle failure.
- Break down new-build health snapshots by `quality_reason` and `capture_outcome`;
  both must be present. Separate older releases when assessing null rates.
- Complete a degraded capture: the PostHog snapshot and local warning remain,
  but `meeting.recording_capture_degraded` is absent from Sentry errors.
- Compare unique users across the whole selected window; never sum daily DAU.
  Do not add canonical failure counts to the same lifecycle failures.
- Check Settings, copy diagnostics, then turn Usage stats off. Reopen and quit:
  there must be no additional analytics/person/digest requests after opt-out.
- Check local-day rollover, repeated quit/relaunch, retry after a network failure,
  and nested count maps. Synthetic local tests validate plumbing, not production
  ingestion or physical audio behavior. Fleet changes require deployment.

PostHog's [capture API](https://posthog.com/docs/api/capture) and
[person properties](https://posthog.com/docs/product-analytics/person-properties)
provide the wire contract for `$set` and event-based anonymous install profiles.

Every capture disables GeoIP enrichment with `$geoip_disable=true`. Request transport IP handling is a server setting: PostHog's [Discard IP data setting](https://posthog.com/tutorials/web-redact-properties#hiding-customer-ip-address) should be verified separately; a client-side `ip: false` option does not provide that guarantee.
