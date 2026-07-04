# Transcripted PostHog Product-Learning Plan

Last audited: 2026-06-19 against `origin/main` at `4ad53b9b`.

This is the product-learning map for opt-in PostHog analytics. It is meant to
answer one question: are users reaching the loop that matters?

> speech or meeting -> saved Markdown -> one sourced agent answer -> return later

For the sharper question-to-PR audit, use
`docs/posthog-product-intelligence-map.md`.

## Privacy Contract

Keep PostHog aggregate, bucketed, and opt-in. Do not collect:

- transcript text or prompt text
- audio data, audio filenames, or audio references
- meeting titles, invitee names, or speaker names
- emails, tokens, raw URLs, or raw error strings
- absolute file paths, source app names, bundle IDs, or raw device names
- per-person joins between website, GitHub, Cloudflare, and app activity

Safe shapes are enum fields, booleans, coarse buckets, public app versions,
stable surface/action IDs, and normalized failure kinds.

## Current Implementation

PostHog is wired through `AnalyticsReporter`. Events only send when anonymous
analytics is enabled, a PostHog key and HTTPS host are configured, and
`AnalyticsEventPolicy` allowlists the event. Properties are allowlisted per
event, then filtered again by `AnalyticsPayloadSanitizer`.

Every emitted event includes default metadata:

| Property | Meaning |
| --- | --- |
| `distinct_id` | anonymous install/device id |
| `session_id` | per-launch UUID |
| `app_version` | public app version |
| `build_version` | build version |
| `os_major` | major macOS version only |

Operational scripts query aggregate counts only:

- `scripts/ops/health-probe.sh posthog`
- `scripts/ops/posthog-dashboard-queries.py`
- `scripts/ops/posthog-activation-funnel.py`
- `scripts/ops/retention-cohort-report.py`
- `scripts/ops/posthog-product-context-pack.py`
- `scripts/ops/posthog-product-dashboard-summary.py`
- `scripts/ops/release-health-card.py`
- `scripts/ops/generate-nightly-digest.py`
- `scripts/ops/nightly-security-check.py`

## Current Event Allowlist

### App, Support, Runtime

| Event | Captured properties |
| --- | --- |
| `app_launched` | none beyond defaults |
| `app_unclean_shutdown_detected` | `app_version`, `build_version`, `duration_bucket`, `format_ready`, `heartbeat_age_bucket`, `last_event`, `os_major`, `previous_clean_shutdown`, `reason`, `recovering`, `session_active`, `session_duration_bucket`, `session_kind`, `session_stage`, `stall_kind`, `stall_stage`, `trigger` |
| `app_session_stall_detected` | same runtime diagnostic properties |
| `support_diagnostics_copied` | none beyond defaults |
| `support_diagnostic_event_sent` | none beyond defaults |

### Onboarding

| Event | Captured properties |
| --- | --- |
| `onboarding_shown` | `analytics_available`, `crash_reporting_available`, `entrypoint`, `has_target`, `meeting_recording_ready`, `mic_status`, `model_state`, `pasteback_status` |
| `onboarding_step_viewed` | `flow_elapsed_bucket`, `model_state`, `step_id`, `step_index` |
| `onboarding_permission_cta_clicked` | `permission_kind`, `prior_status`, `required`, `step_id` |
| `onboarding_permission_status_changed` | `from_status`, `permission_kind`, `step_id`, `to_status` |
| `onboarding_model_state_changed` | `from_status`, `step_id`, `to_status` |
| `onboarding_primary_cta_clicked` | `cta`, `cta_type`, `flow_elapsed_bucket`, `model_state`, `step_elapsed_bucket`, `step_id` |
| `onboarding_first_dictation_started` | `model_state`, `step_id` |
| `onboarding_first_dictation_saved` | `delivery`, `step_id`, `word_count_bucket` |
| `onboarding_first_dictation_stop_clicked` | `step_id` |
| `onboarding_first_dictation_empty` | `step_id` |
| `onboarding_meeting_dry_run_clicked` | `meeting_recording_ready`, `step_id` |
| `onboarding_agent_cta_clicked` | `agent_cta`, `step_id` |
| `onboarding_reporting_toggle_changed` | `available`, `enabled`, `reporting_kind`, `step_id` |
| `onboarding_completed` | `anonymous_usage_enabled`, `calendar_status`, `completion_flow`, `crash_reporting_enabled`, `first_dictation_saved`, `flow_elapsed_bucket`, `meeting_dry_run_completed`, `meeting_recording_ready`, `model_state`, `step_id` |
| `workflow_abandoned` | `elapsed_bucket`, `prior_ready_state`, `reason_kind`, `stage`, `surface`, `workflow_kind` |

