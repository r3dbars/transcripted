#!/usr/bin/env bash
# Sets up and runs the owner's Mac as a self-hosted GitHub Actions runner for
# Swift CI's `checks` and `spm-tests` jobs. See docs/self-hosted-mac-runner.md.
#
# Usage (as the owner, never with sudo): bash scripts/ci/mac-runner.sh <command>
#   install           create the Transcripted CI account and register the runner
#   status            show every runner on the repo, the heartbeat, and pause state
#   pause | resume    stop / start taking new jobs (a running job finishes)
#   uninstall         remove the runner, the CI account, and the heartbeat
#   heartbeat         (owner's launchd agent) report idle or why not
#   self-test         check the pure decision logic (runs on Linux too)
# Internal: root-install, root-uninstall (via the macOS admin prompt),
# start-runner (CI account's launchd agent), job-started-hook (runner hook).
#
# Jobs run as a separate standard (non-admin) account, never as the owner.
# The owner's gh login stays in the owner's account and is only used by the
# install/uninstall steps and the heartbeat, which runs as the owner.

set -euo pipefail

REPO="${MAC_RUNNER_REPO:-r3dbars/transcripted}"
LABEL="transcripted-mac"
RUNNER_NAME="$LABEL-1"
CI_USER="transcripted-ci"
CI_FULL_NAME="Transcripted CI"
CI_HOME="/Users/$CI_USER"
RUNNER_DIR="$CI_HOME/actions-runner"
SYS_DIR="/Library/TranscriptedCI"
RUNNER_AGENT="com.transcripted.ci-runner"
RUNNER_PLIST="/Library/LaunchAgents/$RUNNER_AGENT.plist"
HEARTBEAT_AGENT="com.transcripted.ci-heartbeat"
HEARTBEAT_VAR="MAC_RUNNER_HEARTBEAT"
HEARTBEAT_INTERVAL=20

log() { echo "mac-runner: $*"; }
die() { echo "mac-runner: $*" >&2; exit 1; }

# --- pure decisions (covered by self-test) ----------------------------------

# hook_decision <event> <env_repo> <payload_repo> <pr_head_repo> <expected_repo>
# Prints "allow" or "deny <reason>".
hook_decision() {
  local event="$1" env_repo="$2" payload_repo="$3" head_repo="$4" expected="$5"
  if [ "$env_repo" != "$expected" ] || [ "$payload_repo" != "$expected" ]; then
    echo "deny job is for ${payload_repo:-an unknown repo}, not $expected"
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
    *) echo "deny event ${event:-unset} never runs on this Mac" ;;
  esac
}

