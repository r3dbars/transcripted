#!/usr/bin/env python3
"""Reusable privacy-safe PostHog query helpers for Transcripted dashboards."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import posthog_common as posthog

FAMILIES = (
    "100_wau",
    "activation",
    "meeting_prompt_quality",
    "artifact_usefulness",
    "agent_payoff",
    "speaker_trust",
    "retry_recovery",
    "onboarding_friction",
    "timeline_dayflow",
    "release_health",
)

ACTIVE_WORKFLOW_EVENTS = (
    "app_launched",
    "dictation_started",
    "dictation_completed",
    "meeting_recording_started",
    "meeting_transcript_saved",
    "activation_first_artifact_saved",
    "activation_second_artifact_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_habit_loop_actioned",
    "activation_return_proxy_observed",
    "agent_capture_query_observed",
)

ACTIVATION_EVENTS = (
    "app_launched",
    "onboarding_shown",
    "onboarding_step_viewed",
    "onboarding_completed",
    "onboarding_first_dictation_started",
    "dictation_started",
    "meeting_recording_started",
    "onboarding_first_dictation_saved",
    "activation_first_artifact_saved",
    "meeting_transcript_saved",
    "dictation_completed",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "onboarding_agent_cta_clicked",
    "agent_capture_query_observed",
    "activation_habit_loop_actioned",
    "activation_return_proxy_observed",
    "activation_second_artifact_saved",
    "workflow_abandoned",
)

MEETING_PROMPT_EVENTS = (
    "meeting_prompt_shown",
    "meeting_prompt_choice_made",
    "meeting_prompt_record_selected",
    "meeting_prompt_outcome_recorded",
    "meeting_prompt_dismissed",
    "meeting_prompt_suppressed",
    "meeting_missed_call_nudge",
    "meeting_mic_boost_prompt_shown",
    "meeting_mic_boost_prompt_actioned",
)

ARTIFACT_EVENTS = (
    "activation_first_artifact_saved",
    "activation_second_artifact_saved",
    "dictation_artifact_saved",
    "dictation_completed",
    "meeting_transcript_saved",
    "activation_artifact_action_clicked",
    "activation_habit_loop_actioned",
    "activation_return_proxy_observed",
)

AGENT_PAYOFF_EVENTS = (
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "onboarding_agent_cta_clicked",
    "agent_capture_query_observed",
    "local_meeting_summary_started",
    "local_meeting_summary_cancelled",
    "local_meeting_summary_completed",
    "local_meeting_summary_failed",
)

SPEAKER_TRUST_EVENTS = (
    "meeting_speaker_review_shown",
    "meeting_speaker_review_submitted",
    "meeting_speaker_match_reviewed",
    "meeting_speaker_auto_recognized",
    "meeting_speaker_finalization_failed",
)

RETRY_RECOVERY_EVENTS = (
    "dictation_started",
    "dictation_start_failed",
    "dictation_completed",
    "dictation_cancelled",
    "dictation_no_speech",
    "dictation_stop_latency_measured",
    "dictation_audio_route_recovery_finished",
    "dictation_audio_route_recovery_timeout",
    "meeting_recording_started",
    "meeting_recording_start_failed",
    "meeting_recording_stopped",
    "meeting_capture_health_snapshot",
    "meeting_transcript_saved",
    "meeting_transcript_failed",
    "meeting_transcript_skipped",
    "meeting_file_import_failed",
    "meeting_saved_audio_retranscription_requested",
    "local_meeting_summary_started",
    "local_meeting_summary_cancelled",
    "local_meeting_summary_completed",
    "local_meeting_summary_failed",
    "workflow_abandoned",
    "workflow_recovery_attempted",
    "workflow_recovery_failed",
    "workflow_recovery_finished",
)

ONBOARDING_FRICTION_EVENTS = (
    "onboarding_shown",
    "onboarding_step_viewed",
    "onboarding_permission_status_changed",
    "onboarding_permission_cta_clicked",
    "onboarding_primary_cta_clicked",
    "onboarding_completed",
    "onboarding_first_dictation_started",
    "onboarding_first_dictation_saved",
    "onboarding_first_dictation_empty",
    "onboarding_model_state_changed",
    "onboarding_meeting_dry_run_clicked",
    "product_friction_observed",
    "workflow_abandoned",
)

TIMELINE_DAYFLOW_EVENTS = (
    "timeline_enabled",
    "timeline_screen_permission_ready",
    "timeline_screen_permission_denied",
    "timeline_capture_paused",
    "timeline_capture_resumed",
    "timeline_card_generated",
    "timeline_card_opened",
    "timeline_daily_markdown_written",
    "timeline_used_again",
)

RELEASE_EVENTS = (
    "app_launched",
    "dictation_started",
    "dictation_completed",
    "meeting_recording_started",
    "meeting_transcript_saved",
    "meeting_transcript_failed",
    "update_check_finished",
    "update_download_started",
    "update_download_finished",
    "update_ready_to_install",
    "update_relaunching",
    "update_installed",
)

RELEASE_WORKFLOW_EVENTS = (
    "app_launched",
    "dictation_started",
    "dictation_completed",
    "meeting_recording_started",
    "meeting_transcript_saved",
    "meeting_transcript_failed",
)

DISALLOWED_OUTPUT_FRAGMENTS = (
    "distinct_id",
    "person",
    "uuid",
    "email",
    "name",
    "path",
    "title",
    "transcript",
    "audio",
    "url",
    "token",
    "raw",
)

FIXTURE_PATH = Path("Tests/Fixtures/posthog-dashboard-query-results.json")
OBSERVED_FIXTURE_PATH = Path("Tests/Fixtures/posthog-observed-event-taxonomy.json")
ANALYTICS_EVENTS_PATH = Path("Resources/analytics-events.psv")

EVENT_LITERAL_RE = re.compile(r"\b(?:event|e\.event)\s*=\s*'([a-z][a-z0-9_]+)'|\b(?:event|e\.event)\s+IN\s*\(([^)]*)\)")
STRING_LITERAL_RE = re.compile(r"'([^']+)'")

REQUIRED_TAXONOMY_EVENTS = (
    "activation_first_artifact_saved",
    "activation_second_artifact_saved",
    "dictation_artifact_saved",
    "activation_artifact_action_clicked",
    "workflow_recovery_attempted",
    "workflow_recovery_finished",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "agent_capture_query_observed",
    "activation_habit_loop_actioned",
    "activation_return_proxy_observed",
    "meeting_prompt_shown",
    "meeting_prompt_choice_made",
    "meeting_prompt_record_selected",
    "meeting_prompt_outcome_recorded",
    "meeting_prompt_dismissed",
    "meeting_prompt_suppressed",
    "onboarding_completed",
    "product_friction_observed",
    "workflow_abandoned",
)


@dataclass(frozen=True)
class QuerySpec:
    id: str
    family: str
    title: str
    description: str
    sql: str
    columns: tuple[str, ...]
    notes: tuple[str, ...] = ()


class PostHogDashboardError(RuntimeError):
    pass


load_env = posthog.load_env
sql_quote = posthog.sql_quote
sql_list = posthog.sql_list
event_filter = posthog.event_filter
app_version_filter = posthog.app_version_filter
version_or_app_version_filter = posthog.version_or_app_version_filter


def posthog_config() -> tuple[str, str, str]:
    return posthog.posthog_config(PostHogDashboardError)


def query_specs(days: int, app_version: str | None) -> list[QuerySpec]:
    days = int(days)
    return [
        QuerySpec(
            id="wau.active_devices_by_week",
            family="100_wau",
            title="Weekly active workflow devices",
            description="Counts anonymous active devices by PostHog UTC week from workflow and first-value events.",
            columns=("week", "active_devices", "workflow_events", "first_value_devices", "second_artifact_devices", "agent_payoff_devices", "return_proxy_devices", "habit_loop_devices"),
            sql=f"""
SELECT
  toStartOfWeek(timestamp) AS week,
  uniq(distinct_id) AS active_devices,
  count() AS workflow_events,
  uniqIf(distinct_id, event IN ('activation_first_artifact_saved', 'meeting_transcript_saved', 'onboarding_first_dictation_saved')) AS first_value_devices,
  uniqIf(distinct_id, event = 'activation_second_artifact_saved') AS second_artifact_devices,
  uniqIf(distinct_id, event = 'agent_capture_query_observed') AS agent_payoff_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed') AS return_proxy_devices,
  uniqIf(distinct_id, event = 'activation_habit_loop_actioned') AS habit_loop_devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(ACTIVE_WORKFLOW_EVENTS)}
  {app_version_filter(app_version)}
GROUP BY week
ORDER BY week ASC
""",
            notes=("Use this as the top-line 100 WAU read. It is device-level and aggregate only.",),
        ),
        QuerySpec(
            id="wau.daily_active_devices",
            family="100_wau",
            title="Daily active workflow devices",
            description="Shows DAU, launches, workflow events, and first-value devices for trend cards.",
            columns=("day", "active_devices", "launch_events", "workflow_events", "first_value_devices", "second_artifact_devices", "agent_payoff_devices", "habit_loop_devices"),
            sql=f"""
SELECT
  toDate(timestamp) AS day,
  uniq(distinct_id) AS active_devices,
  countIf(event = 'app_launched') AS launch_events,
  count() AS workflow_events,
  uniqIf(distinct_id, event IN ('activation_first_artifact_saved', 'meeting_transcript_saved', 'onboarding_first_dictation_saved')) AS first_value_devices,
  uniqIf(distinct_id, event = 'activation_second_artifact_saved') AS second_artifact_devices,
  uniqIf(distinct_id, event = 'agent_capture_query_observed') AS agent_payoff_devices,
  uniqIf(distinct_id, event = 'activation_habit_loop_actioned') AS habit_loop_devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(ACTIVE_WORKFLOW_EVENTS)}
  {app_version_filter(app_version)}
GROUP BY day
ORDER BY day ASC
""",
        ),
        QuerySpec(
            id="wau.version_mix",
            family="100_wau",
            title="Active devices by app version",
            description="Breaks active workflow devices by public app version without exposing devices.",
            columns=("app_version", "active_devices", "events", "last_seen"),
            sql=f"""
SELECT
  properties['app_version'] AS app_version,
  uniq(distinct_id) AS active_devices,
  count() AS events,
  max(timestamp) AS last_seen
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(ACTIVE_WORKFLOW_EVENTS)}
  AND properties['app_version'] IS NOT NULL
  {app_version_filter(app_version)}
GROUP BY app_version
ORDER BY active_devices DESC
LIMIT 20
""",
        ),
        QuerySpec(
            id="activation.reach_ladder",
            family="activation",
            title="Activation reach ladder",
            description="One-row reach table for launch through saved Markdown, agent proxy, true agent-use, habit loop, and return proxy.",
            columns=(
                "launch_devices",
                "onboarding_devices",
                "permission_ready_devices",
                "capture_started_devices",
                "strict_saved_markdown_devices",
                "saved_markdown_or_dictation_proxy_devices",
                "artifact_action_devices",
                "agent_proxy_devices",
                "true_agent_query_devices",
                "second_artifact_devices",
                "habit_loop_devices",
                "next_day_return_devices",
                "seven_day_return_devices",
                "return_proxy_devices",
            ),
            sql=f"""
SELECT
  uniqIf(distinct_id, event = 'app_launched') AS launch_devices,
  uniqIf(distinct_id, event IN ('onboarding_shown', 'onboarding_step_viewed')) AS onboarding_devices,
  uniqIf(distinct_id, event = 'onboarding_completed') AS permission_ready_devices,
  uniqIf(distinct_id, event IN ('onboarding_first_dictation_started', 'dictation_started', 'meeting_recording_started')) AS capture_started_devices,
  uniqIf(distinct_id, event IN ('activation_first_artifact_saved', 'onboarding_first_dictation_saved', 'meeting_transcript_saved')) AS strict_saved_markdown_devices,
  uniqIf(distinct_id, event IN ('activation_first_artifact_saved', 'onboarding_first_dictation_saved', 'meeting_transcript_saved', 'dictation_completed')) AS saved_markdown_or_dictation_proxy_devices,
  uniqIf(distinct_id, event = 'activation_artifact_action_clicked') AS artifact_action_devices,
  uniqIf(distinct_id, event IN ('activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked')) AS agent_proxy_devices,
  uniqIf(distinct_id, event = 'agent_capture_query_observed') AS true_agent_query_devices,
  uniqIf(distinct_id, event = 'activation_second_artifact_saved') AS second_artifact_devices,
  uniqIf(distinct_id, event = 'activation_habit_loop_actioned') AS habit_loop_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed' AND properties['return_window_bucket'] = '18_36h') AS next_day_return_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed' AND properties['return_window_bucket'] IN ('36_72h', '3_7d')) AS seven_day_return_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed') AS return_proxy_devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(ACTIVATION_EVENTS)}
  {app_version_filter(app_version)}
""",
            notes=("Treat agent proxy counts as intent. They do not prove a sourced answer.",),
        ),
        QuerySpec(
            id="activation.ordered_funnel",
            family="activation",
            title="Ordered activation funnel",
            description="Uses windowFunnel for ordered launch to agent proxy progression.",
            columns=("deepest_step", "devices"),
            sql=f"""
SELECT deepest_step, count() AS devices
FROM (
  SELECT
    distinct_id,
    windowFunnel({days} * 24 * 3600)(toDateTime(timestamp),
      event = 'app_launched',
      event IN ('onboarding_shown', 'onboarding_step_viewed'),
      event = 'onboarding_completed',
      event IN ('dictation_started', 'onboarding_first_dictation_started', 'meeting_recording_started'),
      event IN ('activation_first_artifact_saved', 'onboarding_first_dictation_saved', 'meeting_transcript_saved', 'dictation_completed'),
      event IN ('activation_artifact_action_clicked', 'activation_agent_prompt_action_clicked'),
      event IN ('activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked')
    ) AS deepest_step
  FROM events
  WHERE timestamp >= now() - INTERVAL {days} DAY
    AND {event_filter(ACTIVATION_EVENTS)}
    {app_version_filter(app_version)}
  GROUP BY distinct_id
)
GROUP BY deepest_step
ORDER BY deepest_step ASC
""",
        ),
        QuerySpec(
            id="activation.return_windows",
            family="activation",
            title="Return proxy windows",
            description="Counts return-proxy events by coarse return window and prior artifact kind.",
            columns=("return_window_bucket", "prior_artifact_kind", "surface", "events", "devices"),
            sql=f"""
SELECT
  properties['return_window_bucket'] AS return_window_bucket,
  properties['prior_artifact_kind'] AS prior_artifact_kind,
  properties['surface'] AS surface,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event = 'activation_return_proxy_observed'
  {app_version_filter(app_version)}
GROUP BY return_window_bucket, prior_artifact_kind, surface
ORDER BY devices DESC
LIMIT 40
""",
        ),
        QuerySpec(
            id="meeting_prompt_quality.prompt_outcomes",
            family="meeting_prompt_quality",
            title="Meeting prompt outcome quality",
            description="Measures detected-meeting prompt reach, choice, acceptance, outcome, dismissal, suppression, and missed-call nudges by coarse signal buckets.",
            columns=("provider", "source", "prompt_reason", "route_ready", "choice_kind", "outcome_kind", "elapsed_bucket", "shown_events", "choice_events", "record_selected_events", "outcome_events", "dismissed_events", "suppressed_events", "missed_call_nudges", "devices"),
            sql=f"""
SELECT
  properties['provider'] AS provider,
  properties['source'] AS source,
  properties['prompt_reason'] AS prompt_reason,
  properties['route_ready'] AS route_ready,
  properties['choice_kind'] AS choice_kind,
  properties['outcome_kind'] AS outcome_kind,
  properties['elapsed_bucket'] AS elapsed_bucket,
  countIf(event = 'meeting_prompt_shown') AS shown_events,
  countIf(event = 'meeting_prompt_choice_made') AS choice_events,
  countIf(event = 'meeting_prompt_record_selected') AS record_selected_events,
  countIf(event = 'meeting_prompt_outcome_recorded') AS outcome_events,
  countIf(event = 'meeting_prompt_dismissed') AS dismissed_events,
  countIf(event = 'meeting_prompt_suppressed') AS suppressed_events,
  countIf(event = 'meeting_missed_call_nudge') AS missed_call_nudges,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(MEETING_PROMPT_EVENTS)}
  {app_version_filter(app_version)}
