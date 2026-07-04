# PostHog Product Intelligence Map

Last audited: 2026-07-04 against this worktree.

Use this as the question-to-PR map for Transcripted product analytics. It is
docs-backed: every row points at current events, safe fields, dashboard query
shape, code seam, test coverage, and the next PR, without asking PostHog to
store content.

## Privacy Boundary

PostHog stays anonymous, aggregate, bucketed, and opt-in. Do not add transcript
text, OCR, app names, meeting titles, paths, URLs, emails, raw device names,
speaker names, user IDs, person IDs, raw IDs, raw error strings, or identifiers.

Safe shapes are enum fields, booleans, coarse buckets, public app/build
versions, coarse counts, and normalized failure kinds. New events must update
`Resources/analytics-events.psv`, `Resources/analytics-reviewed-properties.psv`
when needed, `docs/privacy-first-observability.md`, dashboard helpers, and
analytics policy/sanitizer tests in the same PR.

Note: the requested `ProductDecisionTelemetry` seam is not present in this
checkout. The current reusable seams are `ActivationTelemetry`,
`ProductFrictionTelemetry`, `WorkflowRecoveryTelemetry`,
`SpeakerRecognitionTelemetry`, `AnalyticsEventPolicy`, and
`AnalyticsPayloadSanitizer`. If a future PR adds `ProductDecisionTelemetry`, it
should wrap these patterns instead of creating scattered `AnalyticsReporter`
calls.

## Product Questions