### Activation And Agent Value

| Event | Captured properties |
| --- | --- |
| `activation_artifact_action_clicked` | `action_kind`, `artifact_age_bucket`, `artifact_kind`, `duration_bucket`, `result`, `surface`, `trigger`, `word_count_bucket` |
| `activation_first_artifact_saved` | `artifact_kind`, `duration_bucket`, `surface`, `trigger`, `word_count_bucket` |
| `dictation_artifact_saved` | `delivery`, `duration_bucket`, `save_outcome`, `surface`, `trigger`, `word_count_bucket` |
| `activation_second_artifact_saved` | `first_artifact_kind`, `second_artifact_kind`, `days_since_first_bucket`, `surface`, `trigger` |
| `activation_agent_prompt_action_clicked` | `action_kind`, `agent_target`, `artifact_kind`, `prompt_kind`, `result`, `surface` |
| `activation_agent_setup_cta_clicked` | `agent_target`, `prior_status`, `result`, `setup_kind`, `surface` |
| `activation_return_proxy_observed` | `prior_artifact_kind`, `proxy_kind`, `return_window_bucket`, `surface` |
| `activation_habit_loop_actioned` | `action_kind`, `artifact_kind`, `artifact_count_bucket`, `return_window_bucket`, `surface`, `result` |
| `workflow_abandoned` | `elapsed_bucket`, `prior_ready_state`, `reason_kind`, `stage`, `surface`, `workflow_kind` |
| `workflow_recovery_attempted` | `artifact_retained`, `failure_kind`, `recovery_attempt_bucket`, `retry_source`, `surface`, `workflow_kind` |
| `workflow_recovery_failed` | `artifact_retained`, `elapsed_bucket`, `failure_kind`, `recovery_attempt_bucket`, `result`, `retry_source`, `surface`, `workflow_kind` |
| `workflow_recovery_finished` | `artifact_retained`, `elapsed_bucket`, `failure_kind`, `recovery_attempt_bucket`, `result`, `retry_source`, `surface`, `workflow_kind` |
| `agent_capture_query_observed` | `agent_target`, `query_kind`, `artifact_kind`, `result`, `surface`, `return_window_bucket`, `capture_age_bucket`, `source_count_bucket` |

`agent_capture_query_observed.query_kind` is a reviewed enum. It includes
orientation reads (`list`, `recent`), direct artifact reads/searches
(`read`, `search`, `speaker_lookup`, `recap`), and sourced local-memory rollups
(`action_items`, `commitments`, `decisions`, `digest`, `open_questions`).
Together with `source_count_bucket`, it can show that a saved artifact powered
an agent answer without exporting query text or transcript content.

### Menu, Settings, Updates

