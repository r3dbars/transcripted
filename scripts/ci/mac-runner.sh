#!/usr/bin/env bash
# Sets up and runs the owner's Mac as self-hosted GitHub Actions runners for
# Swift CI's `checks` and `spm-tests` jobs. See docs/self-hosted-mac-runner.md.
#
# Usage: bash scripts/ci/mac-runner.sh <command>
#   install           register the runners, start them, start the heartbeat
#   status            show runners, heartbeat, and pause state
#   pause | resume    stop / start taking new jobs (running jobs finish)
#   uninstall         stop and unregister everything this script installed
#   heartbeat         (launchd) report idle/busy/paused to the repo variable
#   job-started-hook  (runner) refuse jobs that are not from this repo
#   self-test         check the pure decision logic (runs on Linux too)
#
# Everything lives under $MAC_RUNNER_ROOT (default ~/actions-runners), never in
# the repo checkout: install copies this script there, so switching branches
# in ~/transcripted cannot change what the heartbeat or the hook run.

set -euo pipefail

REPO="${MAC_RUNNER_REPO:-r3dbars/transcripted}"
LABEL="transcripted-mac"
ROOT="${MAC_RUNNER_ROOT:-$HOME/actions-runners}"
COUNT="${MAC_RUNNER_COUNT:-2}"
HEARTBEAT_VAR="MAC_RUNNER_HEARTBEAT"
AGENT="com.transcripted.ci-heartbeat"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT.plist"

log() { echo "mac-runner: $*"; }
die() { echo "mac-runner: $*" >&2; exit 1; }

# --- pure decisions (covered by self-test) ----------------------------------

# hook_decision <event> <repo> <expected_repo> <pr_head_repo>
# Prints "allow" or "deny <reason>".
hook_decision() {
  local event="$1" repo="$2" expected="$3" head_repo="$4"
  if [ "$repo" != "$expected" ]; then
    echo "deny job is for $repo, not $expected"
    return
  fi
  case "$event" in
    push|workflow_dispatch) echo "allow" ;;
    pull_request)
      if [ -n "$head_repo" ] && [ "$head_repo" = "$expected" ]; then
        echo "allow"
      else
        echo "deny pull request comes from ${head_repo:-an unknown fork}"
      fi
      ;;
    *) echo "deny event $event never runs on this Mac" ;;
  esac
}

# heartbeat_value <paused 0|1> <on_ac 0|1> <idle_runners> <now>
heartbeat_value() {
  local paused="$1" on_ac="$2" idle="$3" now="$4"
  if [ "$paused" = "1" ]; then echo "paused"; return; fi
  if [ "$on_ac" != "1" ]; then echo "battery"; return; fi
  if [ "$idle" -lt 1 ]; then echo "busy"; return; fi
  echo "$now"
}

self_test() {
  local failures=0 got r="r3dbars/transcripted"
  expect() {
    if [ "$1" != "$2" ]; then
      echo "FAIL: $3 -> '$1', want '$2'" >&2
      failures=$((failures + 1))
    fi
  }
  got="$(hook_decision push "$r" "$r" "")";                     expect "$got" "allow" "push"
  got="$(hook_decision workflow_dispatch "$r" "$r" "")";        expect "$got" "allow" "dispatch"
  got="$(hook_decision pull_request "$r" "$r" "$r")";           expect "$got" "allow" "same-repo PR"
  got="$(hook_decision pull_request "$r" "$r" "evil/fork")";    expect "${got%% *}" "deny" "fork PR"
  got="$(hook_decision pull_request "$r" "$r" "")";             expect "${got%% *}" "deny" "PR with deleted head repo"
  got="$(hook_decision pull_request_target "$r" "$r" "$r")";    expect "${got%% *}" "deny" "pull_request_target"
  got="$(hook_decision issue_comment "$r" "$r" "")";            expect "${got%% *}" "deny" "issue_comment"
  got="$(hook_decision push "evil/other" "$r" "")";             expect "${got%% *}" "deny" "other repo"
  got="$(heartbeat_value 0 1 2 123)"; expect "$got" "123" "idle on AC"
  got="$(heartbeat_value 0 1 0 123)"; expect "$got" "busy" "all busy"
  got="$(heartbeat_value 0 0 2 123)"; expect "$got" "battery" "on battery"
  got="$(heartbeat_value 1 1 2 123)"; expect "$got" "paused" "paused"
  if [ "$failures" -ne 0 ]; then
    echo "mac-runner self-test: $failures failure(s)" >&2
    exit 1
  fi
  echo "mac-runner self-test: ok"
}

# --- runtime helpers ---------------------------------------------------------

require_mac() {
  [ "$(uname -s)" = "Darwin" ] || die "this only runs on macOS"
  [ "$(uname -m)" = "arm64" ] || die "this needs an Apple Silicon Mac"
}

require_gh_admin() {
  command -v gh >/dev/null || die "gh is not installed"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in"
  [ "$(gh api "repos/$REPO" --jq .permissions.admin)" = "true" ] \
    || die "the logged-in gh account is not an admin of $REPO"
}

runner_dirs() {
  local i
  for i in $(seq 1 "$COUNT"); do echo "$ROOT/transcripted-$i"; done
}

# Idle = online, not busy, carrying our label. Uses the API rather than
# process names so it matches what GitHub will actually schedule onto.
idle_runner_count() {
  gh api "repos/$REPO/actions/runners?per_page=100" --jq \
    "[.runners[] | select(any(.labels[]; .name == \"$LABEL\")) | select(.status == \"online\" and .busy == false)] | length"
}

on_ac_power() {
  # Desktop Macs report "AC Power" too; anything else means battery.
  if pmset -g batt 2>/dev/null | head -n 1 | grep -q "AC Power"; then echo 1; else echo 0; fi
}

set_heartbeat() {
  gh variable set "$HEARTBEAT_VAR" --repo "$REPO" --body "$1" >/dev/null
}

heartbeat() {
  local logfile="$ROOT/heartbeat.log"
  # Keep the launchd log from growing forever if gh keeps failing.
  if [ -f "$logfile" ] && [ "$(wc -c < "$logfile")" -gt 1048576 ]; then
    : > "$logfile"
  fi
  local paused=0 idle=0
  [ -f "$ROOT/PAUSED" ] && paused=1
  if [ "$paused" = "0" ]; then
    idle="$(idle_runner_count)" || idle=0
    [[ "$idle" =~ ^[0-9]+$ ]] || idle=0
  fi
  set_heartbeat "$(heartbeat_value "$paused" "$(on_ac_power)" "$idle" "$(date +%s)")"
}

job_started_hook() {
  local head_repo=""
  if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && [ -f "${GITHUB_EVENT_PATH:-}" ]; then
    head_repo="$(/usr/bin/python3 -c 'import json, sys
e = json.load(open(sys.argv[1]))
print((((e.get("pull_request") or {}).get("head") or {}).get("repo") or {}).get("full_name") or "")' "$GITHUB_EVENT_PATH")"
  fi
  local decision
  decision="$(hook_decision "${GITHUB_EVENT_NAME:-}" "${GITHUB_REPOSITORY:-}" "$REPO" "$head_repo")"
  if [ "$decision" != "allow" ]; then
    echo "::error::This Mac refuses this job: ${decision#deny }"
    exit 1
  fi
  echo "This Mac accepts the job (${GITHUB_EVENT_NAME} on ${GITHUB_REPOSITORY})."
}

write_heartbeat_agent() {
  local gh_dir
  gh_dir="$(dirname "$(command -v gh)")"
  mkdir -p "$(dirname "$AGENT_PLIST")"
  cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ROOT/mac-runner.sh</string>
    <string>heartbeat</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$gh_dir:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>MAC_RUNNER_ROOT</key><string>$ROOT</string>
    <key>MAC_RUNNER_REPO</key><string>$REPO</string>
  </dict>
  <key>StartInterval</key><integer>30</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$ROOT/heartbeat.log</string>
  <key>StandardErrorPath</key><string>$ROOT/heartbeat.log</string>
</dict>
</plist>
PLIST
  plutil -lint "$AGENT_PLIST" >/dev/null
  launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
}

# Sets KEY=VALUE in a runner's .env (read by the runner at start).
set_runner_env() {
  local file="$1" key="$2" value="$3"
  touch "$file"
  grep -v "^$key=" "$file" > "$file.tmp" || true
  echo "$key=$value" >> "$file.tmp"
  mv "$file.tmp" "$file"
}

install() {
  require_mac
  require_gh_admin
  case "$ROOT/" in
    "$HOME/transcripted/"*) die "MAC_RUNNER_ROOT must not be inside ~/transcripted" ;;
  esac
  mkdir -p "$ROOT"

  # A fork PR must never run on this Mac. The workflow already routes forks
  # to hosted runners and the hook below refuses them; this makes GitHub wait
  # for the owner's approval before any outside contributor's workflow runs.
  if gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" \
      -f approval_policy=all_external_contributors >/dev/null 2>&1; then
    log "fork PR workflows now need approval for every outside contributor"
  else
    log "WARNING: could not set fork PR approval; set it in repo Settings > Actions > General"
  fi

  cp "${BASH_SOURCE[0]}" "$ROOT/mac-runner.sh"
  printf '#!/bin/bash\nexec /bin/bash "%s/mac-runner.sh" job-started-hook\n' "$ROOT" > "$ROOT/job-started-hook.sh"
  chmod +x "$ROOT/mac-runner.sh" "$ROOT/job-started-hook.sh"

  local version tarball
  version="$(gh api repos/actions/runner/releases/latest --jq .tag_name)"
  version="${version#v}"
  tarball="$ROOT/.downloads/actions-runner-osx-arm64-$version.tar.gz"
  if [ ! -f "$tarball" ]; then
    mkdir -p "$ROOT/.downloads"
    log "downloading runner $version"
    curl -fsSL -o "$tarball.part" \
      "https://github.com/actions/runner/releases/download/v$version/actions-runner-osx-arm64-$version.tar.gz"
    mv "$tarball.part" "$tarball"
  fi

  local dir i=0
  for dir in $(runner_dirs); do
    i=$((i + 1))
    local name="$LABEL-$i"
    if [ -f "$dir/.runner" ]; then
      log "$name already registered"
    else
      mkdir -p "$dir"
      tar -xzf "$tarball" -C "$dir"
      local token
      token="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)"
      (cd "$dir" && ./config.sh --unattended --url "https://github.com/$REPO" --token "$token" \
        --name "$name" --labels "$LABEL" --work _work --replace)
      log "$name registered"
    fi
    set_runner_env "$dir/.env" ACTIONS_RUNNER_HOOK_JOB_STARTED "$ROOT/job-started-hook.sh"
    set_runner_env "$dir/.env" TRANSCRIPTED_DISABLE_FILE_LOGGER 1
    (
      cd "$dir"
      [ -f .service ] || ./svc.sh install >/dev/null
      ./svc.sh stop >/dev/null 2>&1 || true
      ./svc.sh start >/dev/null
    )
    log "$name running (work dir $dir/_work)"
  done

  write_heartbeat_agent
  log "heartbeat running every 30s"
  status
}

status() {
  gh api "repos/$REPO/actions/runners?per_page=100" --jq \
    ".runners[] | select(any(.labels[]; .name == \"$LABEL\")) | \"runner \(.name): \(.status)\(if .busy then \", busy\" else \"\" end)\""
  echo "heartbeat: $(gh variable get "$HEARTBEAT_VAR" --repo "$REPO" 2>/dev/null || echo unset) (now $(date +%s))"
  if [ -f "$ROOT/PAUSED" ]; then echo "paused: yes"; else echo "paused: no"; fi
  if launchctl print "gui/$(id -u)/$AGENT" >/dev/null 2>&1; then
    echo "heartbeat agent: loaded"
  else
    echo "heartbeat agent: not loaded"
  fi
}

pause() {
  mkdir -p "$ROOT"
  touch "$ROOT/PAUSED"
  set_heartbeat paused
  log "paused: new CI jobs go to GitHub; jobs already on this Mac will finish"
}

resume() {
  rm -f "$ROOT/PAUSED"
  heartbeat
  log "resumed"
}

uninstall() {
  require_mac
  require_gh_admin
  set_heartbeat paused || true
  launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
  local dir
  for dir in "$ROOT"/transcripted-*; do
    [ -d "$dir" ] || continue
    (
      cd "$dir"
      if [ -f .service ]; then
        ./svc.sh stop >/dev/null 2>&1 || true
        ./svc.sh uninstall >/dev/null 2>&1 || true
      fi
      if [ -f .runner ]; then
        ./config.sh remove --token "$(gh api -X POST "repos/$REPO/actions/runners/remove-token" --jq .token)"
      fi
    )
    rm -rf "$dir"
  done
  gh variable delete "$HEARTBEAT_VAR" --repo "$REPO" >/dev/null 2>&1 || true
  log "uninstalled; CI runs on GitHub only"
}

case "${1:-}" in
  install) install ;;
  status) status ;;
  pause) pause ;;
  resume) resume ;;
  uninstall) uninstall ;;
  heartbeat) heartbeat ;;
  job-started-hook) job_started_hook ;;
  self-test) self_test ;;
  *) sed -n '2,14p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac
