# Transcripted 100 WAU PostHog Dashboard

This is the minimum useful PostHog setup for steering Transcripted toward 100+
weekly active users without turning analytics into surveillance.

Use the dashboard to answer one question:

> Are more anonymous devices reaching saved Markdown, using it with an agent,
> and coming back later?

The June 2026 audit baseline was: 151 launch devices on `1.1.48`, 484
dictation completions, 84 meeting saves, and much lower strict activation
proof. Treat those as point-in-time inputs, not timeless product truth.

## Operating Definitions

- **Launch WAU:** unique anonymous devices with `app_launched` in the last 7
  days.
- **Value WAU:** unique anonymous devices with at least one value event in the
  last 7 days: `activation_first_artifact_saved`, `dictation_completed`,
  `meeting_transcript_saved`, `activation_artifact_action_clicked`,
  `activation_agent_prompt_action_clicked`, `activation_return_proxy_observed`,
  or `agent_capture_query_observed`.
- **Strict activation:** launch -> permission/onboarding ready -> first saved
  Markdown -> agent-use proof -> return.
- **Proxy activation:** launch -> saved Markdown or dictation completion ->
  artifact opened / prompt copied -> return proxy.

Do not collapse launch, proxy activation, and strict activation into one number.

## Dashboard Set

| Dashboard | Product question | Existing events to use | Missing events needed |
| --- | --- | --- | --- |
| 100 WAU operating dashboard | Are weekly active devices growing toward 100, and are they getting value? | `app_launched`, `activation_first_artifact_saved`, `dictation_completed`, `meeting_transcript_saved`, `activation_artifact_action_clicked`, `activation_agent_prompt_action_clicked`, `activation_return_proxy_observed`, `agent_capture_query_observed`; group by default `app_version`, `build_version`, `os_major` | optional `weekly_value_summary_observed` only if it stays aggregate and bucketed |
| Activation funnel | Where does first value leak? | `app_launched`, `onboarding_shown`, `onboarding_step_viewed`, `onboarding_permission_status_changed`, `onboarding_completed`, `onboarding_first_dictation_started`, `onboarding_first_dictation_saved`, `activation_first_artifact_saved`, `meeting_transcript_saved`, `dictation_completed`, `activation_artifact_action_clicked`, `activation_agent_prompt_action_clicked`, `activation_agent_setup_cta_clicked`, `onboarding_agent_cta_clicked`, `activation_return_proxy_observed`, `agent_capture_query_observed` | general dictation saved-artifact event if `dictation_completed` proves too loose |
| Dictation reliability funnel | Do users who start dictation reach usable text without painful recovery? | `dictation_started`, `dictation_start_failed`, `dictation_completed`, `dictation_stop_latency_measured`, `dictation_cancelled`, `dictation_no_speech`, `dictation_audio_route_changed`, `dictation_audio_route_recovery_finished`, `dictation_audio_route_recovery_timeout` | Dedicated `dictation_saved_markdown` only if needed to separate completion from persisted artifact |
| Meeting reliability funnel | Do meeting captures start, retain audio, transcribe, and save? | `meeting_prompt_shown`, `meeting_prompt_record_selected`, `meeting_prompt_dismissed`, `meeting_prompt_suppressed`, `meeting_recording_started`, `meeting_recording_start_failed`, `meeting_recording_stopped`, `meeting_capture_health_snapshot`, `meeting_transcript_saved`, `meeting_transcript_failed`, `meeting_transcript_skipped`, `meeting_saved_audio_retranscription_requested`, `meeting_mic_boost_prompt_shown`, `meeting_mic_boost_prompt_actioned`, `meeting_file_imported`, `meeting_file_import_failed`, `meeting_speaker_finalization_failed` | `meeting_opened_after_save` if Home/open behavior needs stricter proof than artifact-action clicks |
| Local summary beta funnel | Are beta summaries discoverable, prepared, run, and useful? | `settings_page_viewed`, `settings_action_clicked`, `settings_toggle_changed`; filter `page_id = 'beta'` and action/setting ids such as local summary prepare actions | `local_summary_requested`, `local_summary_started`, `local_summary_completed`, `local_summary_failed`, `local_summary_opened`; keep model/provider/status/failure as enums only |
| Agent/Markdown value loop | Does saved Markdown become a useful agent answer and later return? | `activation_first_artifact_saved`, `activation_artifact_action_clicked`, `activation_agent_prompt_action_clicked`, `activation_agent_setup_cta_clicked`, `onboarding_agent_cta_clicked`, `activation_return_proxy_observed`, `agent_capture_query_observed`, `meeting_transcript_saved`, `dictation_completed` | maybe `agent_answer_returned_observed` only if implemented through local MCP/tool invocation metadata, never content |
| Release health by app version | Did a release improve activation without hurting reliability? | All dashboard events grouped by default `app_version` and `build_version`; update events: `update_check_finished`, `update_download_started`, `update_download_finished`, `update_ready_to_install`, `update_relaunching`, `update_installed`; runtime events: `app_unclean_shutdown_detected`, `app_session_stall_detected` | None for the first dashboard. Add only coarse release-readiness enums if Sentry/PostHog release reviews need a stable join key later |