# heartbeat_value <paused> <on_ac> <runner_up> <job_running> <mic_in_use> <now>
# (flags are 1 or 0). A number means "free"; a word means "send jobs to GitHub".
heartbeat_value() {
  local paused="$1" on_ac="$2" runner_up="$3" job_running="$4" mic="$5" now="$6"
  if [ "$paused" = "1" ]; then echo "paused"; return; fi
  if [ "$on_ac" != "1" ]; then echo "battery"; return; fi
  if [ "$runner_up" != "1" ]; then echo "offline"; return; fi
  if [ "$job_running" = "1" ]; then echo "busy"; return; fi
  if [ "$mic" = "1" ]; then echo "mic"; return; fi
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
  got="$(hook_decision push "$r" "$r" "" "$r")";                    expect "$got" "allow" "push"
  got="$(hook_decision workflow_dispatch "$r" "$r" "" "$r")";       expect "$got" "allow" "dispatch"
  got="$(hook_decision pull_request "$r" "$r" "$r" "$r")";          expect "$got" "allow" "same-repo PR"
  got="$(hook_decision pull_request "$r" "$r" "evil/fork" "$r")";   expect "${got%% *}" "deny" "fork PR"
  got="$(hook_decision pull_request "$r" "$r" "" "$r")";            expect "${got%% *}" "deny" "PR with deleted head repo"
  got="$(hook_decision pull_request_target "$r" "$r" "$r" "$r")";   expect "${got%% *}" "deny" "pull_request_target"
  got="$(hook_decision workflow_run "$r" "$r" "" "$r")";            expect "${got%% *}" "deny" "workflow_run"
  got="$(hook_decision issue_comment "$r" "$r" "" "$r")";           expect "${got%% *}" "deny" "issue_comment"
  got="$(hook_decision "" "$r" "$r" "" "$r")";                      expect "${got%% *}" "deny" "no event"
  got="$(hook_decision push "evil/other" "evil/other" "" "$r")";    expect "${got%% *}" "deny" "other repo"
  got="$(hook_decision push "$r" "evil/other" "" "$r")";            expect "${got%% *}" "deny" "payload names another repo"
  got="$(hook_decision push "$r" "" "" "$r")";                      expect "${got%% *}" "deny" "unreadable payload"
  got="$(heartbeat_value 0 1 1 0 0 123)"; expect "$got" "123" "free"
  got="$(heartbeat_value 1 1 1 0 0 123)"; expect "$got" "paused" "paused"
  got="$(heartbeat_value 0 0 1 0 0 123)"; expect "$got" "battery" "on battery"
  got="$(heartbeat_value 0 1 0 0 0 123)"; expect "$got" "offline" "runner not running"
  got="$(heartbeat_value 0 1 1 1 0 123)"; expect "$got" "busy" "job running"
  got="$(heartbeat_value 0 1 1 0 1 123)"; expect "$got" "mic" "mic in use"
  if [ "$failures" -ne 0 ]; then
    echo "mac-runner self-test: $failures failure(s)" >&2
    exit 1
  fi
  echo "mac-runner self-test: ok"
}

# --- shared helpers ------------------------------------------------------------

state_dir() { echo "$HOME/.transcripted-ci"; }

require_mac() {
  [ "$(uname -s)" = "Darwin" ] || die "this only runs on macOS"
  [ "$(uname -m)" = "arm64" ] || die "this needs an Apple Silicon Mac"
}

require_owner() {
  [ "$(id -u)" != "0" ] || die "run this as yourself, not with sudo"
  [ "$(id -un)" != "$CI_USER" ] || die "run this from the owner's account, not $CI_USER"
}

require_gh_admin() {
  command -v gh >/dev/null || die "gh is not installed"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in"
  [ "$(gh api "repos/$REPO" --jq .permissions.admin)" = "true" ] \
    || die "the logged-in gh account is not an admin of $REPO"
}

script_path() { echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"; }

ci_uid() { id -u "$CI_USER" 2>/dev/null || true; }

ci_logged_in() { pgrep -u "$CI_USER" -x loginwindow >/dev/null 2>&1; }

set_heartbeat() {
  gh variable set "$HEARTBEAT_VAR" --repo "$REPO" --body "$1" >/dev/null
}

# Runs one of this script's root-* commands through the standard macOS
# administrator password prompt.
run_as_admin() {
  local script="$1"; shift
  osascript - "$script" "$@" <<'OSA'
on run argv
  set cmd to "/bin/bash " & quoted form of (item 1 of argv)
  repeat with i from 2 to count of argv
    set cmd to cmd & " " & quoted form of (item i of argv)
  end repeat
  do shell script cmd with administrator privileges
end run
OSA
}

ask_password() {
  local first second
  while true; do
    first="$(osascript -e 'text returned of (display dialog "Pick a password for the new \"Transcripted CI\" account. You will type it once to log in to that account." default answer "" with hidden answer with title "Transcripted CI")')" \
      || die "cancelled"
    second="$(osascript -e 'text returned of (display dialog "Type the same password again." default answer "" with hidden answer with title "Transcripted CI")')" \
      || die "cancelled"
    if [ -n "$first" ] && [ "$first" = "$second" ]; then
      printf '%s' "$first"
      return
    fi
    osascript -e 'display dialog "Those didn'"'"'t match. Try again." buttons {"OK"} default button 1 with title "Transcripted CI"' >/dev/null || die "cancelled"
  done
}