| Event | Captured properties |
| --- | --- |
| `menu_bar_opened` | `dictation_ready`, `entrypoint`, `meeting_recording_ready`, `model_state`, `paste_available`, `recent_meetings_available`, `update_state` |
| `menu_bar_action_clicked` | `action_id`, `dictation_ready`, `meeting_recording_ready`, `paste_available` |
| `settings_opened` | `page_id`, `source` |
| `settings_page_viewed` | `page_id`, `source` |
| `settings_action_clicked` | `action_id`, `page_id` |
| `settings_toggle_changed` | `enabled`, `page_id`, `setting_id` |
| `settings_permission_cta_clicked` | `page_id`, `permission_kind`, `prior_status` |
| `settings_capture_library_changed` | `location_type`, `page_id` |
| `update_action_clicked` | `action_id`, `automatic_downloads_enabled`, `state`, `surface`, `version` |
| `update_setting_changed` | `enabled`, `setting_id` |
| `update_check_finished` | `automatic_downloads_enabled`, `failure_code`, `failure_kind`, `result`, `state`, `version` |
| `update_download_started` | `automatic_downloads_enabled`, `state`, `version` |
| `update_download_finished` | `automatic_downloads_enabled`, `failure_kind`, `state`, `version` |
| `update_ready_to_install` | `automatic_downloads_enabled`, `state`, `version` |
| `update_relaunching` | `version` |
| `update_installed` | `previous_version`, `version` |

### Dictation

Dictation events also allow coarse route fields: `default_input_class`,
`default_output_class`, `format_ready`, `hfp_suspected`, `input_channels`,
`input_device_class`, `input_rate_hz`, `output_channels`,
`output_device_class`, `output_rate_hz`, `recovery_latency_bucket`,
`recovering`, `route_shape`, `sample_flow_started`,
`selection_overrode_default`, `selection_reason`, `selected_input_class`,
`was_recording`.

| Event | Extra captured properties |
| --- | --- |
| `dictation_started` | `trigger` |
| `dictation_start_failed` | `failure_kind`, `start_attempt_bucket`, `trigger` |
| `dictation_completed` | `auto_send`, `delivery`, `duration_bucket`, `trigger`, `word_count_bucket` |
| `dictation_artifact_saved` | `delivery`, `duration_bucket`, `save_outcome`, `surface`, `trigger`, `word_count_bucket` |
| `dictation_stop_latency_measured` | `auto_enter_bucket`, `auto_send`, `cleanup_bucket`, `cleanup_changed`, `cleanup_enabled`, `copy_reason`, `decode_bucket`, `delivery`, `mic_stop_bucket`, `model_wait_bucket`, `outcome`, `paste_bucket`, `save_bucket`, `save_outcome`, `stop_to_done_bucket`, `stop_to_paste_bucket`, `trigger`, `word_count_bucket` |
| `dictation_cancelled` | `duration_bucket`, `trigger` |
| `dictation_no_speech` | `duration_bucket`, `trigger` |
| `dictation_audio_route_changed` | route fields only |
| `dictation_audio_route_recovery_finished` | route fields plus `outcome` |
| `dictation_audio_route_recovery_timeout` | route fields only |

### Meetings

Meeting capture events allow coarse diagnostics such as device class, sample
rate, system status, capture quality, recovery attempt bucket, route-change
bucket, quiet-mic flags, volume-change flags, and audio peaks. These are for
aggregate reliability sizing and should not be expanded to raw device names.