## PostHog Objects

Create these as saved PostHog insights, then collect them into one dashboard.

1. **100 WAU scorecard**
   - Number: launch WAU, last 7 days.
   - Number: value WAU, last 7 days.
   - Trend: value WAU by week for the last 12 weeks.
   - Breakdown: value WAU by `app_version`.
   - Guardrail: value WAU should never include raw content, paths, titles, or
     names.

2. **Activation funnel**
   - Funnel: `app_launched` -> onboarding touched -> `onboarding_completed` ->
     saved Markdown/proxy -> artifact action or agent prompt -> return proxy ->
     `agent_capture_query_observed`.
   - Use `scripts/ops/posthog-activation-funnel.py --days 30` for the
     aggregate report and proxy-vs-proof read.
   - Show strict saved Markdown separately from dictation-completed proxy.

3. **Dictation reliability funnel**
   - Funnel: `dictation_started` -> `dictation_completed`.
   - Breakdown failed starts by `failure_kind`, `trigger`,
     `selected_input_class`, `route_shape`, and `hfp_suspected`.
   - Trend `dictation_no_speech`, `dictation_cancelled`, and
     `dictation_audio_route_recovery_timeout` per value WAU.
   - Use latency buckets from `dictation_stop_latency_measured`; do not export
     raw timings.

4. **Meeting reliability funnel**
   - Funnel: prompt selected or recording started -> recording stopped ->
     health snapshot good/recovered -> transcript saved.
   - Breakdown failures by `failure_kind`, `trigger`, `system_status`,
     `capture_quality`, `system_stream_present`, and coarse device classes.
   - Watch prompt suppressions and dismissals so meeting prompts do not become
     annoying.

5. **Local summary beta funnel**
   - Funnel: Beta page viewed -> summary setting/action touched -> model
     prepared -> summary requested -> summary completed -> summary opened.
   - Today only the first two steps are remote-analytics ready through Settings
     events. The actual summary run should stay missing until enum-only events
     are reviewed and allowlisted.

6. **Agent/Markdown value loop**
   - Trend saved artifacts, artifact actions, agent prompt/setup actions, and
     return proxies together.
   - Primary proof: `agent_capture_query_observed`.
   - Label setup/prompt clicks as proxy evidence; even agent-query rows prove a
     saved-capture read/search, not answer quality.

7. **Release health by app version**
   - Compare launch WAU, value WAU, activation conversion, dictation completion,
     meeting save rate, update success, unclean shutdowns, and stalls by
     `app_version`.
   - Keep Sentry crash triage separate, but use this dashboard to decide if a
     release changed usage or reliability.

## Missing Event Backlog

Only add these if the dashboard cannot answer the product question with existing
events.

| Event | Purpose | Allowed properties |
| --- | --- | --- |
| `local_summary_requested` | Count user intent to summarize a meeting. | `surface`, `provider`, `transcript_age_bucket`, `duration_bucket`, `word_count_bucket` |
| `local_summary_started` | Separate queued/prep friction from generation failures. | `surface`, `provider`, `runtime`, `profile`, `transcript_age_bucket`, `duration_bucket`, `word_count_bucket` |
| `local_summary_completed` | Count successful local summary artifacts. | `surface`, `provider`, `runtime`, `profile`, `duration_bucket`, `word_count_bucket`, `summary_latency_bucket` |
| `local_summary_failed` | Debug beta summary reliability without content. | `surface`, `provider`, `runtime`, `profile`, `failure_kind`, `duration_bucket`, `word_count_bucket` |
| `local_summary_opened` | See whether generated summaries become part of the Home value loop. | `surface`, `provider`, `artifact_age_bucket` |
| `dictation_saved_markdown` | Replace `dictation_completed` as a saved-artifact proxy if needed. | `surface`, `trigger`, `delivery`, `duration_bucket`, `word_count_bucket` |

## Privacy Guardrails

- Aggregate counts, funnels, cohorts, and enum breakdowns are okay.
- No user-level forensics, people tables, session replays, raw distinct IDs, or
  per-device timelines.
- Never send transcript text, audio references, meeting titles, speaker names,
  emails, tokens, raw URLs, source app names, raw device names, or file paths.
- Keep all new properties enum-only, boolean-like, or coarse buckets.
- Any new PostHog event must be added to `AnalyticsEventPolicy`, covered by
  sanitizer/policy tests, and mirrored in `docs/privacy-first-observability.md`.

## Smallest Next Action

Build the PostHog dashboard from existing events first. Then verify
`agent_capture_query_observed` is reaching live aggregates for current builds,
because that is now the strongest gap between artifact volume and true product
value.