GROUP BY provider, source, prompt_reason, route_ready, choice_kind, outcome_kind, elapsed_bucket
ORDER BY shown_events DESC, devices DESC
LIMIT 80
""",
        ),
        QuerySpec(
            id="meeting_prompt_quality.suppression_reasons",
            family="meeting_prompt_quality",
            title="Meeting prompt suppression and dismissal reasons",
            description="Ranks coarse prompt suppression, cooldown, and missing-permission buckets.",
            columns=("event", "suppression_reason", "cooldown_reason", "missing_permission", "backoff_kind", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['suppression_reason'] AS suppression_reason,
  properties['cooldown_reason'] AS cooldown_reason,
  properties['missing_permission'] AS missing_permission,
  properties['backoff_kind'] AS backoff_kind,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('meeting_prompt_dismissed', 'meeting_prompt_suppressed')
  {app_version_filter(app_version)}
GROUP BY event, suppression_reason, cooldown_reason, missing_permission, backoff_kind
ORDER BY events DESC
LIMIT 80
""",
        ),
        QuerySpec(
            id="activation.habit_loop_summary",
            family="activation",
            title="Post-save habit loop summary",
            description="Answers daily-return loop questions from aggregate first/second artifact, agent payoff, and return action events.",
            columns=(
                "first_artifact_devices",
                "second_artifact_devices",
                "agent_payoff_devices",
                "next_day_return_devices",
                "seven_day_return_devices",
                "review_yesterday_devices",
                "promise_review_devices",
                "open_recent_meeting_devices",
                "daily_digest_devices",
            ),
            sql=f"""
SELECT
  uniqIf(distinct_id, event = 'activation_first_artifact_saved') AS first_artifact_devices,
  uniqIf(distinct_id, event = 'activation_second_artifact_saved') AS second_artifact_devices,
  uniqIf(distinct_id, event = 'agent_capture_query_observed') AS agent_payoff_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed' AND properties['return_window_bucket'] = '18_36h') AS next_day_return_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed' AND properties['return_window_bucket'] IN ('36_72h', '3_7d')) AS seven_day_return_devices,
  uniqIf(distinct_id, event = 'activation_habit_loop_actioned' AND properties['action_kind'] = 'review_yesterday' AND properties['result'] IN ('success', 'fallback')) AS review_yesterday_devices,
  uniqIf(distinct_id, event = 'activation_habit_loop_actioned' AND properties['action_kind'] = 'what_did_i_promise' AND properties['result'] IN ('success', 'fallback')) AS promise_review_devices,
  uniqIf(distinct_id, event = 'activation_habit_loop_actioned' AND properties['action_kind'] = 'open_recent_meeting' AND properties['result'] IN ('success', 'fallback')) AS open_recent_meeting_devices,
  uniqIf(distinct_id, event = 'activation_habit_loop_actioned' AND properties['action_kind'] IN ('daily_digest_viewed', 'daily_digest_exported') AND properties['result'] IN ('success', 'fallback')) AS daily_digest_devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('activation_first_artifact_saved', 'activation_second_artifact_saved', 'agent_capture_query_observed', 'activation_return_proxy_observed', 'activation_habit_loop_actioned')
  {app_version_filter(app_version)}
""",
            notes=(
                "Daily digest rows stay zero until a UI seam calls ActivationTelemetry.trackHabitLoopAction for viewed/exported.",
                "The summary counts only success/fallback habit-loop outcomes; failed attempts remain visible in activation.habit_loop_actions.",
            ),
        ),
        QuerySpec(
            id="activation.habit_loop_actions",
            family="activation",
            title="Post-save habit loop actions",
            description="Breaks review-yesterday, promise-review, recent-meeting, digest, and return-after-artifact actions by coarse buckets.",
            columns=("action_kind", "artifact_kind", "return_window_bucket", "surface", "result", "events", "devices"),
            sql=f"""
SELECT
  properties['action_kind'] AS action_kind,
  properties['artifact_kind'] AS artifact_kind,
  properties['return_window_bucket'] AS return_window_bucket,
  properties['surface'] AS surface,
  properties['result'] AS result,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event = 'activation_habit_loop_actioned'
  {app_version_filter(app_version)}
GROUP BY action_kind, artifact_kind, return_window_bucket, surface, result
ORDER BY devices DESC, events DESC
LIMIT 60
""",
        ),
        QuerySpec(
            id="artifact_usefulness.saved_and_used_artifacts",
            family="artifact_usefulness",
            title="Saved artifact usefulness",
            description="Compares saved durable artifacts, second artifacts, artifact actions, habit actions, and return proxy by coarse artifact buckets.",
            columns=("artifact_kind", "surface", "saved_events", "second_artifact_events", "action_events", "habit_loop_events", "return_proxy_events", "devices"),
            sql=f"""
SELECT
  coalesce(properties['artifact_kind'], properties['second_artifact_kind'], properties['prior_artifact_kind']) AS artifact_kind,
  properties['surface'] AS surface,
  countIf(event IN ('activation_first_artifact_saved', 'dictation_artifact_saved', 'dictation_completed', 'meeting_transcript_saved')) AS saved_events,
  countIf(event = 'activation_second_artifact_saved') AS second_artifact_events,
  countIf(event = 'activation_artifact_action_clicked') AS action_events,
  countIf(event = 'activation_habit_loop_actioned') AS habit_loop_events,
  countIf(event = 'activation_return_proxy_observed') AS return_proxy_events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(ARTIFACT_EVENTS)}
  {app_version_filter(app_version)}
GROUP BY artifact_kind, surface
ORDER BY devices DESC, saved_events DESC
LIMIT 80
""",
            notes=("This proves artifact saves/actions/returns, not transcript content quality.",),
        ),
        QuerySpec(
            id="artifact_usefulness.second_value_moment",
            family="artifact_usefulness",
            title="Second saved artifact moment",
            description="Shows second durable artifact saves by first/second kind and days-since-first bucket.",
            columns=("first_artifact_kind", "second_artifact_kind", "days_since_first_bucket", "surface", "events", "devices"),
            sql=f"""
SELECT
  properties['first_artifact_kind'] AS first_artifact_kind,
  properties['second_artifact_kind'] AS second_artifact_kind,
  properties['days_since_first_bucket'] AS days_since_first_bucket,
  properties['surface'] AS surface,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event = 'activation_second_artifact_saved'
  {app_version_filter(app_version)}
GROUP BY first_artifact_kind, second_artifact_kind, days_since_first_bucket, surface
ORDER BY devices DESC, events DESC
LIMIT 60
""",
        ),
        QuerySpec(
            id="agent_payoff.agent_loop",
            family="agent_payoff",
            title="Agent payoff loop",
            description="Compares agent setup/prompt intent to true saved-capture query observations and local meeting-summary outcomes.",
            columns=("event", "agent_target", "query_kind", "result", "surface", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['agent_target'] AS agent_target,
  properties['query_kind'] AS query_kind,
  properties['result'] AS result,
  properties['surface'] AS surface,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(AGENT_PAYOFF_EVENTS)}
  {app_version_filter(app_version)}
GROUP BY event, agent_target, query_kind, result, surface
ORDER BY devices DESC, events DESC
LIMIT 80
""",
            notes=("Prompt/setup rows are intent. `agent_capture_query_observed` is the stronger saved-capture query proof; answer quality remains unknown.",),
        ),
        QuerySpec(
            id="agent_payoff.capture_query_quality",
            family="agent_payoff",
            title="Saved-capture query quality proxy",
            description="Breaks true agent saved-capture query observations by source-count, return-window, capture-age, and result buckets.",
            columns=("agent_target", "query_kind", "source_count_bucket", "capture_age_bucket", "return_window_bucket", "result", "events", "devices"),
            sql=f"""
SELECT
  properties['agent_target'] AS agent_target,
  properties['query_kind'] AS query_kind,
  properties['source_count_bucket'] AS source_count_bucket,
  properties['capture_age_bucket'] AS capture_age_bucket,
  properties['return_window_bucket'] AS return_window_bucket,
  properties['result'] AS result,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event = 'agent_capture_query_observed'
  {app_version_filter(app_version)}
GROUP BY agent_target, query_kind, source_count_bucket, capture_age_bucket, return_window_bucket, result
ORDER BY devices DESC, events DESC
LIMIT 80
""",
        ),
        QuerySpec(
            id="speaker_trust.review_outcomes",
            family="speaker_trust",
            title="Speaker review trust",
            description="Counts speaker review shown/submitted/match-reviewed/auto-recognized outcomes by coarse confidence and review buckets.",
            columns=("event", "channel", "review_action", "completion_kind", "result", "had_suggestion", "similarity_bucket", "margin_bucket", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['channel'] AS channel,
  properties['review_action'] AS review_action,
  properties['completion_kind'] AS completion_kind,
  properties['result'] AS result,
  properties['had_suggestion'] AS had_suggestion,
  properties['similarity_bucket'] AS similarity_bucket,
  properties['margin_bucket'] AS margin_bucket,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(SPEAKER_TRUST_EVENTS)}
  {app_version_filter(app_version)}
GROUP BY event, channel, review_action, completion_kind, result, had_suggestion, similarity_bucket, margin_bucket
ORDER BY events DESC
LIMIT 80
""",
        ),
        QuerySpec(
            id="speaker_trust.finalization_failures",
            family="speaker_trust",
            title="Speaker finalization failures",
            description="Ranks coarse speaker finalization failure buckets without speaker names or transcript text.",
            columns=("failure_kind", "session_stage", "trigger", "queue_depth_bucket", "events", "devices"),
            sql=f"""
SELECT
  properties['failure_kind'] AS failure_kind,
  properties['session_stage'] AS session_stage,
  properties['trigger'] AS trigger,
  properties['queue_depth_bucket'] AS queue_depth_bucket,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event = 'meeting_speaker_finalization_failed'
  {app_version_filter(app_version)}
GROUP BY failure_kind, session_stage, trigger, queue_depth_bucket
ORDER BY events DESC
LIMIT 50
""",
        ),
        QuerySpec(
            id="retry_recovery.workflow_recovery",
            family="retry_recovery",
            title="Workflow retry and recovery",
            description="Tracks recovery attempts and outcomes by workflow, retry source, failure kind, and artifact-retained buckets.",
            columns=("event", "workflow_kind", "failure_kind", "retry_source", "artifact_retained", "result", "recovery_attempt_bucket", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['workflow_kind'] AS workflow_kind,
  properties['failure_kind'] AS failure_kind,
  properties['retry_source'] AS retry_source,
  properties['artifact_retained'] AS artifact_retained,
  properties['result'] AS result,
  properties['recovery_attempt_bucket'] AS recovery_attempt_bucket,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('workflow_recovery_attempted', 'workflow_recovery_finished', 'workflow_recovery_failed', 'meeting_saved_audio_retranscription_requested')
  {app_version_filter(app_version)}
GROUP BY event, workflow_kind, failure_kind, retry_source, artifact_retained, result, recovery_attempt_bucket
ORDER BY events DESC
LIMIT 80
""",
        ),
        QuerySpec(
            id="retry_recovery.failure_rates",
            family="retry_recovery",
            title="Workflow failure rates",
            description="Top-level dictation and meeting failure/recovery counters for health checks.",
            columns=(
                "dictation_starts",
                "dictation_start_failures",
                "dictation_completed",
                "dictation_no_speech",
                "dictation_recovery_timeouts",
                "meeting_starts",
                "meeting_start_failures",
                "meeting_saved",
                "meeting_failed_or_skipped",
                "recovery_finished",
                "recovery_failed",
            ),
            sql=f"""
SELECT
  countIf(event = 'dictation_started') AS dictation_starts,
  countIf(event = 'dictation_start_failed') AS dictation_start_failures,
  countIf(event = 'dictation_completed') AS dictation_completed,
  countIf(event = 'dictation_no_speech') AS dictation_no_speech,
  countIf(event = 'dictation_audio_route_recovery_timeout') AS dictation_recovery_timeouts,
  countIf(event = 'meeting_recording_started') AS meeting_starts,
  countIf(event = 'meeting_recording_start_failed') AS meeting_start_failures,
  countIf(event = 'meeting_transcript_saved') AS meeting_saved,
  countIf(event IN ('meeting_transcript_failed', 'meeting_transcript_skipped')) AS meeting_failed_or_skipped,
  countIf(event = 'workflow_recovery_finished') AS recovery_finished,
  countIf(event = 'workflow_recovery_failed') AS recovery_failed
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(RETRY_RECOVERY_EVENTS)}
  {app_version_filter(app_version)}
""",
        ),
        QuerySpec(
            id="retry_recovery.failure_kinds",
            family="retry_recovery",
            title="Failure kinds",
            description="Ranks coarse failure_kind buckets for failed start/transcript/import/summary outcomes.",
            columns=("event", "failure_kind", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['failure_kind'] AS failure_kind,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('dictation_start_failed', 'meeting_recording_start_failed', 'meeting_transcript_failed', 'meeting_transcript_skipped', 'meeting_file_import_failed', 'local_meeting_summary_cancelled', 'local_meeting_summary_failed')
  {app_version_filter(app_version)}
GROUP BY event, failure_kind
ORDER BY events DESC
LIMIT 40
""",
        ),
        QuerySpec(
            id="retry_recovery.abandonment_exits",
            family="retry_recovery",
            title="Workflow abandonment exits",
            description="Maps coarse places where users left blocked, failed, cancelled, or dismissed workflows.",
            columns=("workflow_kind", "stage", "reason_kind", "elapsed_bucket", "events", "devices"),
            sql=f"""
SELECT
  properties['workflow_kind'] AS workflow_kind,
  properties['stage'] AS stage,
  properties['reason_kind'] AS reason_kind,
  properties['elapsed_bucket'] AS elapsed_bucket,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event = 'workflow_abandoned'
  {app_version_filter(app_version)}
GROUP BY workflow_kind, stage, reason_kind, elapsed_bucket
ORDER BY events DESC
LIMIT 50
""",
            notes=("This is an exit map, not a complete clickstream.",),
        ),
        QuerySpec(
            id="retry_recovery.latency_buckets",
            family="retry_recovery",
            title="Dictation stop latency buckets",
            description="Counts coarse stop-to-done, save, paste, and decode buckets.",
            columns=("stop_to_done_bucket", "decode_bucket", "save_bucket", "paste_bucket", "outcome", "events", "devices"),
            sql=f"""
SELECT
  properties['stop_to_done_bucket'] AS stop_to_done_bucket,
  properties['decode_bucket'] AS decode_bucket,
  properties['save_bucket'] AS save_bucket,
  properties['paste_bucket'] AS paste_bucket,
  properties['outcome'] AS outcome,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event = 'dictation_stop_latency_measured'
  {app_version_filter(app_version)}
GROUP BY stop_to_done_bucket, decode_bucket, save_bucket, paste_bucket, outcome
ORDER BY events DESC
LIMIT 50
""",
        ),
        QuerySpec(
            id="onboarding_friction.step_friction",
            family="onboarding_friction",
            title="Onboarding friction by step",
            description="Counts onboarding views, CTAs, permission changes, dismissals, and product-friction events by coarse step/stage buckets.",
            columns=("event", "step_id", "step_index", "stage", "reason_kind", "permission_kind", "model_state", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['step_id'] AS step_id,
  properties['step_index'] AS step_index,
  properties['stage'] AS stage,
  properties['reason_kind'] AS reason_kind,
  properties['permission_kind'] AS permission_kind,
  properties['model_state'] AS model_state,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(ONBOARDING_FRICTION_EVENTS)}
  {app_version_filter(app_version)}
GROUP BY event, step_id, step_index, stage, reason_kind, permission_kind, model_state
ORDER BY events DESC
LIMIT 100
""",
        ),
        QuerySpec(
            id="artifact_usefulness.artifact_and_agent_actions",
            family="artifact_usefulness",
            title="Artifact and agent action adoption",
            description="Shows open/reveal/summary/copy/setup actions by surface and coarse artifact/agent fields.",
            columns=("event", "surface", "artifact_kind", "action_kind", "result", "trigger", "duration_bucket", "agent_target", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['surface'] AS surface,
  properties['artifact_kind'] AS artifact_kind,
  properties['action_kind'] AS action_kind,
  properties['result'] AS result,
  properties['trigger'] AS trigger,
  properties['duration_bucket'] AS duration_bucket,
  properties['agent_target'] AS agent_target,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('activation_artifact_action_clicked', 'activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked')
  {app_version_filter(app_version)}
GROUP BY event, surface, artifact_kind, action_kind, result, trigger, duration_bucket, agent_target
ORDER BY events DESC
LIMIT 60
""",
        ),
        QuerySpec(
            id="onboarding_friction.permission_readiness",
            family="onboarding_friction",
            title="Onboarding permission readiness",
            description="Shows onboarding completion and permission-status buckets that explain first-run readiness.",
            columns=("completion_flow", "meeting_recording_ready", "calendar_status", "permission_kind", "to_status", "events", "devices"),
            sql=f"""
SELECT
  properties['completion_flow'] AS completion_flow,
  properties['meeting_recording_ready'] AS meeting_recording_ready,
  properties['calendar_status'] AS calendar_status,
  properties['permission_kind'] AS permission_kind,
  properties['to_status'] AS to_status,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('onboarding_completed', 'onboarding_permission_status_changed')
  {app_version_filter(app_version)}
GROUP BY completion_flow, meeting_recording_ready, calendar_status, permission_kind, to_status
ORDER BY events DESC
LIMIT 80
""",
        ),
        QuerySpec(
            id="timeline_dayflow.dayflow_events",
            family="timeline_dayflow",
            title="Timeline Dayflow adoption",
            description="Queries shipped timeline/dayflow analytics by coarse provider, surface, card, and result buckets when those events are present.",
            columns=("event", "provider_kind", "surface", "card_kind", "result", "events", "devices", "first_seen", "last_seen"),
            sql=f"""
SELECT
  event,
  properties['provider_kind'] AS provider_kind,
  properties['surface'] AS surface,
  properties['card_kind'] AS card_kind,
  properties['result'] AS result,
  count() AS events,
  uniq(distinct_id) AS devices,
  min(timestamp) AS first_seen,
  max(timestamp) AS last_seen
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(TIMELINE_DAYFLOW_EVENTS)}
  {app_version_filter(app_version)}
GROUP BY event, provider_kind, surface, card_kind, result
ORDER BY events DESC
LIMIT 80
""",
            notes=("Keep this family separate from shipped release health; Dayflow rows can be sparse by design.",),
        ),
        QuerySpec(
            id="timeline_dayflow.data_quality",
            family="timeline_dayflow",
            title="Timeline Dayflow data quality",
            description="Counts timeline enablement, screen permission, card generation, and markdown write outcomes without screen text, screenshots, app names, or paths.",
            columns=("event", "provider_kind", "permission_state", "card_kind", "result", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['provider_kind'] AS provider_kind,
  properties['permission_state'] AS permission_state,
  properties['card_kind'] AS card_kind,
  properties['result'] AS result,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('timeline_enabled', 'timeline_screen_permission_ready', 'timeline_screen_permission_denied', 'timeline_card_generated', 'timeline_daily_markdown_written')
  {app_version_filter(app_version)}
GROUP BY event, provider_kind, permission_state, card_kind, result
ORDER BY events DESC
LIMIT 50
""",
        ),
        QuerySpec(
            id="release_health.installed_build_outcomes",
            family="release_health",
            title="Installed build launch and outcome counts",
            description="Groups launch, success, and failure events by installed app/build identity so shipped and local/current-main rows stay separate.",
            columns=(
                "app_version",
                "build_version",
                "build_channel",
                "build_revision",
                "launch_events",
                "launch_devices",
                "success_events",
                "success_devices",
                "failure_events",
                "failure_devices",
                "first_seen",
                "last_seen",
            ),
            sql=f"""
SELECT
  properties['app_version'] AS app_version,
  properties['build_version'] AS build_version,
  properties['build_channel'] AS build_channel,
  properties['build_revision'] AS build_revision,
  countIf(event = 'app_launched') AS launch_events,
  uniqIf(distinct_id, event = 'app_launched') AS launch_devices,
  countIf(event IN ('dictation_completed', 'meeting_transcript_saved')) AS success_events,
  uniqIf(distinct_id, event IN ('dictation_completed', 'meeting_transcript_saved')) AS success_devices,
  countIf(event = 'meeting_transcript_failed') AS failure_events,
  uniqIf(distinct_id, event = 'meeting_transcript_failed') AS failure_devices,
  min(timestamp) AS first_seen,
  max(timestamp) AS last_seen
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(RELEASE_WORKFLOW_EVENTS)}
  AND properties['app_version'] IS NOT NULL
  {app_version_filter(app_version)}
GROUP BY app_version, build_version, build_channel, build_revision
ORDER BY launch_devices DESC, launch_events DESC, app_version ASC, build_channel ASC
LIMIT 100
""",
            notes=(
                "This is installed build health only. Rows with build_channel local/dev/main/nightly are current-main proof, not shipped-release proof.",
                "Use update_results for Sparkle target-version health; update events use properties['version'], not installed app_version.",
            ),
        ),
        QuerySpec(
            id="release_health.update_results",
            family="release_health",
            title="Update result breakdown",
            description="Breaks Sparkle update outcomes by coarse result/state/failure kind.",
            columns=("event", "result", "state", "failure_kind", "version", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['result'] AS result,
  properties['state'] AS state,
  properties['failure_kind'] AS failure_kind,
  properties['version'] AS version,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('update_check_finished', 'update_download_finished', 'update_ready_to_install', 'update_installed')
  {version_or_app_version_filter(app_version)}
GROUP BY event, result, state, failure_kind, version
ORDER BY events DESC
LIMIT 80
""",
            notes=("Pass --app-version to filter update target `version`. Keep this separate from installed build health rows.",),
        ),
    ]


def selected_specs(family: str, days: int, app_version: str | None) -> list[QuerySpec]:
    specs = query_specs(days, app_version)
    if family == "all":
        return specs
    return [spec for spec in specs if spec.family == family]


def run_hogql(host: str, project_id: str, token: str, query: str) -> dict[str, Any]:
    return posthog.run_hogql(host, project_id, token, query, PostHogDashboardError)


def rows_as_dicts(response: dict[str, Any], spec: QuerySpec) -> list[dict[str, Any]]:
    try:
        return posthog.rows_as_dicts(
            response,
            DISALLOWED_OUTPUT_FRAGMENTS,
            PostHogDashboardError,
            declared_columns=spec.columns,
        )
    except PostHogDashboardError as exc:
        message = str(exc)
        prefix = "query attempted to expose unsafe output columns: "
        if message.startswith(prefix):
            raise PostHogDashboardError(f"{spec.id} attempted to expose unsafe output columns: {message.removeprefix(prefix)}") from exc
        raise


def unsafe_columns(columns: list[str] | tuple[str, ...]) -> list[str]:
    return [
        str(column)
        for column in columns
        if any(fragment in str(column).lower() for fragment in DISALLOWED_OUTPUT_FRAGMENTS)
    ]


def load_allowed_events(path: Path = ANALYTICS_EVENTS_PATH) -> set[str]:
    if not path.is_absolute():
        path = Path(__file__).resolve().parents[2] / path
    allowed: set[str] = set()
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        event_name = line.split("|", 1)[0].strip()
        if event_name:
            allowed.add(event_name)
    return allowed