| Event | Extra captured properties |
| --- | --- |
| `meeting_recording_started` | `trigger` |
| `meeting_recording_start_failed` | `failure_kind`, `trigger` |
| `meeting_prompt_shown` | `app_signal`, `calendar_confidence`, `call_state`, `missing_permission`, `prompt_reason`, `provider`, `route_ready`, `source` |
| `meeting_prompt_choice_made` | `calendar_confidence`, `call_state`, `choice_kind`, `elapsed_bucket`, `prompt_reason`, `provider`, `route_ready`, `source` |
| `meeting_prompt_dismissed` | prompt fields plus `backoff_kind`, `cooldown_reason` |
| `meeting_prompt_outcome_recorded` | prompt fields plus `elapsed_bucket`, `outcome_kind`, optional `suppression_reason` |
| `meeting_prompt_record_selected` | prompt fields |
| `meeting_prompt_suppressed` | prompt fields plus `capture_activity`, `cooldown_reason`, `suppression_reason` |
| `meeting_mic_boost_prompt_shown` | `duration_bucket`, `trigger` |
| `meeting_mic_boost_prompt_actioned` | `action`, `duration_bucket`, `trigger` |
| `meeting_recording_stopped` | diagnostics plus `capture_quality`, `duration_bucket`, `gap_count_bucket`, `reason`, `route_change_count_bucket`, `system_stream_present`, `stop_timed_out`, `trigger` |
| `meeting_capture_health_snapshot` | same as `meeting_recording_stopped` |
| `meeting_recording_cancelled` | diagnostics plus `duration_bucket`, `reason`, `stop_timed_out`, `system_stream_present`, `trigger` |
| `meeting_transcript_saved` | `duration_bucket`, `participant_count_bucket`, `queue_depth_bucket`, `trigger`, `word_count_bucket` |
| `meeting_transcript_failed` | diagnostics plus `failure_kind`, `queue_depth_bucket`, `trigger` |
| `meeting_speaker_finalization_failed` | `failure_kind`, `queue_depth_bucket`, `session_stage`, `trigger` |
| `meeting_transcript_skipped` | diagnostics plus `failure_kind`, `queue_depth_bucket`, `trigger` |
| `meeting_saved_audio_retranscription_requested` | `mic_stream_present`, `trigger` |
| `meeting_file_imported` | `queue_depth_bucket` |
| `meeting_file_import_failed` | `failure_kind`, `import_stage` |

## What Is Measurable Today

- Weekly active devices and daily active devices from `app_launched` plus core
  workflow events.
- Onboarding exposure, step views, permission CTA clicks, permission status
  changes, model state, first dictation attempt, first dictation save,
  completion, and dismissal.
- Dictation start, start failure, completion, stop latency, cancellation,
  no-speech, delivery, pasteback outcome, local-model latency buckets, auto-send
  state, and coarse audio route health.
- Meeting prompt shown, accepted, dismissed, suppressed, start/stop/cancel,
  capture health, transcript saved/failed/skipped, imported-audio failure,
  speaker-finalization failure, and saved-audio retranscription request.
- First saved artifact across dictation and meeting with coarse artifact kind,
  trigger, duration bucket, and word-count bucket.
- Artifact open/reveal/preview/local-summary actions and agent setup or prompt-copy intent.
- Confident workflow abandonment for onboarding close, meeting-prompt dismissal
  or suppression, local-summary/model-prep block/cancel/fail, failed agent setup
  or artifact handoff, and failed-meeting retry dismissal/delete.
- Return proxy when Home observes an older saved artifact.
- Release health by app version and update lifecycle.

## Biggest Blind Spots

- `agent_capture_query_observed` exists in the read-only MCP/agent surface and
  now covers sourced local-memory rollups, but PostHog still cannot judge
  whether the sourced answer was useful.
- General dictation saved-Markdown writes now have `dictation_artifact_saved`;
  keep `dictation_completed` as completion-volume context, not strict saved-artifact proof.
- `agent_capture_query_observed` proves successful saved-capture reads,
  searches, and summary-memory rollups through MCP, but it still cannot judge
  answer quality.
- General dictation saved-Markdown writes still rely on `dictation_completed`
  as a proxy, while onboarding dictation and meeting saves have stricter events.
- Settings/action tracking is broad enough to show discovery, but it does not
  always connect settings changes to later workflow success.
- Local summary beta behavior now has artifact-action, start, completion,
  failure, and abandonment shape. It still cannot judge whether the generated
  summary was useful.
- Speaker review now has a narrow prompt/submission funnel, but final transcript
  rewrite quality is still visible mainly through meeting outcome and
  finalization failure events.
- Retention is a return proxy, not a real habit model. It needs day/week active
  cohorts and first-artifact-to-second-artifact conversion in PostHog dashboards.

## A+ Event Taxonomy To Add

Prefer a small number of lifecycle events over broad click tracking.

