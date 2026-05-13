#!/usr/bin/env bash
set -euo pipefail

# support-email-routing-smoke.sh - quick operator check for Transcripted support mail routing
# Usage: bash scripts/ops/support-email-routing-smoke.sh [--api] [--domain transcripted.app] [--address help@transcripted.app]

DOMAIN="${TRANSCRIPTED_SUPPORT_DOMAIN:-transcripted.app}"
ADDRESS="${TRANSCRIPTED_SUPPORT_ADDRESS:-help@transcripted.app}"
API_MODE="auto"

failures=0
warnings=0

usage() {
  cat <<'EOF'
Usage: bash scripts/ops/support-email-routing-smoke.sh [options]

Checks public DNS for Cloudflare Email Routing records. If CLOUDFLARE_API_TOKEN
is present, also checks Cloudflare Email Routing settings and the enabled route
for help@transcripted.app.

Options:
  --api                 Require Cloudflare API checks instead of treating them as optional.
  --no-api              Only run public DNS checks.
  --domain DOMAIN       Domain to check. Default: transcripted.app
  --address ADDRESS     Support address to check. Default: help@transcripted.app
  -h, --help            Show this help.

Optional env:
  CLOUDFLARE_API_TOKEN  Token with Zone:Read and Email Routing Rules Read.
  CLOUDFLARE_ZONE_ID    Optional zone id. If absent, the script looks up the zone by domain.
EOF
}

pass() {
  echo "PASS $1"
}

warn() {
  warnings=$((warnings + 1))
  echo "WARN $1"
}

fail() {
  failures=$((failures + 1))
  echo "FAIL $1"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

compact_lines() {
  tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    fail "$name is not installed; cannot run this smoke check."
    return 1
  fi
}

cloudflare_get() {
  local path="$1"
  curl -fsS \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4${path}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api)
        API_MODE="required"
        shift
        ;;
      --no-api)
        API_MODE="off"
        shift
        ;;
      --domain)
        if [[ $# -lt 2 ]]; then
          echo "--domain requires a value." >&2
          exit 2
        fi
        DOMAIN="${2:-}"
        shift 2
        ;;
      --address)
        if [[ $# -lt 2 ]]; then
          echo "--address requires a value." >&2
          exit 2
        fi
        ADDRESS="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 2
        ;;
    esac
  done

  if [[ -z "$DOMAIN" ]] || [[ -z "$ADDRESS" ]]; then
    echo "Domain and address must be non-empty." >&2
    exit 2
  fi
}

check_mx_records() {
  local mx_records
  mx_records="$(dig +time=5 +tries=1 +short MX "$DOMAIN" || true)"

  if [[ -z "$mx_records" ]]; then
    fail "No MX records found for $DOMAIN."
    return
  fi

  echo "MX records:"
  printf '%s\n' "$mx_records" | sort -n | sed 's/^/  /'

  local expected_targets=(
    "route1.mx.cloudflare.net"
    "route2.mx.cloudflare.net"
    "route3.mx.cloudflare.net"
  )

  local normalized_targets
  normalized_targets="$(printf '%s\n' "$mx_records" | awk '{print $2}' | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')"

  local target
  for target in "${expected_targets[@]}"; do
    if printf '%s\n' "$normalized_targets" | grep -Fxq "$target"; then
      pass "MX includes $target."
    else
      fail "MX is missing $target."
    fi
  done

  local unexpected
  unexpected="$(printf '%s\n' "$normalized_targets" | grep -Ev '^(route1|route2|route3)\.mx\.cloudflare\.net$' || true)"
  if [[ -n "$unexpected" ]]; then
    fail "Unexpected non-Cloudflare MX target(s): $(printf '%s\n' "$unexpected" | compact_lines)."
  else
    pass "No competing MX targets are published."
  fi
}

check_spf_record() {
  local txt_records
  txt_records="$(dig +time=5 +tries=1 +short TXT "$DOMAIN" || true)"

  if [[ -z "$txt_records" ]]; then
    fail "No TXT records found for $DOMAIN; SPF cannot be checked."
    return
  fi

  local spf_count=0
  local spf_has_cloudflare=0
  local line normalized normalized_lower
  while IFS= read -r line; do
    normalized="$(printf '%s' "$line" | tr -d '"' | sed 's/[[:space:]][[:space:]]*/ /g')"
    normalized_lower="$(lower "$normalized")"
    case "$normalized_lower" in
      v=spf1*)
        spf_count=$((spf_count + 1))
        if printf '%s' "$normalized_lower" | grep -Fq 'include:_spf.mx.cloudflare.net'; then
          spf_has_cloudflare=1
        fi
        ;;
    esac
  done <<< "$txt_records"

  if [[ "$spf_count" -eq 0 ]]; then
    fail "No SPF TXT record found for $DOMAIN."
  elif [[ "$spf_count" -gt 1 ]]; then
    fail "Multiple SPF TXT records found for $DOMAIN; publish exactly one SPF record."
  elif [[ "$spf_has_cloudflare" -eq 1 ]]; then
    pass "SPF includes Cloudflare Email Routing."
  else
    fail "SPF record does not include _spf.mx.cloudflare.net."
  fi
}

check_nameservers() {
  local ns_records
  ns_records="$(dig +time=5 +tries=1 +short NS "$DOMAIN" || true)"

  if [[ -z "$ns_records" ]]; then
    warn "No NS records returned for $DOMAIN."
    return
  fi

  if printf '%s\n' "$ns_records" | grep -Fqi '.ns.cloudflare.com.'; then
    pass "Authoritative nameservers are Cloudflare nameservers."
  else
    warn "$DOMAIN is not currently returning Cloudflare nameservers."
  fi
}

resolve_zone_id() {
  if [[ -n "${CLOUDFLARE_ZONE_ID:-}" ]]; then
    printf '%s' "$CLOUDFLARE_ZONE_ID"
    return 0
  fi

  local response zone_id
  if ! response="$(cloudflare_get "/zones?name=${DOMAIN}")"; then
    return 1
  fi

  zone_id="$(printf '%s' "$response" | jq -r '.result[0].id // empty')"
  if [[ -z "$zone_id" ]]; then
    return 1
  fi

  printf '%s' "$zone_id"
}

check_api_settings() {
  if [[ "$API_MODE" == "off" ]]; then
    return
  fi

  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    if [[ "$API_MODE" == "required" ]]; then
      fail "CLOUDFLARE_API_TOKEN is missing; cannot run required Cloudflare API checks."
    else
      warn "Cloudflare API checks skipped because CLOUDFLARE_API_TOKEN is not set."
    fi
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    fail "curl is not installed; cannot run Cloudflare API checks."
    return
  fi

  if ! command -v jq >/dev/null 2>&1; then
    fail "jq is not installed; cannot parse Cloudflare API responses."
    return
  fi

  local zone_id
  if ! zone_id="$(resolve_zone_id)"; then
    if [[ "$API_MODE" == "required" ]]; then
      fail "Could not resolve Cloudflare zone id for $DOMAIN."
    else
      warn "Cloudflare API checks skipped because the zone id could not be resolved."
    fi
    return
  fi

  local settings
  if settings="$(cloudflare_get "/zones/${zone_id}/email/routing")"; then
    local enabled
    enabled="$(printf '%s' "$settings" | jq -r '.result.enabled // false')"
    if [[ "$enabled" == "true" ]]; then
      pass "Cloudflare Email Routing is enabled for $DOMAIN."
    else
      fail "Cloudflare Email Routing is not enabled for $DOMAIN."
    fi
  else
    if [[ "$API_MODE" == "required" ]]; then
      fail "Could not read Cloudflare Email Routing settings. Check token scopes."
    else
      warn "Could not read Cloudflare Email Routing settings. Check token scopes."
    fi
  fi

  local dns_settings
  if dns_settings="$(cloudflare_get "/zones/${zone_id}/email/routing/dns")"; then
    local missing_dns_count
    missing_dns_count="$(printf '%s' "$dns_settings" | jq '[.result.errors[]?] | length')"
    if [[ "$missing_dns_count" -eq 0 ]]; then
      pass "Cloudflare DNS API reports no missing Email Routing records."
    else
      fail "Cloudflare DNS API reports ${missing_dns_count} missing or invalid Email Routing record(s)."
    fi
  else
    if [[ "$API_MODE" == "required" ]]; then
      fail "Could not read Cloudflare Email Routing DNS status. Check token scopes."
    else
      warn "Could not read Cloudflare Email Routing DNS status. Check token scopes."
    fi
  fi

  check_api_route "$zone_id"
}

check_api_route() {
  local zone_id="$1"
  local rules
  if ! rules="$(cloudflare_get "/zones/${zone_id}/email/routing/rules?enabled=true&per_page=50")"; then
    if [[ "$API_MODE" == "required" ]]; then
      fail "Could not read Cloudflare Email Routing rules. Token needs Email Routing Rules Read."
    else
      warn "Could not read Cloudflare Email Routing rules. Token needs Email Routing Rules Read."
    fi
    return
  fi

  local matching_rules rule_count action_types
  matching_rules="$(printf '%s' "$rules" | jq --arg address "$ADDRESS" '
    [
      .result[]?
      | select(.enabled == true)
      | select(any(.matchers[]?; .type == "literal" and (.field // "to") == "to" and ((.value // "") | ascii_downcase) == ($address | ascii_downcase)))
    ]
  ')"
  rule_count="$(printf '%s' "$matching_rules" | jq 'length')"

  if [[ "$rule_count" -gt 0 ]]; then
    action_types="$(printf '%s' "$matching_rules" | jq -r '[.[].actions[]?.type] | unique | join(", ")')"
    if printf '%s' "$action_types" | grep -Eq '(^|, )(forward|worker)(,|$)'; then
      pass "Found enabled Cloudflare rule for $ADDRESS with action type(s): ${action_types}."
    else
      fail "Found enabled Cloudflare rule for $ADDRESS, but action type is not forward or worker."
    fi
    return
  fi

  local catch_all
  if catch_all="$(cloudflare_get "/zones/${zone_id}/email/routing/rules/catch_all")"; then
    local catch_all_enabled catch_all_actions
    catch_all_enabled="$(printf '%s' "$catch_all" | jq -r '.result.enabled // false')"
    catch_all_actions="$(printf '%s' "$catch_all" | jq -r '[.result.actions[]?.type] | unique | join(", ")')"
    if [[ "$catch_all_enabled" == "true" ]] && printf '%s' "$catch_all_actions" | grep -Eq '(^|, )(forward|worker)(,|$)'; then
      warn "No explicit enabled rule for $ADDRESS, but an enabled catch-all route exists."
      return
    fi
  fi

  fail "No enabled Cloudflare route was found for $ADDRESS."
}

main() {
  parse_args "$@"

  echo "Transcripted support email routing smoke"
  echo "Domain:  $DOMAIN"
  echo "Address: $ADDRESS"
  echo ""

  require_command dig || true
  if [[ "$failures" -eq 0 ]]; then
    check_mx_records
    check_spf_record
    check_nameservers
  fi

  echo ""
  check_api_settings

  echo ""
  if [[ "$failures" -eq 0 ]]; then
    if [[ "$warnings" -eq 0 ]]; then
      echo "OK support email routing smoke passed."
    else
      echo "OK support email routing smoke passed with ${warnings} warning(s)."
    fi
    exit 0
  fi

  echo "ERROR support email routing smoke found ${failures} failure(s) and ${warnings} warning(s)."
  exit 1
}

main "$@"