def sql_event_literals(sql: str) -> set[str]:
    events: set[str] = set()
    for match in EVENT_LITERAL_RE.finditer(sql):
        single, in_list = match.groups()
        if single:
            events.add(single)
        if in_list:
            events.update(STRING_LITERAL_RE.findall(in_list))
    return events


def referenced_events(specs: list[QuerySpec]) -> set[str]:
    events: set[str] = set()
    for spec in specs:
        events.update(sql_event_literals(spec.sql))
    return events


def event_taxonomy_errors(
    specs: list[QuerySpec],
    allowed_events: set[str],
    require_required_coverage: bool,
) -> list[str]:
    errors: list[str] = []
    referenced = referenced_events(specs)
    missing = sorted(referenced - allowed_events)
    if missing:
        errors.append("query catalog references event(s) outside analytics-events.psv: " + ", ".join(missing))
    missing_required = sorted(event for event in REQUIRED_TAXONOMY_EVENTS if event not in allowed_events)
    if missing_required:
        errors.append("required product-learning event(s) missing from analytics-events.psv: " + ", ".join(missing_required))
    if require_required_coverage:
        unqueried_required = sorted(event for event in REQUIRED_TAXONOMY_EVENTS if event not in referenced)
        if unqueried_required:
            errors.append("required product-learning event(s) missing from dashboard query catalog: " + ", ".join(unqueried_required))
    return errors


def spec_payload(specs: list[QuerySpec], days: int, app_version: str | None) -> dict[str, Any]:
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mode": "dry_run",
        "window_days": days,
        "app_version": app_version,
        "privacy": "Query specs aggregate anonymous devices and events only. Output columns are enum buckets, counts, timestamps, and public versions; no people rows, raw IDs, transcript text, audio references, titles, paths, URLs, emails, or tokens.",
        "families": sorted({spec.family for spec in specs}),
        "queries": [
            {
                "id": spec.id,
                "family": spec.family,
                "title": spec.title,
                "description": spec.description,
                "columns": list(spec.columns),
                "notes": list(spec.notes),
                "hogql": clean_sql(spec.sql),
            }
            for spec in specs
        ],
    }


def execute_payload(specs: list[QuerySpec], days: int, app_version: str | None) -> dict[str, Any]:
    load_env()
    host, project_id, token = posthog_config()
    queries: list[dict[str, Any]] = []
    for spec in specs:
        response = run_hogql(host, project_id, token, spec.sql)
        queries.append(
            {
                "id": spec.id,
                "family": spec.family,
                "title": spec.title,
                "description": spec.description,
                "columns": list(spec.columns),
                "notes": list(spec.notes),
                "rows": rows_as_dicts(response, spec),
            }
        )
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mode": "live",
        "window_days": days,
        "app_version": app_version,
        "source": {
            "kind": "posthog_hogql_aggregate",
            "host": host,
            "project": "configured PostHog project",
        },
        "privacy": "Aggregate rows only; no user IDs, people rows, transcript text, audio references, titles, paths, URLs, emails, or tokens are written.",
        "families": sorted({spec.family for spec in specs}),
        "queries": queries,
    }


def observed_events_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  count() AS events,
  uniq(distinct_id) AS devices,
  min(timestamp) AS first_seen,
  max(timestamp) AS last_seen
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  {app_version_filter(app_version)}
GROUP BY event
ORDER BY event ASC
LIMIT 1000
"""


def observed_event_rows_from_response(response: dict[str, Any]) -> list[dict[str, Any]]:
    return posthog.rows_as_dicts(
        response,
        DISALLOWED_OUTPUT_FRAGMENTS,
        PostHogDashboardError,
        declared_columns=("event", "events", "devices", "first_seen", "last_seen"),
    )


def observed_event_rows_from_fixture(path: Path) -> list[dict[str, Any]]:
    fixture = load_fixture(path)
    rows = fixture.get("observed_events")
    if rows is None:
        rows = fixture.get("events")
    if not isinstance(rows, list):
        raise PostHogDashboardError(f"observed-event fixture must contain an observed_events array: {path}")
    for row in rows:
        if not isinstance(row, dict) or not row.get("event"):
            raise PostHogDashboardError(f"observed-event fixture row is missing event: {row!r}")
    return rows


def observed_taxonomy_payload(
    rows: list[dict[str, Any]],
    days: int,
    app_version: str | None,
    mode: str,
) -> dict[str, Any]:
    allowed_events = load_allowed_events()
    unknown = sorted({str(row.get("event")) for row in rows if str(row.get("event")) not in allowed_events})
    required_present = sorted(event for event in REQUIRED_TAXONOMY_EVENTS if event in allowed_events)
    observed_required = sorted(event for event in required_present if any(row.get("event") == event for row in rows))
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mode": mode,
        "window_days": days,
        "app_version": app_version,
        "source": {
            "kind": "fixture_observed_event_aggregates" if mode == "fixture" else "posthog_hogql_event_name_aggregates",
        },
        "privacy": "Observed-event taxonomy checks use aggregate event-name rows only: event name, event count, anonymous device count, and first/last seen timestamps. They never request people rows, distinct IDs, transcripts, audio references, titles, paths, URLs, emails, or tokens.",
        "allowed_event_count": len(allowed_events),
        "observed_event_count": len({str(row.get("event")) for row in rows}),
        "unknown_events": unknown,
        "required_taxonomy_events": required_present,
        "observed_required_taxonomy_events": observed_required,
        "observed_events": rows,
    }


def execute_taxonomy_payload(days: int, app_version: str | None) -> dict[str, Any]:
    load_env()
    host, project_id, token = posthog_config()
    response = run_hogql(host, project_id, token, observed_events_query(days, app_version))
    payload = observed_taxonomy_payload(observed_event_rows_from_response(response), days, app_version, "live")
    payload["source"]["host"] = host
    payload["source"]["project"] = "configured PostHog project"
    return payload


def clean_sql(sql: str) -> str:
    return "\n".join(line.rstrip() for line in sql.strip().splitlines())


def md_table(headers: list[str], rows: list[list[Any]]) -> str:
    def clean(value: Any) -> str:
        if value is True:
            return "true"
        if value is False:
            return "false"
        if value is None or value == "":
            return "-"
        return str(value).replace("|", "\\|").replace("\n", " ")

    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(clean(value) for value in row) + " |")
    return "\n".join(lines)


def render_markdown(payload: dict[str, Any]) -> str:
    lines = [
        "# Transcripted PostHog Dashboard Queries",
        "",
        f"Generated: {payload['generated_at']}",
        f"Mode: {payload['mode']}",
        f"Window: last {payload['window_days']} days",
        f"App version: {payload.get('app_version') or 'all app versions'}",
        "",
        payload["privacy"],
        "",
    ]
    by_family: dict[str, list[dict[str, Any]]] = {}
    for query in payload["queries"]:
        by_family.setdefault(query["family"], []).append(query)

    for family in FAMILIES:
        queries = by_family.get(family)
        if not queries:
            continue
        lines.extend(["## " + family.replace("_", " ").title(), ""])
        for query in queries:
            lines.extend(
                [
                    "### " + query["id"],
                    "",
                    query["description"],
                    "",
                    "Output columns: `" + "`, `".join(query["columns"]) + "`.",
                    "",
                ]
            )
            for note in query.get("notes") or []:
                lines.extend([f"- {note}", ""])
            if "hogql" in query:
                lines.extend(["```sql", query["hogql"], "```", ""])
            if "rows" in query:
                rows = query.get("rows") or []
                if rows:
                    headers = list(query["columns"])
                    lines.extend([md_table(headers, [[row.get(column) for column in headers] for row in rows[:12]]), ""])
                else:
                    lines.extend(["No rows returned.", ""])
    return "\n".join(lines)


def render_taxonomy_markdown(payload: dict[str, Any]) -> str:
    unknown = payload.get("unknown_events") or []
    rows = payload.get("observed_events") or []
    required_observed = set(payload.get("observed_required_taxonomy_events") or [])
    required_rows = [
        [
            event,
            "observed" if event in required_observed else "not observed",
        ]
        for event in payload.get("required_taxonomy_events") or []
    ]
    event_rows = [
        [
            row.get("event"),
            row.get("events"),
            row.get("devices"),
            row.get("first_seen"),
            row.get("last_seen"),
        ]
        for row in rows[:80]
    ]
    lines = [
        "# Transcripted PostHog Observed Event Taxonomy Check",
        "",
        f"Generated: {payload['generated_at']}",
        f"Mode: {payload['mode']}",
        f"Window: last {payload['window_days']} days",
        f"App version: {payload.get('app_version') or 'all app versions'}",
        "",
        payload["privacy"],
        "",
        f"Allowed events: {payload['allowed_event_count']}",
        f"Observed events: {payload['observed_event_count']}",
        f"Unknown observed events: {len(unknown)}",
        "",
    ]
    if unknown:
        lines.extend(["## Unknown Observed Events", "", md_table(["event"], [[event] for event in unknown]), ""])
    else:
        lines.extend(["No unknown observed event names.", ""])
    lines.extend(["## Recently Merged Product-Learning Events", "", md_table(["event", "fixture/live status"], required_rows), ""])
    if event_rows:
        lines.extend(["## Observed Event Aggregates", "", md_table(["event", "events", "devices", "first_seen", "last_seen"], event_rows), ""])
    return "\n".join(lines)


def render_payload(payload: dict[str, Any]) -> str:
    if "unknown_events" in payload:
        return render_taxonomy_markdown(payload)
    return render_markdown(payload)


def write_outputs(payload: dict[str, Any], markdown: str, write_dir: Path | None) -> tuple[Path, Path]:
    output_dir = write_dir or Path("/tmp/transcripted-posthog-dashboard-queries") / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir.mkdir(parents=True, exist_ok=True)
    markdown_path = output_dir / "posthog-dashboard-queries.md"
    json_path = output_dir / "posthog-dashboard-queries.json"
    markdown_path.write_text(markdown, encoding="utf-8")
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return markdown_path, json_path


def load_fixture(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PostHogDashboardError(f"fixture could not be read: {path}: {exc}") from exc


def fixture_payload(path: Path, family: str, days: int, app_version: str | None) -> dict[str, Any]:
    fixture = load_fixture(path)
    specs = selected_specs(family, days, app_version)
    spec_ids = {spec.id for spec in specs}
    queries = [query for query in fixture.get("queries", []) if query.get("id") in spec_ids]
    by_id = {spec.id: spec for spec in specs}
    for query in queries:
        spec = by_id[str(query["id"])]
        query["family"] = spec.family
        query["title"] = spec.title
        query["description"] = spec.description
        query["columns"] = list(spec.columns)
        query["notes"] = list(spec.notes)
        unsafe = unsafe_columns(query["columns"])
        if unsafe:
            raise PostHogDashboardError(f"fixture query {spec.id} has unsafe output columns: {', '.join(unsafe)}")
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mode": "fixture",
        "window_days": days,
        "app_version": app_version,
        "privacy": "Synthetic fixture rows only. Counts and buckets are fake and contain no private data.",
        "families": sorted({query["family"] for query in queries}),
        "queries": queries,
    }


def validate_specs(specs: list[QuerySpec], require_all_families: bool = False) -> list[str]:
    errors: list[str] = []
    allowed_events = load_allowed_events()
    seen: set[str] = set()
    for spec in specs:
        if spec.id in seen:
            errors.append(f"duplicate query id: {spec.id}")
        seen.add(spec.id)
        unsafe = unsafe_columns(spec.columns)
        if unsafe:
            errors.append(f"{spec.id} exposes unsafe output column(s): {', '.join(unsafe)}")
        sql_upper = spec.sql.upper()
        if "SELECT *" in sql_upper:
            errors.append(f"{spec.id} uses SELECT *")
        if spec.family not in FAMILIES:
            errors.append(f"{spec.id} uses unknown family {spec.family}")
    if require_all_families:
        missing = sorted(set(FAMILIES) - {spec.family for spec in specs})
        if missing:
            errors.append("missing family specs: " + ", ".join(missing))
    errors.extend(event_taxonomy_errors(specs, allowed_events, require_required_coverage=require_all_families))
    return errors


def run_self_test() -> int:
    specs = query_specs(30, "1.1.48")
    errors = validate_specs(specs, require_all_families=True)
    try:
        payload = fixture_payload(FIXTURE_PATH, "all", 30, "1.1.48")
    except PostHogDashboardError as exc:
        errors.append(str(exc))
        payload = {"queries": []}
    try:
        taxonomy_payload = observed_taxonomy_payload(
            observed_event_rows_from_fixture(OBSERVED_FIXTURE_PATH),
            30,
            "1.1.48",
            "fixture",
        )
        if taxonomy_payload["unknown_events"]:
            errors.append("observed-event fixture contains event(s) outside analytics-events.psv: " + ", ".join(taxonomy_payload["unknown_events"]))
        if "agent_capture_query_observed" not in taxonomy_payload["observed_required_taxonomy_events"]:
            errors.append("observed-event fixture should include agent_capture_query_observed")
        if "workflow_recovery_finished" not in taxonomy_payload["observed_required_taxonomy_events"]:
            errors.append("observed-event fixture should include workflow_recovery_finished")
        if "meeting_prompt_outcome_recorded" not in taxonomy_payload["observed_required_taxonomy_events"]:
            errors.append("observed-event fixture should include meeting_prompt_outcome_recorded")
    except PostHogDashboardError as exc:
        errors.append(str(exc))
    fallback_rows = posthog.rows_as_dicts(
        {"results": [["2026-06-18", 24]]},
        DISALLOWED_OUTPUT_FRAGMENTS,
        PostHogDashboardError,
        declared_columns=("day", "active_devices"),
    )
    if fallback_rows != [{"day": "2026-06-18", "active_devices": 24}]:
        errors.append("column-less response fallback did not use declared columns")
    rendered = render_markdown(payload)
    required = (
        "wau.active_devices_by_week",
        "activation.reach_ladder",
        "meeting_prompt_quality.prompt_outcomes",
        "artifact_usefulness.saved_and_used_artifacts",
        "agent_payoff.agent_loop",
        "speaker_trust.review_outcomes",
        "retry_recovery.failure_rates",
        "onboarding_friction.step_friction",
        "timeline_dayflow.dayflow_events",
        "release_health.installed_build_outcomes",
    )
    for query_id in required:
        if query_id not in rendered:
            errors.append(f"fixture render missing {query_id}")
    habit_summary = next((spec for spec in specs if spec.id == "activation.habit_loop_summary"), None)
    if habit_summary and "properties['result'] IN ('success', 'fallback')" not in habit_summary.sql:
        errors.append("habit-loop summary must exclude failed outcomes from success shortcut counts")
    habit_actions = next((query for query in payload.get("queries", []) if query.get("id") == "activation.habit_loop_actions"), None)
    action_rows = habit_actions.get("rows", []) if isinstance(habit_actions, dict) else []
    if not any(row.get("result") == "failed" for row in action_rows):
        errors.append("fixture must include a failed habit-loop action row so result breakdown stays exercised")
    forbidden_output = ("transcript_text", "audio_path", "meeting_title", "raw_url", "email", "token")
    lowered = rendered.lower()
    leaked = [fragment for fragment in forbidden_output if fragment in lowered]
    if leaked:
        errors.append("fixture render contains unsafe fragment(s): " + ", ".join(leaked))
    if errors:
        print("self-test failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("self-test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=("all", *FAMILIES), default="all", help="Dashboard family to print or run.")
    parser.add_argument("--days", type=int, default=30, help="Lookback window in days.")
    parser.add_argument("--app-version", help="Optional app_version/version filter, e.g. 1.1.48.")
    parser.add_argument("--dry-run", action="store_true", help="Print query specs without requiring PostHog credentials.")
    parser.add_argument("--fixture", type=Path, help="Render synthetic fixture rows instead of querying PostHog.")
    parser.add_argument("--taxonomy-check", action="store_true", help="Compare observed PostHog event names against Resources/analytics-events.psv.")
    parser.add_argument("--observed-fixture", type=Path, help="Run --taxonomy-check against a synthetic observed-event aggregate fixture.")
    parser.add_argument("--json-only", action="store_true", help="Print JSON instead of Markdown.")
    parser.add_argument("--write-dir", type=Path, help="Directory for posthog-dashboard-queries.md/json outputs.")
    parser.add_argument("--self-test", action="store_true", help="Run offline fixture/spec/privacy checks.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()
    if args.days <= 0:
        print("ERROR: --days must be positive", file=sys.stderr)
        return 2

    try:
        if args.taxonomy_check:
            if args.observed_fixture:
                payload = observed_taxonomy_payload(
                    observed_event_rows_from_fixture(args.observed_fixture),
                    args.days,
                    args.app_version,
                    "fixture",
                )
            else:
                payload = execute_taxonomy_payload(args.days, args.app_version)
            if payload["unknown_events"]:
                raise PostHogDashboardError("observed event(s) outside analytics-events.psv: " + ", ".join(payload["unknown_events"]))
        else:
            specs = selected_specs(args.family, args.days, args.app_version)
            if not specs:
                print("ERROR: no query specs selected", file=sys.stderr)
                return 2

            spec_errors = validate_specs(specs)
            if spec_errors:
                raise PostHogDashboardError("; ".join(spec_errors))
            if args.fixture:
                payload = fixture_payload(args.fixture, args.family, args.days, args.app_version)
            elif args.dry_run:
                payload = spec_payload(specs, args.days, args.app_version)
            else:
                payload = execute_payload(specs, args.days, args.app_version)
    except PostHogDashboardError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 3

    markdown = render_payload(payload)
    if args.write_dir:
        markdown_path, json_path = write_outputs(payload, markdown, args.write_dir)
    else:
        markdown_path = json_path = None

    if args.json_only:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(markdown)
        if markdown_path and json_path:
            print(f"Report written: {markdown_path}")
            print(f"Data written: {json_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