| Event | When to fire | Properties |
| --- | --- | --- |
| `agent_capture_query_observed` | The local MCP/agent layer observes a privacy-safe query against saved captures or sourced local summary memory | `agent_target`, `query_kind`, `artifact_kind`, `result`, `surface`, `return_window_bucket`, `capture_age_bucket`, `source_count_bucket` |
| `activation_second_artifact_saved` | A device saves its second artifact | `first_artifact_kind`, `second_artifact_kind`, `days_since_first_bucket`, `surface`, `trigger` |
| `activation_habit_loop_actioned` | A user takes a post-save or daily-return action like Review yesterday, What did I promise, open recent meeting, daily digest viewed/exported, or return after first/second artifact | `action_kind`, `artifact_kind`, `artifact_count_bucket`, `return_window_bucket`, `surface`, `result` |
| `dictation_artifact_saved` | Any normal dictation Markdown is durably saved | `delivery`, `duration_bucket`, `save_outcome`, `surface`, `trigger`, `word_count_bucket` |
| `dictation_retry_started` | User retries after a failed or empty dictation | `failure_kind`, `retry_source`, `route_shape`, `trigger` |
| `meeting_speaker_auto_recognized` | A returning speaker was silently recognized without review; `graduated` marks a profile's first-ever auto-recognition | `similarity_bucket`, `margin_bucket`, `call_count_bucket`, `channel`, `graduated`, `surface` |
| `meeting_speaker_match_reviewed` | One review verdict joining match confidence to the user's answer (confirmed = right, corrected = wrong) | `review_action`, `similarity_bucket`, `margin_bucket`, `call_count_bucket`, `channel`, `had_suggestion`, `surface` |
| `meeting_speaker_review_shown` | A saved meeting has review work surfaced | `review_item_bucket`, `local_voice_bucket`, `remote_voice_bucket`, `match_suggestion_bucket`, `known_people_bucket`, `review_reason`, `surface` |
| `meeting_speaker_review_submitted` | User saves or defers speaker review | `review_item_bucket`, `local_voice_bucket`, `remote_voice_bucket`, `match_suggestion_bucket`, `known_people_bucket`, `review_reason`, `completion_kind`, `result`, `updates_submitted_bucket`, `surface` |
| `settings_feature_discovered` | A high-leverage feature panel is first viewed | `feature_area`, `page_id`, `source` |
| `workflow_abandoned` | App can confidently infer abandonment without content | `workflow_kind`, `stage`, `reason_kind`, `elapsed_bucket`, `surface`, optional `prior_ready_state` |

Do not add generic "button clicked" for every control. Track buttons only when
they answer a product question: did the user start capture, grant permission,
save/open a useful artifact, connect an agent, recover from failure, or return?

## Dashboards And Funnels

Use `scripts/ops/posthog-dashboard-queries.py --dry-run` for the reusable
HogQL specs behind these dashboard families. Use `--json-only` when
`transcripted-health` or another agent needs machine-readable rows.

### 100 WAU Operating Dashboard

- WAU and DAU from core workflow events, not only launch.
- WAU by app version.
- first artifact devices, second artifact devices, and return-proxy devices.
- dictation completed devices and meeting transcript saved devices.
- failure-rate tiles for dictation start, dictation no-speech, meeting start,
  meeting transcript failure, update failure.

`scripts/ops/posthog-product-dashboard-summary.py` is the deterministic
dashboard-to-product-task loop. It reads aggregate PostHog signal for this
dashboard plus Activation, Reliability, Feature Adoption, and Release Health,
then outputs the biggest activation leak, biggest reliability leak, strongest
adoption signal, under-discovered feature, release regression watch, and top
three PR/task candidates. Fixture mode uses
`Tests/Fixtures/posthog-product-dashboard-summary.json` so CI can verify the
ranking logic without credentials.

### Activation Funnel

`app_launched` -> `onboarding_shown` / `onboarding_step_viewed` ->
permission ready -> `dictation_started` / `meeting_recording_started` ->
`activation_first_artifact_saved` -> `activation_second_artifact_saved` ->
`activation_artifact_action_clicked` ->
`activation_agent_prompt_action_clicked` / `activation_agent_setup_cta_clicked`
-> `agent_capture_query_observed` -> `activation_return_proxy_observed`.

