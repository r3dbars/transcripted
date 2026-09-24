#!/usr/bin/env bash
# Runs Swift CI's `checks` and `spm-tests` jobs on the owner's Mac, each in a
# fresh throwaway macOS VM. See docs/self-hosted-mac-runner.md.
#
# Usage (as the owner, never with sudo): bash scripts/ci/mac-runner.sh <command>
#   install           install Tart, build the CI VM image, start the service
#   status            show every runner on the repo, the heartbeat, VMs, pause state
#   pause | resume    stop / start taking new jobs (a running job finishes)
#   rebuild           rebuild the CI VM image (e.g. for a newer runner)
#   uninstall         stop the service and delete its VMs, images and state
#   self-test         check the pure decision logic (runs on Linux too)
# Internal: serve (the owner's launchd agent), job-started-hook (inside a VM).
#
# Nothing from a job runs on the host. For every job the service clones a
# stopped "golden" VM (APFS copy-on-write), gives it a one-job just-in-time
# runner registration through a read-only shared folder, boots it, waits for
# the job, then deletes the VM. The owner's gh login never enters a VM.

set -euo pipefail

REPO="${MAC_RUNNER_REPO:-r3dbars/transcripted}"
LABEL="transcripted-mac"
# HOME is unset inside the job-started hook (it runs under env -i).
STATE="${MAC_RUNNER_HOME:-${HOME:-/var/empty}/.transcripted-ci}"
IMAGE="${MAC_RUNNER_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-xcode:latest}"
BASE_VM="ci-base"
GOLDEN_VM="ci-golden"
JOB_PREFIX="ci-job-"
GUEST_USER="admin"
GUEST_HOME="/Users/$GUEST_USER"
GUEST_SHARE="/Volumes/My Shared Files/ci"
AGENT="com.transcripted.ci-vm"
HEARTBEAT_VAR="MAC_RUNNER_HEARTBEAT"
INTERVAL=20
BOOT_TIMEOUT=600
JOB_MAX_SECONDS=$((100 * 60))
IDLE_RECYCLE_SECONDS=$((2 * 60 * 60))
GOLDEN_MAX_AGE_DAYS=14
MIN_FREE_GB="${MAC_RUNNER_MIN_FREE_GB:-120}"

export TART_HOME="$STATE/tart"
TART="$STATE/tart.app/Contents/MacOS/tart"

log() { echo "mac-runner $(date -u +%H:%M:%SZ): $*"; }
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

# heartbeat_value <paused 0|1> <on_ac 0|1> <runner idle|busy|offline> <mic 0|1> <now>
# A number means "free"; a word means "send new jobs to GitHub".
heartbeat_value() {
  local paused="$1" on_ac="$2" runner="$3" mic="$4" now="$5"
  if [ "$paused" = "1" ]; then echo "paused"; return; fi
  if [ "$on_ac" != "1" ]; then echo "battery"; return; fi
  case "$runner" in
    busy) echo "busy"; return ;;
    idle) ;;
    *) echo "offline"; return ;;
  esac
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
  got="$(heartbeat_value 0 1 idle 0 123)";    expect "$got" "123" "free"
  got="$(heartbeat_value 1 1 idle 0 123)";    expect "$got" "paused" "paused"
  got="$(heartbeat_value 0 0 idle 0 123)";    expect "$got" "battery" "on battery"
  got="$(heartbeat_value 0 1 offline 0 123)"; expect "$got" "offline" "VM still booting"
  got="$(heartbeat_value 0 1 gone 0 123)";    expect "$got" "offline" "runner gone"
  got="$(heartbeat_value 0 1 busy 0 123)";    expect "$got" "busy" "job running"
  got="$(heartbeat_value 0 1 busy 1 123)";    expect "$got" "busy" "job running during a call"
  got="$(heartbeat_value 0 1 idle 1 123)";    expect "$got" "mic" "mic in use"
  if [ "$failures" -ne 0 ]; then
    echo "mac-runner self-test: $failures failure(s)" >&2
    exit 1
  fi
  echo "mac-runner self-test: ok"
}

# --- host helpers ------------------------------------------------------------------

require_host() {
  [ "$(uname -s)" = "Darwin" ] || die "this only runs on macOS"
  [ "$(uname -m)" = "arm64" ] || die "this needs an Apple Silicon Mac"
  [ "$(id -u)" != "0" ] || die "run this as yourself, not with sudo"
  local version
  version="$(sw_vers -productVersion)"
  [ "${version%%.*}" -ge 26 ] || die "the CI VM is macOS 26; this Mac runs $version"
}

require_gh_admin() {
  command -v gh >/dev/null || die "gh is not installed"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in"
  [ "$(gh api "repos/$REPO" --jq .permissions.admin)" = "true" ] \
    || die "the logged-in gh account is not an admin of $REPO"
}

free_gb() {
  mkdir -p "$STATE"
  df -g "$STATE" | awk 'NR == 2 {print $4}'
}

vm_names() {
  "$TART" list --source local --format json 2>/dev/null \
    | /usr/bin/python3 -c 'import json, sys; [print(vm.get("Name", "")) for vm in json.load(sys.stdin)]' 2>/dev/null || true
}

vm_exists() { vm_names | grep -qx "$1"; }

delete_vm() {
  "$TART" stop "$1" --timeout 30 >/dev/null 2>&1 || true
  "$TART" delete "$1" >/dev/null 2>&1 || true
}

set_heartbeat() {
  gh variable set "$HEARTBEAT_VAR" --repo "$REPO" --body "$1" >/dev/null 2>&1 \
    || log "could not update the heartbeat ($1)"
}

# Prints idle, busy, offline (registered, not connected), gone, or error.
runner_state() {
  local out
  out="$(gh api "repos/$REPO/actions/runners?per_page=100" --jq \
    ".runners[] | select(.name == \"$1\") | if .status == \"online\" then (if .busy then \"busy\" else \"idle\" end) else \"offline\" end" 2>/dev/null)" \
    || { echo error; return; }
  echo "${out:-gone}"
}

delete_runner() {
  local id
  id="$(gh api "repos/$REPO/actions/runners?per_page=100" --jq ".runners[] | select(.name == \"$1\") | .id" 2>/dev/null || true)"
  [ -z "$id" ] || gh api -X DELETE "repos/$REPO/actions/runners/$id" >/dev/null 2>&1 || true
}

# A one-job registration. The runner deregisters itself after that job.
mint_jit() {
  gh api -X POST "repos/$REPO/actions/runners/generate-jitconfig" \
    -f name="$1" -F runner_group_id=1 -f "labels[]=$LABEL" -f work_folder=_work \
    --jq .encoded_jit_config
}

block_reason() {
  if [ -f "$STATE/PAUSED" ]; then echo paused; return; fi
  if ! pmset -g batt 2>/dev/null | head -n 1 | grep -q "AC Power"; then echo battery; return; fi
  echo ""
}

mic_in_use() {
  if [ -x "$STATE/mic-in-use" ] && "$STATE/mic-in-use"; then echo 1; else echo 0; fi
}

# Downloads the latest runner and checks its SHA-256 against GitHub's
# published value (the release asset digest, else the hash in the notes).
download_runner() {
  local dest="$1" version name want got tmp
  version="$(gh api repos/actions/runner/releases/latest --jq .tag_name)"
  version="${version#v}"
  name="actions-runner-osx-arm64-$version.tar.gz"
  want="$(gh api repos/actions/runner/releases/latest --jq ".assets[] | select(.name == \"$name\") | .digest // empty")"
  want="${want#sha256:}"
  if [ -z "$want" ]; then
    want="$(gh api repos/actions/runner/releases/latest --jq .body \
      | sed -n 's/.*<!-- BEGIN SHA osx-arm64 -->\([0-9a-f]\{64\}\)<!-- END SHA osx-arm64 -->.*/\1/p' | head -n 1)"
  fi
  [ -n "$want" ] || die "could not find the published SHA-256 for $name"
  tmp="$dest.part"
  curl -fsSL -o "$tmp" "https://github.com/actions/runner/releases/download/v$version/$name"
  got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    die "runner download failed its checksum (got $got, want $want)"
  fi
  mv "$tmp" "$dest"
  log "runner $version downloaded and verified"
}

# Small CoreAudio check: exit 0 when any device with input streams is running
# (a meeting, dictation, or call is using a microphone), 1 when none is.
build_mic_helper() {
  local out="$1" dir
  dir="$(mktemp -d)"
  cat > "$dir/mic-in-use.swift" <<'SWIFT'
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
  xcrun swiftc -O "$dir/mic-in-use.swift" -o "$out" || status=$?
  rm -rf "$dir"
  return "$status"
}

# --- the guest side -------------------------------------------------------------------

# Writes the files the golden VM is built from into $1 (shared read-only).
write_guest_files() {
  local dir="$1"
  cp "$STATE/mac-runner.sh" "$dir/mac-runner.sh"

  # Runs before every job, from an empty environment.
  cat > "$dir/job-started-hook.sh" <<HOOK
#!/bin/bash
exec /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \\
  GITHUB_EVENT_NAME="\${GITHUB_EVENT_NAME:-}" \\
  GITHUB_EVENT_PATH="\${GITHUB_EVENT_PATH:-}" \\
  GITHUB_REPOSITORY="\${GITHUB_REPOSITORY:-}" \\
  MAC_RUNNER_REPO="$REPO" \\
  /bin/bash --noprofile --norc "$GUEST_HOME/ci/mac-runner.sh" job-started-hook
HOOK

  # Starts at the guest's auto-login, runs exactly one job, powers off.
  cat > "$dir/ci-job.sh" <<JOB
#!/bin/bash
share="$GUEST_SHARE"
for _ in \$(seq 1 300); do
  [ -s "\$share/jitconfig" ] && break
  sleep 2
done
[ -s "\$share/jitconfig" ] || exit 1
cd "$GUEST_HOME/ci/actions-runner" || exit 1
export ACTIONS_RUNNER_HOOK_JOB_STARTED="$GUEST_HOME/ci/job-started-hook.sh"
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1
./run.sh --jitconfig "\$(cat "\$share/jitconfig")" >> "$GUEST_HOME/ci/job.log" 2>&1
sudo -n /sbin/shutdown -h now >/dev/null 2>&1 || true
JOB

  cat > "$dir/com.transcripted.ci-job.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.transcripted.ci-job</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$GUEST_HOME/ci/ci-job.sh</string>
  </array>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

  # Run once in the golden VM: install the runner, then prove the hook
  # refuses a fork PR and accepts a same-repo push before the image is kept.
  cat > "$dir/guest-setup.sh" <<SETUP
#!/bin/bash
set -euo pipefail
if [ "\$(id -u)" = 0 ]; then exec sudo -u "$GUEST_USER" -H /bin/bash "\$0" "\$@"; fi
share="$GUEST_SHARE"
ci="$GUEST_HOME/ci"
rm -rf "\$ci"
mkdir -p "\$ci/actions-runner" "$GUEST_HOME/Library/LaunchAgents"
tar -xzf "\$share/runner.tar.gz" -C "\$ci/actions-runner"
cp "\$share/mac-runner.sh" "\$share/job-started-hook.sh" "\$share/ci-job.sh" "\$ci/"
chmod 755 "\$ci"/*.sh
cp "\$share/com.transcripted.ci-job.plist" "$GUEST_HOME/Library/LaunchAgents/"
xcrun --find swift >/dev/null || { echo "no Xcode toolchain in this image"; exit 1; }
tmp="\$(mktemp -d)"
printf '{"repository":{"full_name":"%s"}}' "$REPO" > "\$tmp/push.json"
printf '{"repository":{"full_name":"%s"},"pull_request":{"head":{"repo":{"full_name":"evil/fork"}}}}' "$REPO" > "\$tmp/fork.json"
GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="\$tmp/push.json" GITHUB_REPOSITORY="$REPO" \\
  /bin/bash "\$ci/job-started-hook.sh" || { echo "the hook refused a same-repo push"; exit 1; }
if GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="\$tmp/fork.json" GITHUB_REPOSITORY="$REPO" \\
  /bin/bash "\$ci/job-started-hook.sh"; then
  echo "the hook accepted a fork PR"; exit 1
fi
rm -rf "\$tmp"
echo guest-setup-ok
SETUP
  chmod 755 "$dir"/*.sh
}

guest_exec() { "$TART" exec "$@" </dev/null; }

wait_for_guest() {
  local vm="$1" deadline=$((SECONDS + BOOT_TIMEOUT))
  until guest_exec "$vm" true >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || die "$vm never answered tart exec"
    sleep 3
  done
  until [ "$(guest_exec "$vm" stat -f %Su /dev/console 2>/dev/null)" = "$GUEST_USER" ]; do
    [ "$SECONDS" -lt "$deadline" ] || die "$vm never logged in to its desktop"
    sleep 3
  done
  until guest_exec "$vm" test -f "$GUEST_SHARE/guest-setup.sh" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || die "$vm never mounted the shared folder"
    sleep 3
  done
}

build_golden() {
  local build="ci-golden-build" share="$STATE/share/golden" cpu mem
  if ! vm_exists "$BASE_VM"; then
    log "downloading the CI image $IMAGE (tens of GB, this takes a while)"
    "$TART" clone "$IMAGE" "$BASE_VM"
  fi
  cpu="${MAC_RUNNER_CPU:-$(( $(sysctl -n hw.ncpu) / 2 ))}"
  [ "$cpu" -ge 4 ] || cpu=4
  mem="${MAC_RUNNER_MEMORY_MB:-8192}"

  delete_vm "$build"
  rm -rf "$share"
  mkdir -p "$share" "$STATE/logs"
  chmod 700 "$share"
  download_runner "$share/runner.tar.gz"
  write_guest_files "$share"

  "$TART" clone "$BASE_VM" "$build"
  "$TART" set "$build" --cpu "$cpu" --memory "$mem"
  log "booting $build to install the runner"
  "$TART" run "$build" --no-graphics --no-audio --no-clipboard --dir "ci:$share:ro" \
    > "$STATE/logs/$build.log" 2>&1 < /dev/null &
  local pid=$!
  wait_for_guest "$build"
  local setup_log="$STATE/logs/$build-setup.log"
  guest_exec "$build" /bin/bash "$GUEST_SHARE/guest-setup.sh" > "$setup_log" 2>&1 || true
  if ! grep -qx guest-setup-ok "$setup_log"; then
    cat "$setup_log" >&2
    delete_vm "$build"
    die "guest setup failed; see $STATE/logs/$build.log"
  fi
  "$TART" stop "$build" --timeout 60 >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true

  delete_vm "$GOLDEN_VM"
  "$TART" clone "$build" "$GOLDEN_VM"
  delete_vm "$build"
  rm -rf "$share"
  date +%s > "$STATE/golden-built-at"
  log "CI image ready ($cpu CPUs, $mem MB per job VM)"
}

golden_is_stale() {
  local built
  built="$(cat "$STATE/golden-built-at" 2>/dev/null || echo 0)"
  [ $(( $(date +%s) - built )) -gt $((GOLDEN_MAX_AGE_DAYS * 86400)) ]
}

# --- the service (owner's launchd agent) -----------------------------------------

cleanup_leftovers() {
  local vm
  for vm in $(vm_names); do
    case "$vm" in "$JOB_PREFIX"*|ci-golden-build) delete_vm "$vm" ;; esac
  done
  rm -rf "$STATE/share"/"$JOB_PREFIX"*
  local name
  for name in $(gh api "repos/$REPO/actions/runners?per_page=100" --jq \
      ".runners[] | select(.name | startswith(\"$LABEL-\")) | select(.busy | not) | .name" 2>/dev/null); do
    delete_runner "$name"
  done
}

run_one_job() {
  local stamp name vm share pid jit
  stamp="$(date +%s)"
  name="$LABEL-$stamp"
  vm="$JOB_PREFIX$stamp"
  share="$STATE/share/$vm"
  mkdir -p "$share"
  chmod 700 "$share"
  jit="$(mint_jit "$name")" || { rm -rf "$share"; log "could not get a runner registration"; return 1; }
  (umask 077; printf '%s' "$jit" > "$share/jitconfig")
  jit=""

  if ! "$TART" clone "$GOLDEN_VM" "$vm"; then
    rm -rf "$share"; delete_runner "$name"; return 1
  fi
  "$TART" run "$vm" --no-graphics --no-audio --no-clipboard --dir "ci:$share:ro" \
    > "$STATE/logs/job.log" 2>&1 < /dev/null &
  pid=$!
  log "$vm booting for runner $name"

  local began now state started=0 busy_since=0 block
  began="$(date +%s)"
  while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"
    state="$(runner_state "$name")"
    case "$state" in
      busy)
        started=1
        [ "$busy_since" -ne 0 ] || busy_since="$now"
        set_heartbeat busy
        # Keep the Mac from idle-sleeping mid-job; renewed every loop.
        caffeinate -i -t $((INTERVAL * 3)) >/dev/null 2>&1 &
        [ $((now - busy_since)) -lt "$JOB_MAX_SECONDS" ] || { log "$vm ran past the job time limit"; break; }
        ;;
      idle)
        block="$(block_reason)"
        if [ -n "$block" ]; then
          set_heartbeat "$block"
          log "$block: dropping the idle VM"
          break
        fi
        [ $((now - began)) -lt "$IDLE_RECYCLE_SECONDS" ] || { log "recycling a long-idle VM"; break; }
        set_heartbeat "$(heartbeat_value 0 1 idle "$(mic_in_use)" "$now")"
        ;;
      gone)
        # Ephemeral runners deregister after their one job.
        log "runner $name finished (had started: $started)"
        break
        ;;
      offline|error)
        set_heartbeat offline
        if [ "$started" = "0" ] && [ $((now - began)) -gt "$BOOT_TIMEOUT" ]; then
          log "$vm never connected its runner"
          break
        fi
        ;;
    esac
    sleep "$INTERVAL"
  done

  set_heartbeat offline
  delete_runner "$name"
  delete_vm "$vm"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$share"
  [ "$started" = "1" ] && log "$vm done"
  return 0
}

serve() {
  set +e
  mkdir -p "$STATE/logs"
  cleanup_leftovers
  while true; do
    if [ -f "$STATE/serve.log" ] && [ "$(wc -c < "$STATE/serve.log")" -gt 5242880 ]; then
      mv "$STATE/serve.log" "$STATE/serve.log.1"
    fi
    local block
    block="$(block_reason)"
    if [ -n "$block" ]; then
      set_heartbeat "$block"
      sleep "$INTERVAL"
      continue
    fi
    if ! vm_exists "$GOLDEN_VM"; then
      set_heartbeat offline
      log "no CI image; run: bash $STATE/mac-runner.sh rebuild"
      sleep 300
      continue
    fi
    if golden_is_stale; then
      set_heartbeat offline
      log "CI image is older than $GOLDEN_MAX_AGE_DAYS days; rebuilding"
      ( build_golden ) || { log "rebuild failed; using the old image"; date +%s > "$STATE/golden-built-at"; }
      continue
    fi
    run_one_job || { set_heartbeat offline; sleep 60; }
  done
}

# --- owner commands ------------------------------------------------------------------

install() {
  require_host
  require_gh_admin
  mkdir -p "$STATE/logs" "$STATE/share"
  chmod 700 "$STATE"
  local gb
  gb="$(free_gb)"
  [ "${gb:-0}" -ge "$MIN_FREE_GB" ] || die "need about $MIN_FREE_GB GB free for the CI image; this Mac has ${gb:-0} GB"

  # Only this setup's runners may be registered: any other runner would have
  # no job-started hook and no throwaway VM.
  local others
  others="$(gh api "repos/$REPO/actions/runners?per_page=100" --jq \
    ".runners[] | select(.name | startswith(\"$LABEL-\") | not) | \"\(.name) (\(.status), labels: \([.labels[].name] | join(\",\")))\"")"
  if [ -n "$others" ]; then
    echo "$others" >&2
    die "other runners are registered on $REPO; remove them first (repo Settings > Actions > Runners)"
  fi

  # Fork PR workflows wait for the owner's approval before they run at all.
  gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" \
    -f approval_policy=all_external_contributors >/dev/null 2>&1 || true
  local policy
  policy="$(gh api "repos/$REPO/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy 2>/dev/null || echo unknown)"
  log "fork PR approval policy: $policy"
  [ "$policy" = "all_external_contributors" ] \
    || log "WARNING: set repo Settings > Actions > General > fork PR approval to 'all outside collaborators'"

  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ "$here/mac-runner.sh" != "$STATE/mac-runner.sh" ]; then
    cp "$here/mac-runner.sh" "$STATE/mac-runner.sh.new"
    mv "$STATE/mac-runner.sh.new" "$STATE/mac-runner.sh"
  fi
  if [ ! -x "$TART" ]; then
    [ -f "$here/../vm/transcripted-vm.sh" ] || die "run install from a repo checkout (needs scripts/vm/transcripted-vm.sh for the pinned Tart)"
    TVM_HOME="$STATE" bash "$here/../vm/transcripted-vm.sh" install-tart
  fi
  if ! build_mic_helper "$STATE/mic-in-use"; then
    log "WARNING: could not build the microphone check; the Mac will take jobs during calls"
  fi

  set_heartbeat offline
  build_golden

  local plist="$HOME/Library/LaunchAgents/$AGENT.plist" gh_dir
  gh_dir="$(dirname "$(command -v gh)")"
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$STATE/mac-runner.sh</string>
    <string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$gh_dir:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
    <key>MAC_RUNNER_REPO</key><string>$REPO</string>
    <key>MAC_RUNNER_HOME</key><string>$STATE</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$STATE/serve.log</string>
  <key>StandardErrorPath</key><string>$STATE/serve.log</string>
</dict>
</plist>
PLIST
  plutil -lint "$plist" >/dev/null
  launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
  local _
  for _ in 1 2 3 4 5; do
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null && break
    sleep 1
  done
  launchctl print "gui/$(id -u)/$AGENT" >/dev/null 2>&1 || die "the CI service did not start"
  log "CI service running"
  status
}

rebuild() {
  require_host
  require_gh_admin
  [ -x "$TART" ] || die "not installed; run install first"
  touch "$STATE/PAUSED"
  set_heartbeat paused
  log "paused while rebuilding; waiting for any running job to finish"
  while vm_names | grep -q "^$JOB_PREFIX"; do sleep 10; done
  build_golden
  rm -f "$STATE/PAUSED"
  log "resumed"
}

status() {
  echo "runners on $REPO:"
  gh api "repos/$REPO/actions/runners?per_page=100" --jq \
    '.runners[] | "  \(.name): \(.status)\(if .busy then ", busy" else "" end) [\([.labels[].name] | join(","))]"'
  echo "heartbeat: $(gh variable get "$HEARTBEAT_VAR" --repo "$REPO" 2>/dev/null || echo unset) (now $(date +%s))"
  if [ -f "$STATE/PAUSED" ]; then echo "paused: yes"; else echo "paused: no"; fi
  if launchctl print "gui/$(id -u)/$AGENT" >/dev/null 2>&1; then
    echo "CI service: loaded"
  else
    echo "CI service: not loaded"
  fi
  if [ -x "$TART" ]; then
    echo "VMs: $(vm_names | tr '\n' ' ')"
  else
    echo "VMs: Tart not installed"
  fi
  echo "disk used: $(du -sh "$STATE" 2>/dev/null | awk '{print $1}')"
}

pause() {
  mkdir -p "$STATE"
  touch "$STATE/PAUSED"
  set_heartbeat paused
  log "paused: new CI jobs go to GitHub; a job already on this Mac will finish"
}

resume() {
  rm -f "$STATE/PAUSED"
  log "resumed"
}

uninstall() {
  require_host
  require_gh_admin
  set_heartbeat paused
  launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$AGENT.plist"
  if [ -x "$TART" ]; then
    local vm
    for vm in $(vm_names); do delete_vm "$vm"; done
  fi
  local name
  for name in $(gh api "repos/$REPO/actions/runners?per_page=100" --jq \
      ".runners[] | select(.name | startswith(\"$LABEL-\")) | .name" 2>/dev/null); do
    delete_runner "$name"
  done
  gh variable delete "$HEARTBEAT_VAR" --repo "$REPO" >/dev/null 2>&1 || true
  rm -rf "$STATE"
  log "uninstalled; CI runs on GitHub only"
}

# --- inside a CI VM ----------------------------------------------------------------------

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
    return (value.get("full_name") or "") if isinstance(value, dict) else ""
print(name(event.get("repository")))
print(name(((event.get("pull_request") or {}).get("head") or {}).get("repo")))
PY
)"
    payload_repo="$(printf '%s\n' "$parsed" | sed -n 1p)"
    head_repo="$(printf '%s\n' "$parsed" | sed -n 2p)"
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
  rebuild) rebuild ;;
  uninstall) uninstall ;;
  self-test) self_test ;;
  serve) serve ;;
  job-started-hook) job_started_hook ;;
  *) sed -n '2,13p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac
