#!/usr/bin/env bash
set -euo pipefail

# health-probe.sh - Operational health checks for Transcripted observability lanes
# Usage: bash scripts/ops/health-probe.sh <lane|all>
# Returns 0 on success or skipped lane, 1 if a present-creds probe fails

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../" && pwd)"

usage() {
  echo "Usage: bash scripts/ops/health-probe.sh <github|sentry|posthog|cloudflare|all>"
  exit 0
}

skip_lane() {
  local lane="$1"
  local var_name="$2"
  echo "SKIP $lane: missing $var_name"
  exit 0
}

probe_github() {
  if ! command -v gh &> /dev/null; then
    echo "SKIP github: gh CLI not found"
    exit 0
  fi

  if ! gh auth status &> /dev/null; then
    echo "SKIP github: not authenticated (run 'gh auth login')"
    exit 0
  fi

  echo "GitHub health check..."
  local repo_info
  repo_info=$(gh api repos/r3dbars/transcripted --jq '{name: .name, description: .description, stars: .stargazers_count, forks: .forks_count}')
  echo "Repository: $repo_info"

  local traffic
  traffic=$(gh api repos/r3dbars/transcripted/traffic/views --jq '{views: .views, uniques: .uniques}')
  echo "Traffic (last 14d): $traffic"

  local releases
  releases=$(gh release list -R r3dbars/transcripted --limit 5 --json tagName,name,createdAt,isDraft,isPrerelease --jq '.[] | "\(.tagName) \(.name)"')
  echo "Recent releases:"
  echo "$releases"
}

probe_sentry() {
  if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
    skip_lane "sentry" "SENTRY_AUTH_TOKEN"
  fi

  echo "Sentry health check..."
  local response
  response=$(curl -s -f -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
    "https://sentry.io/api/0/projects/r3dbars/apple-macos/issues/?query=is:unresolved&limit=10" \
    --header "Content-Type: application/json")

  if [[ -z "$response" ]]; then
    echo "Sentry: no unresolved issues"
    return 0
  fi

  local count
  count=$(echo "$response" | jq -r 'length')
  echo "Sentry unresolved issues: $count"

  if [[ "$count" -gt 0 ]]; then
    local top_issue
    top_issue=$(echo "$response" | jq -r '.[0] | "[\(.id)] \(.title)"')
    echo "Top issue: $top_issue"
  fi
}

probe_posthog() {
  if [[ -z "${POSTHOG_PERSONAL_API_KEY:-}" ]] || [[ -z "${POSTHOG_PROJECT_ID:-}" ]]; then
    if [[ -z "${POSTHOG_PERSONAL_API_KEY:-}" ]]; then
      skip_lane "posthog" "POSTHOG_PERSONAL_API_KEY"
    else
      skip_lane "posthog" "POSTHOG_PROJECT_ID"
    fi
  fi

  echo "PostHog health check..."
  local workflow_events onboarding_events first_value_events query payload
  workflow_events="'app_launched','app_unclean_shutdown_detected','app_session_stall_detected','onboarding_completed','dictation_started','dictation_start_failed','dictation_completed','dictation_cancelled','dictation_no_speech','dictation_audio_route_recovery_timeout','meeting_recording_started','meeting_recording_start_failed','meeting_recording_stopped','meeting_recording_cancelled','meeting_transcript_saved','meeting_transcript_failed','meeting_transcript_skipped'"
  onboarding_events="'onboarding_shown','onboarding_step_viewed','onboarding_permission_cta_clicked','onboarding_permission_status_changed','onboarding_model_state_changed','onboarding_primary_cta_clicked','onboarding_first_dictation_started','onboarding_first_dictation_saved','onboarding_first_dictation_stop_clicked','onboarding_first_dictation_empty','onboarding_meeting_dry_run_clicked','onboarding_agent_cta_clicked','onboarding_reporting_toggle_changed','onboarding_completed','onboarding_dismissed'"
  first_value_events="'onboarding_first_dictation_saved','onboarding_agent_cta_clicked'"
  query="select uniq(distinct_id) as devices_7d, sum(case when event in ($workflow_events) then 1 else 0 end) as workflow_events_7d, sum(case when event in ($onboarding_events) then 1 else 0 end) as onboarding_events_7d, sum(case when event in ($first_value_events) then 1 else 0 end) as first_value_events_7d from events where timestamp >= now() - interval 7 day"
  payload=$(jq -cn --arg query "$query" '{query: $query}')

  local response
  response=$(curl -s -f -X POST \
    -H "Authorization: Bearer $POSTHOG_PERSONAL_API_KEY" \
    -H "Content-Type: application/json" \
    "https://us.i.posthog.com/api/projects/$POSTHOG_PROJECT_ID/query/" \
    -d "$payload")

  if [[ -z "$response" ]]; then
    echo "PostHog: query failed"
    return 1
  fi

  local devices events onboarding first_value
  devices=$(echo "$response" | jq -r '.data[0][0]')
  events=$(echo "$response" | jq -r '.data[0][1]')
  onboarding=$(echo "$response" | jq -r '.data[0][2] // 0')
  first_value=$(echo "$response" | jq -r '.data[0][3] // 0')
  echo "PostHog (last 7d): devices=$devices, workflow_events=$events, onboarding_events=$onboarding, first_value_events=$first_value"
}

probe_cloudflare() {
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] || [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
      skip_lane "cloudflare" "CLOUDFLARE_API_TOKEN"
    else
      skip_lane "cloudflare" "CLOUDFLARE_ACCOUNT_ID"
    fi
  fi

  echo "Cloudflare health check..."

  # Get Pages projects
  local projects
  projects=$(curl -s -f -X GET \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects" \
    --header "Content-Type: application/json")

  if [[ -z "$projects" ]]; then
    echo "Cloudflare: unable to fetch Pages projects"
    return 1
  fi

  local project_names=("transcripted-app" "r3d-bar")
  for proj in "${project_names[@]}"; do
    local project_data
    project_data=$(echo "$projects" | jq -r --arg name "$proj" '.result[] | select(.name == $name)')

    if [[ -z "$project_data" ]]; then
      echo "Cloudflare ($proj): not found"
      continue
    fi

    local project_id
    project_id=$(echo "$project_data" | jq -r '.id')

    # Get last deployment
    local deployments
    deployments=$(curl -s -f -X GET \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_id/deployments" \
      --header "Content-Type: application/json")

    local last_deploy
    last_deploy=$(echo "$deployments" | jq -r '.result[0] // {} | "id=\(.uuid) state=\(.deployment_status) created=\(.created_on)"')

    echo "Cloudflare ($proj): $last_deploy"
  done

  # Zone analytics (for both domains)
  local domains=("transcripted.app" "r3d.bar")
  for domain in "${domains[@]}"; do
    local zone_id
    zone_id=$(curl -s -f -X GET \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones?name=$domain" \
      --header "Content-Type: application/json" | jq -r '.result[0].id // empty')

    if [[ -z "$zone_id" ]]; then
      echo "Cloudflare ($domain): zone not found"
      continue
    fi

    local analytics
    analytics=$(curl -s -f -X GET \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/analytics/dashboard?since=3600&zone_tag=$zone_id" \
      --header "Content-Type: application/json")

    local requests unique_visitors
    requests=$(echo "$analytics" | jq -r '.result.sum.requests // "N/A"')
    unique_visitors=$(echo "$analytics" | jq -r '.result.sum.uniques // "N/A"')

    echo "Cloudflare ($domain): requests=$requests, unique_visitors=$unique_visitors"
  done
}

run_all() {
  local failed_lane=""
  local exit_code=0

  for lane in github sentry posthog cloudflare; do
    echo "=== $lane ==="
    if ! probe_$lane; then
      failed_lane="$lane"
      exit_code=1
    fi
    echo ""
  done

  if [[ $exit_code -ne 0 ]]; then
    echo "ERROR: $failed_lane probe failed"
  fi

  exit $exit_code
}

# Main
case "${1:-}" in
  github)
    probe_github
    ;;
  sentry)
    probe_sentry
    ;;
  posthog)
    probe_posthog
    ;;
  cloudflare)
    probe_cloudflare
    ;;
  all)
    run_all
    ;;
  *)
    usage
    ;;
esac