Break out `workflow_abandoned` by `workflow_kind`, `stage`, `reason_kind`, and
`prior_ready_state` beside the ordered funnel. Treat it as an exit map, not a
click stream.

### Dictation Reliability Funnel

`dictation_started` -> `dictation_start_failed` or recording active ->
`dictation_stop_latency_measured` -> `dictation_completed` ->
`dictation_artifact_saved` -> pasted/copied delivery -> retry after failure.

Break down by trigger, delivery, route shape, input/output class,
`hfp_suspected`, failure kind, and latency buckets.

### Meeting Reliability Funnel

`meeting_prompt_shown` -> `meeting_prompt_choice_made` ->
`meeting_prompt_record_selected` -> `meeting_recording_started` ->
`meeting_prompt_outcome_recorded` -> `meeting_recording_stopped` ->
`meeting_transcript_saved` / failed / skipped -> speaker review ->
summary requested -> summary finished.

Break down by provider, source, route readiness, missing permission, trigger,
system stream present, capture quality, queue depth, and failure kind.
Use `workflow_recovery_finished` for terminal retry/recovery totals, then
`workflow_recovery_failed` for failure-only drill-downs by `workflow_kind`,
`failure_kind`, `retry_source`, `recovery_attempt_bucket`, and `result`.

### Local Summary Beta Funnel

`meeting_transcript_saved` -> `local_meeting_summary_started` ->
`local_meeting_summary_completed` / `local_meeting_summary_failed` /
`local_meeting_summary_cancelled` ->
`workflow_recovery_finished` / `workflow_recovery_failed` for retry from the failure notice ->
opened/copied/applied summary. Track provider, runtime, duration bucket, result,
and failure kind only.

### Agent And Markdown Value Loop

`activation_first_artifact_saved` -> open/reveal/preview/local summary ->
agent prompt/setup -> `agent_capture_query_observed` -> next-day return ->
second artifact saved.

This is the north-star dashboard. Treat prompt-copy and setup clicks as intent,
not proof.

### Agent Product Context Pack

When Codex or another agent needs product context for prioritization, run:

```bash
python3 scripts/ops/posthog-product-context-pack.py --days 30
```

This produces a compact JSON and Markdown pack with:

- current activation bottleneck
- strongest repeat-use signal
- highest reliability pain
- release-version anomaly
- strongest feature adoption signal
- top three recommended next PRs

Use the pack in Transcripted health/nightly reports when the goal is an
agent-readable decision artifact. Keep the activation funnel report for deeper
diagnosis.

### Release Health By App Version

- launch, success, and failure rows by `app_version`, `build_version`,
  `build_channel`, and `build_revision`
- shipped-release reads must not merge `build_channel = release` rows with
  local/current-main rows such as `local`, `dev`, `main`, `nightly`, or
  `unknown`
- first successful `dictation_artifact_saved`
- useful dictation completion volume via `dictation_completed`
- first successful `meeting_transcript_saved`
- `activation_first_artifact_saved`
- update lifecycle events
- Sentry release health next to PostHog usage, without joining personal data

## Live Aggregate Snapshot

The 2026-06-19 aggregate probes showed:

- Last 7 days: 193 active devices, 2390 workflow events, 1018 onboarding events,
  850 first-value events.
- Last 30 days: 214 launch devices, 37 strict saved-Markdown devices, 43
  saved-Markdown-plus-dictation-proxy devices, 32 agent setup/proxy devices,
  17 return-proxy devices, and true agent-query devices from `agent_capture_query_observed`.

Interpretation: product usage is real, but the current analytics still cannot
prove the full saved-artifact -> sourced-agent-answer -> return loop.

## Smallest Next Implementation

Keep `agent_capture_query_observed` live and narrow in the read-only MCP/agent
surface: successful saved-capture reads/searches, sourced summary-memory
rollups, enum values, source-count buckets, and coarse age/window buckets only.
The next useful loop is live-proof verification and answer-quality UNKNOWN
reporting, not richer content capture.