| Product question | Current event coverage | Missing event or proof | Safe enum/bucket properties | Dashboard query | Code seam | Test coverage | PR needed |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Are detected meeting prompts useful, or noisy? | `meeting_prompt_shown`, `meeting_prompt_record_selected`, `meeting_prompt_dismissed`, `meeting_prompt_suppressed`, plus `meeting_detected_call_ended` and `meeting_missed_call_nudge`. | Stronger timeout/ignored proof: prompt shown but no accept/dismiss before the decision window. Also a coarse manual-start-after-suppression proxy for false negatives. | Existing: `provider`, `source`, `prompt_reason`, `calendar_confidence`, `call_state`, `route_ready`, `missing_permission`, `suppression_reason`, `cooldown_reason`, `backoff_kind`. Add only `decision_elapsed_bucket` and `followup_start_bucket` if needed. | `feature_adoption.meeting_prompts` from `scripts/ops/posthog-dashboard-queries.py`; trend accept, dismiss, suppress, and timeout rates by provider/source/route readiness. | `TranscriptedApp.swift` prompt actions; any new helper should live beside the existing prompt telemetry shape or in a future `ProductDecisionTelemetry`. | `Tests/AnalyticsEventPolicyTests.swift` already pins prompt fields and sanitizer drops paths, raw durations, errors, source apps, and URLs. | Small PR: add ignored/timeout prompt event if product needs it; otherwise dashboard-only. |
| Do saved artifacts look useful after capture? | `activation_first_artifact_saved`, `activation_second_artifact_saved`, `dictation_artifact_saved`, `meeting_transcript_saved`, `activation_artifact_action_clicked`. | Consumption after save is still inferred. There is no strict artifact-opened-after-save or reopened-days-later signal beyond existing artifact actions. | Existing: `artifact_kind`, `action_kind`, `artifact_age_bucket`, `surface`, `trigger`, `word_count_bucket`, `duration_bucket`, `days_since_first_bucket`. Add `followup_window_bucket` only if needed. | `feature_adoption.artifact_and_agent_actions`, `activation.reach_ladder`, and `activation.return_windows`. Query cohorts from first artifact to artifact action within 24h/7d. | `ActivationTelemetry.trackFirstArtifactSavedIfNeeded`, `trackArtifactAction`, dictation/meeting save paths. | `AnalyticsEventPolicyTests` pins activation events and proves sanitizer drops transcript, title, speaker name, audio path, file path, URL, prompt/query text, raw capture IDs, source app names, and raw word count. | Usually dashboard-only. Medium PR only if all artifact open/reveal/copy paths need stricter follow-up action coverage. |
| Does agent setup turn into actual agent payoff? | `activation_agent_prompt_action_clicked`, `activation_agent_setup_cta_clicked`, `onboarding_agent_cta_clicked`, `agent_capture_query_observed`, `activation_return_proxy_observed`. | Answer usefulness is still unknown. `agent_capture_query_observed` proves saved-capture read/search, not whether the answer helped. Broader MCP tool usage is thinner than capture-query proof. | Existing: `agent_target`, `query_kind`, `artifact_kind`, `result`, `surface`, `return_window_bucket`, `capture_age_bucket`, `source_count_bucket`, `prompt_kind`, `setup_kind`, `prior_status`. Future: `tool_kind`, `result`, `source_count_bucket`; never query text. | `activation.reach_ladder`, `feature_adoption.artifact_and_agent_actions`, `scripts/ops/retention-cohort-report.py`, and `scripts/ops/posthog-product-context-pack.py`. | `Tools/TranscriptedMCP/Sources/TranscriptedMCP/AgentCaptureQueryTelemetry.swift`; app-side setup/action seams in `ActivationTelemetry`. | `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/AgentCaptureQueryTelemetryTests.swift`, `AnalyticsEventPolicyTests`, retention script self-test. | Medium PR: generalize MCP telemetry beyond capture-query if needed. Keep answer quality `UNKNOWN` unless a privacy-safe local outcome exists. |
| Can users trust speaker names? | `meeting_speaker_review_shown`, `meeting_speaker_review_submitted`, `meeting_speaker_match_reviewed`, `meeting_speaker_auto_recognized`, `meeting_speaker_finalization_failed`. | Later correction after an accepted auto-recognition is not isolated as a trust-decay metric. No content-level correctness can leave device. | Existing: `review_action`, `similarity_bucket`, `margin_bucket`, `call_count_bucket`, `channel`, `had_suggestion`, `review_item_bucket`, `known_people_bucket`, `completion_kind`, `updates_submitted_bucket`, `result`, `surface`. Add only `correction_window_bucket` if needed. | Add a dashboard query: override/correction rate by `similarity_bucket`, `margin_bucket`, and `had_suggestion`; weekly count of `meeting_speaker_finalization_failed`. | `SpeakerRecognitionTelemetry`, `SpeakerNamingSheet.swift`, `MeetingSessionController.swift` speaker finalization. | `Tests/SpeakerRecognitionTelemetryTests.swift` and `AnalyticsEventPolicyTests` speaker-review suites. | Small PR: add correction-window bucket if current reviewed/auto events cannot answer threshold tuning. |
| Do retry and recovery paths actually recover users? | `workflow_recovery_attempted`, `workflow_recovery_finished`, `workflow_recovery_failed`, `workflow_abandoned`, dictation route recovery events, meeting failure/skipped events, `meeting_saved_audio_retranscription_requested`. | Wake/sleep and active-capture recovery are not fully represented in the product dashboard. Retry attempts are covered generically, but recovery-kind dashboards need stricter use. | Existing: `workflow_kind`, `failure_kind`, `retry_source`, `recovery_attempt_bucket`, `surface`, `artifact_retained`, `result`, `elapsed_bucket`, plus route/capture health buckets. Add `recovery_kind` only if `workflow_kind` is too broad. | `reliability.workflow_failure_rates`, `reliability.failure_kinds`, and a recovery outcome query grouped by `workflow_kind`, `failure_kind`, `retry_source`, `result`. Count totals from `workflow_recovery_finished`; use `workflow_recovery_failed` only for failure drill-downs. | `WorkflowRecoveryTelemetry`, `ProductFrictionTelemetry`, retry call sites in failed meeting and dictation flows. | `AnalyticsEventPolicyTests` pins recovery/friction fields; sanitizer tests cover raw error/path/url drops. | Medium PR: wire missing wake/active-capture recovery attempts if product wants recovery success rate, not just failure rate. |
| Can Dayflow/timeline ship without content leakage? | No PostHog timeline events today. Timeline docs explicitly keep screenshots, app names, window titles, OCR, screen content, and screenshot paths local. | Content-free engine health only: enabled state, pause/resume, capture loop health, retention cleanup. No activity taxonomy yet. | Safe future fields: `enabled`, `state`, `pause_reason`, `session_duration_bucket`, `capture_gap_bucket`, `cleanup_count_bucket`, `storage_cap_bucket`. Never app/window/OCR/path/title. | New dashboard family only after events exist: timeline engine health by week, pause rate, capture gap buckets, retention cleanup volume. | Future `TimelineTelemetry` near `Sources/Timeline/ScreenCaptureEngine.swift` and `TimelineRetentionManager.swift`; `Sources/Timeline/CLAUDE.md` is the guardrail. | New tests required in `AnalyticsEventPolicyTests` and sanitizer corpus before any event ships. | Separate high-scrutiny PR. Do not bundle with normal product telemetry. |
| Where does onboarding abandon? | `onboarding_shown`, `onboarding_step_viewed`, permission/model/CTA events, first dictation start/save/empty/stop, meeting dry run, agent CTA, reporting toggle, `onboarding_completed`, plus `workflow_abandoned`. | Mostly query shape. A single rollup event is optional; existing step events and abandoned workflow fields answer confident exits. | Existing: `step_id`, `step_index`, `flow_elapsed_bucket`, `step_elapsed_bucket`, `model_state`, `permission_kind`, `prior_status`, `to_status`, `cta`, `cta_type`, `first_dictation_saved`, `meeting_dry_run_completed`, `completion_flow`, `stage`, `reason_kind`. | `activation.ordered_funnel` plus an onboarding-friction query grouped by `step_id`, `stage`, `reason_kind`, and `flow_elapsed_bucket`. | `PermissionsOnboardingView.swift`; `ActivationTelemetry.trackWorkflowAbandoned` for confident exits. | `AnalyticsEventPolicyTests` pins onboarding funnel fields and sanitizer behavior. | Dashboard-only unless a specific abandoned-stage rollup proves materially easier to operate. |
| Are users forming post-save habits? | `activation_second_artifact_saved`, `activation_return_proxy_observed`, `agent_capture_query_observed`, `dictation_completed`, `dictation_artifact_saved`, `meeting_transcript_saved`. | Habit quality is still aggregate/proxy. There is no client-emitted active-days bucket; the retention script computes habit cohorts from PostHog event history. | Existing: `days_since_first_bucket`, `first_artifact_kind`, `second_artifact_kind`, `return_window_bucket`, `prior_artifact_kind`, `artifact_kind`, `capture_age_bucket`. Future: `repeat_modality`, `active_days_bucket` only if computed without IDs/content. | `scripts/ops/retention-cohort-report.py`, `wau.active_devices_by_week`, `wau.daily_active_devices`, `activation.return_windows`. | `ActivationTelemetry` saved-artifact/return proxy; retention scripts for aggregate cohorts. | `Tests/RepoCommandContractTests.swift` keeps first-value events in health probes/docs; retention script has self-test. | Dashboard/script-only for now. Medium PR only if PostHog-side cohorts cannot answer repeat modality. |
| Are local summaries useful enough to keep? | `local_meeting_summary_started`, `local_meeting_summary_completed`, `local_meeting_summary_failed`, `local_meeting_summary_cancelled`; settings actions also cover retry/open/dismiss notice actions. | There is no direct feedback/usefulness event, and completed summaries are not yet part of the main product loop dashboard. | Existing: `provider`, `runtime`, `summary_action`, `setup_ready`, `queue_depth_bucket`, `chunk_count_bucket`, `duration_bucket`, `failure_kind`, `stage`. Add `result` or `feedback_bucket` only if a real user-visible feedback control exists. | Add a local-summary funnel: transcript saved -> summary started -> completed/failed/cancelled -> opened/copied via settings actions. | `TranscriptedSettingsView.swift` summary start/complete/fail/cancel/action call sites. | `AnalyticsEventPolicyTests` pins local summary events through taxonomy parity; sanitizer tests cover forbidden payloads. | Small dashboard PR first. Product-code PR only when there is a real feedback action to instrument. |

## Dashboard Backlog

1. Add speaker trust query specs to `scripts/ops/posthog-dashboard-queries.py`.
2. Add workflow recovery outcome query specs for `workflow_recovery_*`.
3. Add local summary funnel specs if local summaries stay in the product loop.
4. Keep timeline analytics out until the timeline team approves content-free
   engine-health events.

## PR Checklist For New Events

1. Add the event to `Resources/analytics-events.psv`.
2. Add any non-bucket property to `Resources/analytics-reviewed-properties.psv`.
3. Update `docs/privacy-first-observability.md`.
4. Update this map and the relevant PostHog script/query helper.
5. Add or extend `Tests/AnalyticsEventPolicyTests.swift`.
6. Add sanitizer regression coverage if a new field is near a forbidden shape.
7. Run:

```bash
python3 scripts/ops/normalize-analytics-taxonomy.py --check
bash run-tests.sh --filter AnalyticsEventPolicy
bash run-tests.sh --filter AnalyticsPayloadSanitizer
```