# Downloads the latest runner and checks its SHA-256 against GitHub's
# published value (the release asset digest, else the hash in the notes).
download_runner() {
  local dest_dir="$1" version name tarball want got
  version="$(gh api repos/actions/runner/releases/latest --jq .tag_name)"
  version="${version#v}"
  name="actions-runner-osx-arm64-$version.tar.gz"
  tarball="$dest_dir/$name"
  want="$(gh api repos/actions/runner/releases/latest --jq ".assets[] | select(.name == \"$name\") | .digest // empty")"
  want="${want#sha256:}"
  if [ -z "$want" ]; then
    want="$(gh api repos/actions/runner/releases/latest --jq .body \
      | sed -n 's/.*<!-- BEGIN SHA osx-arm64 -->\([0-9a-f]\{64\}\)<!-- END SHA osx-arm64 -->.*/\1/p' | head -n 1)"
  fi
  [ -n "$want" ] || die "could not find the published SHA-256 for $name"
  if [ ! -f "$tarball" ]; then
    curl -fsSL -o "$tarball.part" "https://github.com/actions/runner/releases/download/v$version/$name"
    mv "$tarball.part" "$tarball"
  fi
  got="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    rm -f "$tarball"
    die "runner download failed its checksum (got $got, want $want)"
  fi
  echo "$tarball"
}

# Small CoreAudio check: exit 0 when any device with input streams is running
# (a meeting, dictation, or call is using a microphone), 1 when none is.
build_mic_helper() {
  local out="$1" src
  src="$(mktemp -d)/mic-in-use.swift"
  cat > "$src" <<'SWIFT'
import CoreAudio
import Darwin

func devices() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { exit(2) }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { exit(2) }
    return ids
}

for device in devices() {
    var streams = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var streamBytes: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamBytes) == noErr, streamBytes > 0 else { continue }
    var running = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var valueBytes = UInt32(MemoryLayout<UInt32>.size)
    if AudioObjectGetPropertyData(device, &running, 0, nil, &valueBytes, &value) == noErr, value != 0 {
        exit(0)
    }
}
exit(1)
SWIFT
  local status=0
  xcrun swiftc -O "$src" -o "$out" || status=$?
  rm -rf "$(dirname "$src")"
  return "$status"
}

# --- owner commands --------------------------------------------------------------

install() {
  require_mac
  require_owner
  require_gh_admin
  local state
  state="$(state_dir)"
  mkdir -p "$state/downloads"
  chmod 700 "$state"

  # Only this setup's runner may be registered on the repo: any other runner
  # (e.g. an old ~/actions-runner) would carry no job-started hook.
  local others
  others="$(gh api "repos/$REPO/actions/runners?per_page=100" --jq \
    ".runners[] | select(.name != \"$RUNNER_NAME\") | \"\(.name) (\(.status), labels: \([.labels[].name] | join(\",\")))\"")"
  if [ -n "$others" ]; then
    echo "$others" >&2
    die "other runners are registered on $REPO; remove them first (repo Settings > Actions > Runners)"
  fi
  if [ -f "$HOME/actions-runner/.runner" ]; then
    log "note: ~/actions-runner is configured for: $(sed -n 's/.*"gitHubUrl": *"\([^"]*\)".*/\1/p' "$HOME/actions-runner/.runner")"
    log "it is not registered on $REPO, so it cannot take this repo's jobs; leaving it alone"
  fi

  # Fork PR workflows wait for the owner's approval before they run at all.
  if gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" \
      -f approval_policy=all_external_contributors >/dev/null 2>&1; then
    log "fork PR workflows now need approval for every outside contributor"
  else
    log "WARNING: could not set fork PR approval; set it in repo Settings > Actions > General"
  fi

  local home_mode
  home_mode="$(stat -f %Lp "$HOME")"
  if [ $((home_mode % 10)) -ne 0 ]; then
    log "WARNING: your home folder is readable by other accounts (mode $home_mode)"
  fi

  local tarball helper secrets
  tarball="$(download_runner "$state/downloads")"
  helper="$state/mic-in-use"
  if ! build_mic_helper "$helper"; then
    log "WARNING: could not build the microphone check; the Mac will take jobs even during calls"
    helper=""
  fi

  secrets="$(mktemp "$state/secrets.XXXXXX")"
  chmod 600 "$secrets"
  trap 'rm -f "$secrets"' EXIT
  gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token > "$secrets"
  if [ -z "$(ci_uid)" ]; then
    ask_password >> "$secrets"
  fi

  log "asking for your Mac password to create the account and install the runner"
  run_as_admin "$(script_path)" root-install "$secrets" "$tarball" "$helper" "$(id -un)"
  rm -f "$secrets"

  write_heartbeat_agent "$state"
  log "heartbeat running every ${HEARTBEAT_INTERVAL}s"
  if ! ci_logged_in; then
    log "last step: log in to the \"$CI_FULL_NAME\" account once (Apple menu > Lock Screen, pick it),"
    log "then switch back to your own account. Its runner keeps going in the background."
  fi
  status
}

write_heartbeat_agent() {
  local state="$1" gh_dir plist
  gh_dir="$(dirname "$(command -v gh)")"
  plist="$HOME/Library/LaunchAgents/$HEARTBEAT_AGENT.plist"
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$HEARTBEAT_AGENT</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SYS_DIR/mac-runner.sh</string>
    <string>heartbeat</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$gh_dir:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
    <key>MAC_RUNNER_REPO</key><string>$REPO</string>
  </dict>
  <key>StartInterval</key><integer>$HEARTBEAT_INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$state/heartbeat.log</string>
  <key>StandardErrorPath</key><string>$state/heartbeat.log</string>
</dict>
</plist>
PLIST
  plutil -lint "$plist" >/dev/null
  launchctl bootout "gui/$(id -u)/$HEARTBEAT_AGENT" 2>/dev/null || true
  bootstrap_agent "gui/$(id -u)" "$plist"
}

# launchctl can refuse a bootstrap right after a bootout (error 5) while the
# old instance is still going away, so retry briefly.
bootstrap_agent() {
  local domain="$1" plist="$2" _
  for _ in 1 2 3 4 5; do
    launchctl bootstrap "$domain" "$plist" 2>/dev/null && return 0
    sleep 1
  done
  launchctl bootstrap "$domain" "$plist"
}

heartbeat() {
  local state logfile
  state="$(state_dir)"
  logfile="$state/heartbeat.log"
  if [ -f "$logfile" ] && [ "$(wc -c < "$logfile")" -gt 1048576 ]; then
    : > "$logfile"
  fi

  local paused=0 on_ac=0 runner_up=0 job_running=0 mic=0
  [ -f "$state/PAUSED" ] && paused=1
  pmset -g batt 2>/dev/null | head -n 1 | grep -q "AC Power" && on_ac=1
  pgrep -u "$CI_USER" -f "bin/Runner.Listener" >/dev/null 2>&1 && runner_up=1
  if pgrep -u "$CI_USER" -f "bin/Runner.Worker" >/dev/null 2>&1; then
    job_running=1
    # Keep the Mac from idle-sleeping mid-job; renewed every heartbeat.
    caffeinate -i -t $((HEARTBEAT_INTERVAL * 3)) >/dev/null 2>&1 &
  fi
  if [ -x "$SYS_DIR/mic-in-use" ] && "$SYS_DIR/mic-in-use"; then
    mic=1
  fi
  set_heartbeat "$(heartbeat_value "$paused" "$on_ac" "$runner_up" "$job_running" "$mic" "$(date +%s)")"
}

status() {
  echo "runners on $REPO:"
  gh api "repos/$REPO/actions/runners?per_page=100" --jq \
    '.runners[] | "  \(.name): \(.status)\(if .busy then ", busy" else "" end) [\([.labels[].name] | join(","))]"'
  echo "heartbeat: $(gh variable get "$HEARTBEAT_VAR" --repo "$REPO" 2>/dev/null || echo unset) (now $(date +%s))"
  if [ -f "$(state_dir)/PAUSED" ]; then echo "paused: yes"; else echo "paused: no"; fi
  if [ -n "$(ci_uid)" ]; then echo "CI account: exists"; else echo "CI account: missing"; fi
  if ci_logged_in; then echo "CI account logged in: yes"; else echo "CI account logged in: no"; fi
  if launchctl print "gui/$(id -u)/$HEARTBEAT_AGENT" >/dev/null 2>&1; then
    echo "heartbeat agent: loaded"
  else
    echo "heartbeat agent: not loaded"
  fi
}

pause() {
  mkdir -p "$(state_dir)"
  touch "$(state_dir)/PAUSED"
  set_heartbeat paused
  log "paused: new CI jobs go to GitHub; a job already on this Mac will finish"
}

resume() {
  rm -f "$(state_dir)/PAUSED"
  heartbeat
  log "resumed"
}

uninstall() {
  require_mac
  require_owner
  require_gh_admin
  set_heartbeat paused || true
  launchctl bootout "gui/$(id -u)/$HEARTBEAT_AGENT" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$HEARTBEAT_AGENT.plist"

  local secrets
  secrets="$(mktemp -t transcripted-ci)"
  chmod 600 "$secrets"
  gh api -X POST "repos/$REPO/actions/runners/remove-token" --jq .token > "$secrets" \
    || log "WARNING: could not get a remove token; the runner may stay listed on GitHub as offline"
  log "asking for your Mac password to remove the runner and the CI account"
  run_as_admin "$(script_path)" root-uninstall "$secrets" || log "WARNING: the admin step did not finish"
  rm -f "$secrets"

  # Drop the GitHub-side registration too, if it is still there.
  local id
  id="$(gh api "repos/$REPO/actions/runners?per_page=100" --jq ".runners[] | select(.name == \"$RUNNER_NAME\") | .id" 2>/dev/null || true)"
  if [ -n "$id" ]; then
    gh api -X DELETE "repos/$REPO/actions/runners/$id" >/dev/null 2>&1 || log "WARNING: could not delete runner $RUNNER_NAME on GitHub"
  fi
  gh variable delete "$HEARTBEAT_VAR" --repo "$REPO" >/dev/null 2>&1 || true
  rm -rf "$(state_dir)"
  log "uninstalled; CI runs on GitHub only"
}

# --- root commands (via the admin prompt) --------------------------------------

root_install() {
  local secrets="$1" tarball="$2" helper="$3" owner="$4"
  [ "$(id -u)" = "0" ] || die "root-install must run as root"
  local token password
  token="$(sed -n 1p "$secrets")"
  password="$(sed -n '2,$p' "$secrets")"
  rm -f "$secrets"
  [ -n "$token" ] || die "missing registration token"

  # A dedicated standard account with its own group, so it is not in "staff"
  # and cannot read the owner's group-readable files.
  if ! dscl . -read "/Groups/$CI_USER" >/dev/null 2>&1; then
    dseditgroup -o create -r "$CI_FULL_NAME" "$CI_USER"
  fi
  local gid
  gid="$(dscl . -read "/Groups/$CI_USER" PrimaryGroupID | awk '{print $2}')"
  if ! id -u "$CI_USER" >/dev/null 2>&1; then
    [ -n "$password" ] || die "missing password for the new account"
    sysadminctl -addUser "$CI_USER" -fullName "$CI_FULL_NAME" -GID "$gid" \
      -password "$password" -home "$CI_HOME" -shell /bin/zsh
  fi
  password=""
  dscl . -create "/Users/$CI_USER" PrimaryGroupID "$gid"
  dseditgroup -o edit -d "$CI_USER" -t user staff 2>/dev/null || true
  dseditgroup -o edit -d "$CI_USER" -t user admin 2>/dev/null || true
  [ -d "$CI_HOME" ] || createhomedir -c -u "$CI_USER" >/dev/null
  chown -R "$CI_USER:$gid" "$CI_HOME"
  chmod 700 "$CI_HOME"

  # Root-owned copies of this script, the hook, and the launcher, so the CI
  # account cannot change what they do.
  mkdir -p "$SYS_DIR"
  if [ "${BASH_SOURCE[0]}" != "$SYS_DIR/mac-runner.sh" ]; then
    cp "${BASH_SOURCE[0]}" "$SYS_DIR/mac-runner.sh.new"
    mv "$SYS_DIR/mac-runner.sh.new" "$SYS_DIR/mac-runner.sh"
  fi
  rm -f "$SYS_DIR/mic-in-use"
  if [ -n "$helper" ] && [ -f "$helper" ]; then
    cp "$helper" "$SYS_DIR/mic-in-use"
  fi
  cat > "$SYS_DIR/job-started-hook.sh" <<HOOK
#!/bin/bash
# Runs before every job. Starts from an empty environment so nothing the job
# sets can change how the check runs.
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \\
  GITHUB_EVENT_NAME="\${GITHUB_EVENT_NAME:-}" \\
  GITHUB_EVENT_PATH="\${GITHUB_EVENT_PATH:-}" \\
  GITHUB_REPOSITORY="\${GITHUB_REPOSITORY:-}" \\
  MAC_RUNNER_REPO="$REPO" \\
  /bin/bash --noprofile --norc "$SYS_DIR/mac-runner.sh" job-started-hook
HOOK
  cat > "$SYS_DIR/start-runner.sh" <<START
#!/bin/bash
exec /bin/bash --noprofile --norc "$SYS_DIR/mac-runner.sh" start-runner
START
  chown -R root:wheel "$SYS_DIR"
  chmod 755 "$SYS_DIR" "$SYS_DIR"/*

  if [ ! -f "$RUNNER_DIR/.runner" ]; then
    rm -rf "$RUNNER_DIR"
    mkdir -p "$RUNNER_DIR"
    tar -xzf "$tarball" -C "$RUNNER_DIR"
    chown -R "$CI_USER:$gid" "$RUNNER_DIR"
    # Only the custom label: no self-hosted/macOS/ARM64 defaults, so jobs that
    # target generic self-hosted labels (hardware-smokes) never land here.
    sudo -u "$CI_USER" -H /bin/bash -c "cd '$RUNNER_DIR' && ./config.sh --unattended \
      --url 'https://github.com/$REPO' --token '$token' --name '$RUNNER_NAME' \
      --no-default-labels --labels '$LABEL' --work _work --replace"
  fi
  token=""

  # Loads for every GUI login; start-runner exits at once for anyone but the
  # CI account.
  cat > "$RUNNER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$RUNNER_AGENT</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SYS_DIR/start-runner.sh</string>
  </array>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>Nice</key><integer>10</integer>
</dict>
</plist>
PLIST
  chown root:wheel "$RUNNER_PLIST"
  chmod 644 "$RUNNER_PLIST"
  plutil -lint "$RUNNER_PLIST" >/dev/null

  local uid
  uid="$(id -u "$CI_USER")"
  if pgrep -u "$CI_USER" -x loginwindow >/dev/null 2>&1; then
    launchctl bootout "gui/$uid/$RUNNER_AGENT" 2>/dev/null || true
    bootstrap_agent "gui/$uid" "$RUNNER_PLIST"
  fi
  echo "root-install done for owner $owner"
}

root_uninstall() {
  local secrets="$1"
  [ "$(id -u)" = "0" ] || die "root-uninstall must run as root"
  local token
  token="$(sed -n 1p "$secrets" 2>/dev/null || true)"
  rm -f "$secrets"
  local uid
  uid="$(id -u "$CI_USER" 2>/dev/null || true)"
  if [ -n "$uid" ]; then
    launchctl bootout "gui/$uid/$RUNNER_AGENT" 2>/dev/null || true
  fi
  rm -f "$RUNNER_PLIST"
  if [ -n "$token" ] && [ -f "$RUNNER_DIR/.runner" ]; then
    sudo -u "$CI_USER" -H /bin/bash -c "cd '$RUNNER_DIR' && ./config.sh remove --token '$token'" \
      || echo "could not unregister the runner; the owner step deletes it on GitHub instead"
  fi
  if [ -n "$uid" ]; then
    pkill -u "$CI_USER" 2>/dev/null || true
    sleep 2
    pkill -KILL -u "$CI_USER" 2>/dev/null || true
    sysadminctl -deleteUser "$CI_USER" || echo "could not delete the $CI_USER account"
  fi
  rm -rf "$CI_HOME"
  dseditgroup -o delete "$CI_USER" 2>/dev/null || true
  rm -rf "$SYS_DIR"
  echo "root-uninstall done"
}

# --- CI account commands -----------------------------------------------------------

start_runner() {
  # The agent loads for every GUI login; only the CI account runs a runner.
  [ "$(id -un)" = "$CI_USER" ] || exit 0
  cd "$RUNNER_DIR"
  mkdir -p _diag
  exec >> "_diag/launchd.log" 2>&1
  # The hook comes from here, never from the runner's own .env.
  if [ -f .env ]; then
    grep -v '^ACTIONS_RUNNER_HOOK_' .env > .env.tmp || true
    mv .env.tmp .env
  fi
  export ACTIONS_RUNNER_HOOK_JOB_STARTED="$SYS_DIR/job-started-hook.sh"
  export TRANSCRIPTED_DISABLE_FILE_LOGGER=1
  exec ./run.sh
}

job_started_hook() {
  local payload_repo="" head_repo=""
  if [ -f "${GITHUB_EVENT_PATH:-}" ]; then
    local parsed
    parsed="$(/usr/bin/python3 -I - "$GITHUB_EVENT_PATH" <<'PY' || true
import json, sys
try:
    event = json.load(open(sys.argv[1]))
except Exception:
    event = {}
def name(value):
    return (value or {}).get("full_name") or "" if isinstance(value, dict) else ""
print(name(event.get("repository")))
print(name(((event.get("pull_request") or {}).get("head") or {}).get("repo")))
PY
)"
    payload_repo="$(sed -n 1p <<< "$parsed")"
    head_repo="$(sed -n 2p <<< "$parsed")"
  fi
  local decision
  decision="$(hook_decision "${GITHUB_EVENT_NAME:-}" "${GITHUB_REPOSITORY:-}" "$payload_repo" "$head_repo" "$REPO")"
  if [ "$decision" != "allow" ]; then
    echo "::error::This Mac refuses this job: ${decision#deny }"
    exit 1
  fi
  echo "This Mac accepts the job (${GITHUB_EVENT_NAME} on ${GITHUB_REPOSITORY})."
}

case "${1:-}" in
  install) install ;;
  status) status ;;
  pause) pause ;;
  resume) resume ;;
  uninstall) uninstall ;;
  heartbeat) heartbeat ;;
  self-test) self_test ;;
  root-install) shift; root_install "$@" ;;
  root-uninstall) shift; root_uninstall "$@" ;;
  start-runner) start_runner ;;
  job-started-hook) job_started_hook ;;
  *) sed -n '2,14p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac
