#!/usr/bin/env bash
# Runs Swift CI's `checks` and `spm-tests` jobs on the owner's Mac, each in a
# fresh throwaway macOS VM. See docs/self-hosted-mac-runner.md.
#
# Usage (as the owner, never with sudo): bash scripts/ci/mac-runner.sh <command>
#   install           install Tart, build the CI VM image, start the service
#                     (run it again from a newer checkout to update)
#   status            show every runner on the repo, the heartbeat, VMs, waiting jobs
#   pause | resume    stop / start offering this Mac to new runs
#   rebuild           rebuild the CI VM image (e.g. for a newer runner)
#   uninstall         stop the service and delete its VMs, images and state
#   self-test         check the pure decision logic (runs on Linux too)
# Internal: serve (the owner's launchd agent), build-golden, job-started-hook (inside a VM).
#
# Nothing from a job runs on the host. A VM only exists while a job is waiting
# for this Mac: the service clones a stopped "golden" VM (APFS copy-on-write),
# boots it at low priority, hands it a one-job just-in-time runner
# registration through a read-only shared folder, waits for the job, then
# deletes the VM. Inside the VM a firewall blocks the Mac, other VMs and the
# local network, and the job's user has no admin rights. The owner's gh login
# never enters a VM.

set -euo pipefail

REPO="${MAC_RUNNER_REPO:-r3dbars/transcripted}"
LABEL="transcripted-mac"
# HOME is unset inside the job-started hook (it runs under env -i).
STATE="${MAC_RUNNER_HOME:-${HOME:-/var/empty}/.transcripted-ci}"
STATE_NAME=".transcripted-ci"
STATE_MARKER=".transcripted-ci-home"
# Cirrus Labs macOS 26 with Xcode 26.5 (tag 26.5 on 2026-09-24), pinned by
# digest. To move to a newer image, change this and run install again.
IMAGE="${MAC_RUNNER_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-xcode@sha256:923c98d32e40ffadb6e6815a9722124b7a57bdf7d7763a708a2b28d1970831bd}"
BASE_VM="ci-base"
GOLDEN_VM="ci-golden"
BUILD_VM="ci-golden-build"
OLD_GOLDEN_VM="ci-golden-old"
JOB_PREFIX="ci-job-"
GUEST_USER="admin"
GUEST_HOME="/Users/$GUEST_USER"
GUEST_SHARE="/Volumes/My Shared Files/ci"
AGENT="com.transcripted.ci-vm"
HEARTBEAT_VAR="MAC_RUNNER_HEARTBEAT"
INTERVAL=20
# How often to poll GitHub when no new job can be on its way here: the Mac
# hasn't said "free" for FREE_GRACE seconds, or the owner's API quota is low.
SLOW_INTERVAL=120
FREE_GRACE=600
MIN_API_LEFT=1000
# Write the heartbeat at least this often; pick-runner treats >60s as stale.
BEAT_EVERY=40
BOOT_TIMEOUT=600
# A connected runner that gets no job in this long is dropped.
PICKUP_SECONDS=300
JOB_MAX_SECONDS=$((100 * 60))
# A waiting job this Mac can't start for this long is sent back to GitHub.
REROUTE_SECONDS=$((15 * 60))
BACKOFF_MAX=1800
# A runner that drops off GitHub mid-job (VM hung or rebooted) is given up on.
LOST_SECONDS=600
GOLDEN_MAX_AGE_DAYS=14
MIN_FREE_GB="${MAC_RUNNER_MIN_FREE_GB:-120}"
MIN_JOB_FREE_GB="${MAC_RUNNER_MIN_JOB_FREE_GB:-40}"
# macOS runs at most two VMs at once, across every app on the Mac.
MAX_VMS=2
RUNNER_NAME_RE="^$LABEL-[0-9]{10}\$"

export TART_HOME="$STATE/tart"
TART="$STATE/tart.app/Contents/MacOS/tart"

log() { echo "mac-runner $(date -u +%H:%M:%SZ): $*"; }
die() { echo "mac-runner: $*" >&2; exit 1; }

# --- pure decisions (covered by self-test) ----------------------------------

# hook_decision <event> <env_repo> <payload_repo> <pr_head_repo> <expected_repo> [job]
# Prints "allow" or "deny <reason>".
hook_decision() {
  local event="$1" env_repo="$2" payload_repo="$3" head_repo="$4" expected="$5" job="${6:-}"
  if [ "$env_repo" != "$expected" ] || [ "$payload_repo" != "$expected" ]; then
    echo "deny job is for ${payload_repo:-an unknown repo}, not $expected"
    return
  fi
  case "$job" in
    ""|checks|spm-tests) ;;
    *) echo "deny job $job never runs on this Mac"; return ;;
  esac
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

# offer_block <paused> <on_ac> <disk_ok> <vms_running> <mic> <backing_off>
# Why this Mac should not be offered to new runs, or "" when it can be.
offer_block() {
  local paused="$1" on_ac="$2" disk_ok="$3" vms="$4" mic="$5" backoff="$6"
  if [ "$paused" = "1" ]; then echo "paused"; return; fi
  if [ "$on_ac" != "1" ]; then echo "battery"; return; fi
  if [ "$disk_ok" != "1" ]; then echo "disk"; return; fi
  if [ "$vms" -ge "$MAX_VMS" ]; then echo "vms"; return; fi
  if [ "$mic" = "1" ]; then echo "mic"; return; fi
  if [ "$backoff" = "1" ]; then echo "offline"; return; fi
  echo ""
}

# start_block <disk_ok> <vms_running> <backing_off>
# Why a job that is already waiting for this Mac can't start now, or "".
# Pause, battery and the mic don't stop it: it was sent here while the Mac
# said it was free, and nothing else will run it.
start_block() {
  local disk_ok="$1" vms="$2" backoff="$3"
  if [ "$disk_ok" != "1" ]; then echo "disk"; return; fi
  if [ "$vms" -ge "$MAX_VMS" ]; then echo "vms"; return; fi
  if [ "$backoff" = "1" ]; then echo "offline"; return; fi
  echo ""
}

# heartbeat_value <word or ""> <now>: a bare number means "free"; anything
# else ("busy:<now>", ...) means "send new jobs to GitHub". The time lets
# pick-runner tell a live Mac from one that went to sleep.
heartbeat_value() {
  if [ -z "$1" ]; then echo "$2"; else echo "$1:$2"; fi
}

# next_backoff <current seconds>: 60, 120, 240, ... up to BACKOFF_MAX.
next_backoff() {
  local next=$(( ${1:-0} * 2 ))
  [ "$next" -ge 60 ] || next=60
  [ "$next" -le "$BACKOFF_MAX" ] || next="$BACKOFF_MAX"
  echo "$next"
}

# tart_pin <transcripted-vm.sh>: prints "<version> <sha256>" of the Tart
# release that script pins, so both tools install the same checked binary.
# shellcheck disable=SC2016 # \$ is a literal $ in these sed patterns
tart_pin() {
  local version sha
  version="$(sed -n 's/^TVM_TART_VERSION="\${TVM_TART_VERSION:-\([0-9][0-9.]*\)}"$/\1/p' "$1" | head -n 1)"
  sha="$(sed -n 's/^TVM_TART_SHA256="\${TVM_TART_SHA256:-\([0-9a-f]\{64\}\)}"$/\1/p' "$1" | head -n 1)"
  [ -n "$version" ] && [ -n "$sha" ] || return 1
  echo "$version $sha"
}

# state_dir_ok <path>: the only folder uninstall deletes must be unmistakably
# this tool's: absolute, named .transcripted-ci, no . or .. parts.
state_dir_ok() {
  local h="$1"
  case "$h" in /*) ;; *) return 1 ;; esac
  case "$h/" in */../*|*/./*|*//*) return 1 ;; esac
  [ "$(basename "$h")" = "$STATE_NAME" ]
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
  got="$(hook_decision pull_request "$r" "$r" "$r" "$r" checks)";   expect "$got" "allow" "checks job"
  got="$(hook_decision push "$r" "$r" "" "$r" spm-tests)";          expect "$got" "allow" "spm-tests job"
  got="$(hook_decision workflow_dispatch "$r" "$r" "" "$r" hardware-smokes)"; expect "${got%% *}" "deny" "hardware-smokes job"
  got="$(hook_decision pull_request "$r" "$r" "evil/fork" "$r")";   expect "${got%% *}" "deny" "fork PR"
  got="$(hook_decision pull_request "$r" "$r" "" "$r")";            expect "${got%% *}" "deny" "PR with deleted head repo"
  got="$(hook_decision pull_request_target "$r" "$r" "$r" "$r")";   expect "${got%% *}" "deny" "pull_request_target"
  got="$(hook_decision workflow_run "$r" "$r" "" "$r")";            expect "${got%% *}" "deny" "workflow_run"
  got="$(hook_decision issue_comment "$r" "$r" "" "$r")";           expect "${got%% *}" "deny" "issue_comment"
  got="$(hook_decision "" "$r" "$r" "" "$r")";                      expect "${got%% *}" "deny" "no event"
  got="$(hook_decision push "evil/other" "evil/other" "" "$r")";    expect "${got%% *}" "deny" "other repo"
  got="$(hook_decision push "$r" "evil/other" "" "$r")";            expect "${got%% *}" "deny" "payload names another repo"
  got="$(hook_decision push "$r" "" "" "$r")";                      expect "${got%% *}" "deny" "unreadable payload"

  got="$(offer_block 0 1 1 0 0 0)"; expect "$got" "" "free"
  got="$(offer_block 1 1 1 0 0 0)"; expect "$got" "paused" "paused"
  got="$(offer_block 0 0 1 0 0 0)"; expect "$got" "battery" "on battery"
  got="$(offer_block 0 1 0 0 0 0)"; expect "$got" "disk" "low disk"
  got="$(offer_block 0 1 1 1 0 0)"; expect "$got" "" "one other VM"
  got="$(offer_block 0 1 1 2 0 0)"; expect "$got" "vms" "two other VMs"
  got="$(offer_block 0 1 1 0 1 0)"; expect "$got" "mic" "mic in use"
  got="$(offer_block 0 1 1 0 0 1)"; expect "$got" "offline" "backing off"
  got="$(start_block 1 0 0)";       expect "$got" "" "waiting job can start"
  got="$(start_block 0 0 0)";       expect "$got" "disk" "waiting job, low disk"
  got="$(start_block 1 2 0)";       expect "$got" "vms" "waiting job, no VM slot"
  got="$(start_block 1 0 1)";       expect "$got" "offline" "waiting job, backing off"
  got="$(heartbeat_value "" 123)";     expect "$got" "123" "free heartbeat"
  got="$(heartbeat_value busy 123)";   expect "$got" "busy:123" "busy heartbeat"
  got="$(next_backoff 0)";    expect "$got" "60" "first backoff"
  got="$(next_backoff 60)";   expect "$got" "120" "second backoff"
  got="$(next_backoff 1800)"; expect "$got" "1800" "backoff cap"

  state_dir_ok "/Users/x/.transcripted-ci" || expect bad good "state dir"
  state_dir_ok "/Users/x" && expect good bad "home as state dir"
  state_dir_ok "/Users/x/.transcripted-vm" && expect good bad "#1790's home as state dir"
  state_dir_ok "relative/.transcripted-ci" && expect good bad "relative state dir"
  state_dir_ok "/Users/x/../.transcripted-ci" && expect good bad "state dir with .."

  # install reads the Tart pin from #1790's script; prove that still parses.
  local vm_script
  vm_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../vm/transcripted-vm.sh"
  if [ -f "$vm_script" ]; then
    got="$(tart_pin "$vm_script" || echo unparsed)"
    case "$got" in
      [0-9]*" "????????????????????????????????????????????????????????????????) ;;
      *) expect "$got" "<version> <sha256>" "Tart pin in transcripted-vm.sh" ;;
    esac
  fi
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
  state_dir_ok "$STATE" || die "MAC_RUNNER_HOME must be an absolute path ending in /$STATE_NAME (got $STATE)"
}

require_gh_admin() {
  command -v gh >/dev/null || die "gh is not installed"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in"
  [ "$(gh api "repos/$REPO" --jq .permissions.admin)" = "true" ] \
    || die "the logged-in gh account is not an admin of $REPO"
}

free_gb() {
  df -g "$STATE" 2>/dev/null | awk 'NR == 2 {print $4}'
}

disk_ok() {
  local gb
  gb="$(free_gb)"
  if [ "${gb:-0}" -ge "$MIN_JOB_FREE_GB" ]; then echo 1; else echo 0; fi
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

# Virtualization.framework runs each VM in its own XPC process, whichever app
# started it (this service, scripts/vm/transcripted-vm.sh, UTM, ...).
vm_processes() {
  pgrep -u "$(id -u)" -f 'com.apple.Virtualization.VirtualMachine' 2>/dev/null || true
}

running_vms() { vm_processes | grep -c . || true; }

# set_heartbeat <word or "">. Skips the write when nothing changed recently,
# which keeps the owner's gh API use down.
LAST_BEAT="none"
LAST_BEAT_AT=0
set_heartbeat() {
  local now
  now="$(date +%s)"
  if [ "$1" = "$LAST_BEAT" ] && [ $((now - LAST_BEAT_AT)) -lt "$BEAT_EVERY" ]; then return 0; fi
  if gh variable set "$HEARTBEAT_VAR" --repo "$REPO" --body "$(heartbeat_value "$1" "$now")" >/dev/null 2>&1; then
    LAST_BEAT="$1"
    LAST_BEAT_AT="$now"
  else
    log "could not update the heartbeat (${1:-free})"
  fi
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

# Prints "<run id> <seconds waiting>" for every Swift CI job that is queued
# for this Mac. Fails on any API error.
#
# To keep the owner's API use down, a run attempt whose `checks` and
# `spm-tests` jobs both exist and neither waits for this Mac is remembered in
# $STATE/settled-runs and not looked at again (their runner never changes
# within an attempt). So a poll costs one call plus one per new run.
waiting_mac_jobs() {
  local runs key run out settled="$STATE/settled-runs" keep=""
  runs="$(gh api --paginate "repos/$REPO/actions/workflows/swift-ci.yml/runs?status=in_progress&per_page=100" \
    --jq '.workflow_runs[] | "\(.id):\(.run_attempt)"')" || return 1
  for key in $runs; do
    if grep -qx "$key" "$settled" 2>/dev/null; then
      keep="$keep$key
"
      continue
    fi
    run="${key%%:*}"
    out="$(gh api "repos/$REPO/actions/runs/$run/jobs?filter=latest&per_page=100" --jq \
      "[.jobs[] | select(.name == \"checks\" or .name == \"spm-tests\")] as \$ours
       | [\$ours[] | select(.status == \"queued\" and ((.labels // []) | any(. == \"$LABEL\")))] as \$waiting
       | ([.jobs[] | select(.name == \"pick-runner\" and .status == \"completed\")] | length > 0) as \$picked
       | if \$picked and (\$ours | length) >= 2 and ([\$ours[] | select((.labels // []) | length > 0)] | length) >= 2
            and (\$waiting | length) == 0 then \"settled\"
         else (\$waiting[] | \"$run \\(now - (.created_at | fromdateiso8601) | floor)\") end")" \
      || return 1
    if [ "$out" = "settled" ]; then
      keep="$keep$key
"
    elif [ -n "$out" ]; then
      printf '%s\n' "$out"
    fi
  done
  # Only runs still in progress stay in the file.
  printf '%s' "$keep" > "$settled.new" && mv "$settled.new" "$settled"
}

# api_quota_low: true when the owner's gh core quota is nearly used up.
# The rate_limit endpoint itself is free.
api_quota_low() {
  local left
  left="$(gh api rate_limit --jq .resources.core.remaining 2>/dev/null || echo "")"
  case "$left" in ""|*[!0-9]*) return 1 ;; esac
  [ "$left" -lt "$MIN_API_LEFT" ]
}

# Cancels a run and starts it again. The heartbeat already says this Mac is
# not free, so pick-runner sends the new attempt to GitHub's runners.
reroute_run() {
  local run="$1" status i
  log "sending run $run back to GitHub's runners"
  gh api -X POST "repos/$REPO/actions/runs/$run/cancel" >/dev/null 2>&1 || true
  for i in $(seq 1 30); do
    status="$(gh api "repos/$REPO/actions/runs/$run" --jq .status 2>/dev/null || echo unknown)"
    [ "$status" = "completed" ] && break
    [ "$LAST_BEAT" = "none" ] || set_heartbeat "$LAST_BEAT"
    # build-and-test runs even after a cancel (if: always()); don't wait on it.
    [ "$i" -ne 12 ] || gh api -X POST "repos/$REPO/actions/runs/$run/force-cancel" >/dev/null 2>&1 || true
    sleep 5
  done
  for i in 1 2 3; do
    gh api -X POST "repos/$REPO/actions/runs/$run/rerun" >/dev/null 2>&1 && return 0
    sleep 10
  done
  log "could not re-run $run; re-run it from the Actions tab"
}

is_paused() { if [ -f "$STATE/PAUSED" ]; then echo 1; else echo 0; fi; }

on_ac() { if pmset -g batt 2>/dev/null | head -n 1 | grep -q "AC Power"; then echo 1; else echo 0; fi; }

mic_in_use() {
  if [ -x "$STATE/mic-in-use" ] && "$STATE/mic-in-use"; then echo 1; else echo 0; fi
}

# Downloads the latest runner and checks its SHA-256 against GitHub's
# published value (the release asset digest, else the hash in the notes).
download_runner() {
  local dest="$1" version name want got tmp
  version="$(gh api repos/actions/runner/releases/latest --jq .tag_name)" || return 1
  version="${version#v}"
  name="actions-runner-osx-arm64-$version.tar.gz"
  want="$(gh api repos/actions/runner/releases/latest --jq ".assets[] | select(.name == \"$name\") | .digest // empty")"
  want="${want#sha256:}"
  if [ -z "$want" ]; then
    want="$(gh api repos/actions/runner/releases/latest --jq .body \
      | sed -n 's/.*<!-- BEGIN SHA osx-arm64 -->\([0-9a-f]\{64\}\)<!-- END SHA osx-arm64 -->.*/\1/p' | head -n 1)"
  fi
  [ -n "$want" ] || { log "could not find the published SHA-256 for $name"; return 1; }
  tmp="$dest.part"
  curl -fsSL -o "$tmp" "https://github.com/actions/runner/releases/download/v$version/$name" || { rm -f "$tmp"; return 1; }
  got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    log "runner download failed its checksum (got $got, want $want)"
    return 1
  fi
  mv "$tmp" "$dest"
  log "runner $version downloaded and verified"
}

# Installs the Tart release pinned in scripts/vm/transcripted-vm.sh into
# $STATE/tart.app (checksum and code signature checked). It never touches
# that script's own ~/.transcripted-vm folder.
install_tart() {
  local vm_script="$1" pin version sha tmp got
  pin="$(tart_pin "$vm_script")" || die "could not read the pinned Tart version from $vm_script"
  version="${pin%% *}"
  sha="${pin#* }"
  if [ -x "$TART" ] && [ "$("$TART" --version 2>/dev/null)" = "$version" ]; then
    log "Tart $version already installed"
    return 0
  fi
  tmp="$(mktemp -d)"
  log "downloading Tart $version"
  curl -fsSL -o "$tmp/tart.tar.gz" "https://github.com/cirruslabs/tart/releases/download/$version/tart.tar.gz" \
    || { rm -rf "$tmp"; die "Tart download failed"; }
  got="$(shasum -a 256 "$tmp/tart.tar.gz" | awk '{print $1}')"
  [ "$got" = "$sha" ] || { rm -rf "$tmp"; die "Tart download checksum mismatch (got $got, want $sha)"; }
  tar -xzf "$tmp/tart.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "could not unpack Tart"; }
  codesign --verify --deep --strict "$tmp/tart.app" || { rm -rf "$tmp"; die "Tart's code signature did not verify"; }
  spctl -a -t exec "$tmp/tart.app" >/dev/null 2>&1 || log "warning: Gatekeeper did not assess tart.app as notarized"
  rm -rf "$STATE/tart.app"
  mv "$tmp/tart.app" "$STATE/tart.app"
  rm -rf "$tmp"
  [ -x "$TART" ] || die "Tart install finished but $TART is missing"
  log "Tart $("$TART" --version 2>/dev/null) installed"
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
  GITHUB_JOB="\${GITHUB_JOB:-}" \\
  MAC_RUNNER_REPO="$REPO" \\
  /bin/bash --noprofile --norc "$GUEST_HOME/ci/mac-runner.sh" job-started-hook
HOOK

  # Starts at the guest's auto-login and runs exactly one job. It waits for
  # this boot's firewall first; the host deletes the VM when the job is done.
  cat > "$dir/ci-job.sh" <<JOB
#!/bin/bash
share="$GUEST_SHARE"
stamp=/var/run/transcripted-ci-firewall.ok
boot="\$(/usr/sbin/sysctl -n kern.bootsessionuuid)"
for _ in \$(seq 1 150); do
  [ "\$(cat "\$stamp" 2>/dev/null)" = "\$boot" ] && break
  sleep 2
done
if [ "\$(cat "\$stamp" 2>/dev/null)" != "\$boot" ]; then
  echo "no firewall this boot; not starting the runner" >> "$GUEST_HOME/ci/job.log"
  exit 1
fi
for _ in \$(seq 1 300); do
  [ -s "\$share/jitconfig" ] && break
  sleep 2
done
[ -s "\$share/jitconfig" ] || exit 1
cd "$GUEST_HOME/ci/actions-runner" || exit 1
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export ACTIONS_RUNNER_HOOK_JOB_STARTED="$GUEST_HOME/ci/job-started-hook.sh"
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1
exec ./run.sh --jitconfig "\$(cat "\$share/jitconfig")" >> "$GUEST_HOME/ci/job.log" 2>&1
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

  # The guest firewall, installed as the VM's /etc/pf.conf. A job can reach
  # the internet (GitHub, package downloads) but not the Mac running the VM,
  # other VMs, or the local network. DNS goes only to the VM network's own
  # resolver (the host's DNS proxy), and nothing can connect in.
  cat > "$dir/pf.conf" <<'PF'
# Transcripted CI VM firewall (scripts/ci/mac-runner.sh).
set skip on lo0
block drop in all label "transcripted-ci"
pass in quick proto udp from any port 67 to any port 68
pass out quick proto udp from any port 68 to any port 67 keep state
pass out quick inet proto { udp tcp } to (en0:network) port 53 keep state
block return out quick inet6 all label "transcripted-ci"
block return out quick inet to { 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4 } label "transcripted-ci"
pass out quick inet all keep state
PF

  # Loads the firewall at every boot and records that it is on, so the job
  # user's runner can check before it starts.
  cat > "$dir/firewall.sh" <<'FW'
#!/bin/bash
stamp=/var/run/transcripted-ci-firewall.ok
rm -f "$stamp"
/sbin/pfctl -q -f /etc/pf.conf || exit 1
/sbin/pfctl -q -e >/dev/null 2>&1 || true
/sbin/pfctl -s info 2>/dev/null | /usr/bin/grep -q "Status: Enabled" || exit 1
/sbin/pfctl -s rules 2>/dev/null | /usr/bin/grep -q 'label "transcripted-ci"' || exit 1
/usr/sbin/sysctl -n kern.bootsessionuuid > "$stamp"
FW

  cat > "$dir/com.transcripted.ci-firewall.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.transcripted.ci-firewall</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Library/TranscriptedCI/firewall.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

  # Tries a TCP connection to each host:port (IPv6 as [addr]:port) and
  # prints "<target> open|refused|timeout|error <seconds>" per line.
  cat > "$dir/net-probe.py" <<'PROBE'
import errno, socket, sys, time
for target in sys.argv[1:]:
    host, port = target.rsplit(":", 1)
    family = socket.AF_INET6 if host.startswith("[") else socket.AF_INET
    began = time.time()
    try:
        with socket.socket(family, socket.SOCK_STREAM) as sock:
            sock.settimeout(3)
            sock.connect((host.strip("[]"), int(port)))
        result = "open"
    except socket.timeout:
        result = "timeout"
    except OSError as error:
        result = "refused" if error.errno == errno.ECONNREFUSED else "error"
    print(f"{target} {result} {time.time() - began:.1f}")
PROBE

  # Run as root in the golden VM with the job user's name. A root daemon
  # whose program the job user could replace would hand a job root after a
  # guest restart (and root can turn the firewall off). Such programs are
  # copied somewhere only root can write, and anything else the user could
  # change fails the build.
  cat > "$dir/lock-daemons.sh" <<'LOCK'
#!/bin/bash
set -euo pipefail
user="$1"
realpath_of() { /usr/bin/python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
# True when the job user can write, or owns (and so could chmod), the path
# or any folder above it, following symlinks too.
user_can_change() {
  local p
  for p in "$1" "$(realpath_of "$1")"; do
    while [ -n "$p" ] && [ "$p" != "/" ]; do
      if sudo -u "$user" test -w "$p" || sudo -u "$user" test -O "$p"; then return 0; fi
      p="$(dirname "$p")"
    done
  done
  return 1
}
buddy=/usr/libexec/PlistBuddy
safe_dir=/Library/TranscriptedCI/daemons
mkdir -p "$safe_dir"
chown root:wheel /Library/TranscriptedCI "$safe_dir"
chmod 755 /Library/TranscriptedCI "$safe_dir"
bad=0
flag() { echo "$*"; bad=1; }
check_libs() {
  local lib
  for lib in $(otool -L "$1" 2>/dev/null | awk 'NR > 1 {print $1}'); do
    case "$lib" in /*) ;; *) continue ;; esac
    [ ! -e "$lib" ] || ! user_can_change "$lib" || flag "$1 loads $lib, which the job user can change"
  done
}
for plist in /Library/LaunchDaemons/*.plist; do
  [ -f "$plist" ] || continue
  if user_can_change "$plist"; then flag "the job user can edit $plist"; continue; fi
  prog="$("$buddy" -c "Print :Program" "$plist" 2>/dev/null || true)"
  arg0="$("$buddy" -c "Print :ProgramArguments:0" "$plist" 2>/dev/null || true)"
  exe="${prog:-$arg0}"
  if [ -n "$exe" ] && [ "${exe#/}" != "$exe" ] && [ -f "$exe" ] && user_can_change "$exe"; then
    safe="$safe_dir/$(basename "$exe")-$(printf '%s' "$exe" | shasum | cut -c1-8)"
    install -o root -g wheel -m 755 "$(realpath_of "$exe")" "$safe"
    [ "$prog" != "$exe" ] || "$buddy" -c "Set :Program $safe" "$plist"
    [ "$arg0" != "$exe" ] || "$buddy" -c "Set :ProgramArguments:0 $safe" "$plist"
    echo "moved $exe to $safe for $plist"
    check_libs "$safe"
  fi
  # Every file the daemon is started with must be out of reach too.
  i=0
  while arg="$("$buddy" -c "Print :ProgramArguments:$i" "$plist" 2>/dev/null)"; do
    if [ "${arg#/}" != "$arg" ] && [ -e "$arg" ] && user_can_change "$arg"; then
      flag "$plist starts with $arg, which the job user can change"
    fi
    i=$((i + 1))
  done
  prog="$("$buddy" -c "Print :Program" "$plist" 2>/dev/null || true)"
  if [ -n "$prog" ] && [ -e "$prog" ] && user_can_change "$prog"; then
    flag "$plist runs $prog, which the job user can change"
  fi
  env="$("$buddy" -c "Print :EnvironmentVariables" "$plist" 2>/dev/null || true)"
  if printf '%s\n' "$env" | grep -q "DYLD_"; then flag "$plist sets DYLD_ variables"; fi
  for dir in $(printf '%s\n' "$env" | sed -n 's/^ *PATH = //p' | tr ':' ' '); do
    [ ! -e "$dir" ] || ! user_can_change "$dir" || flag "$plist puts $dir, which the job user can change, on PATH"
  done
done
# Other ways macOS runs things as root.
for hook in LoginHook LogoutHook; do
  path="$(defaults read com.apple.loginwindow "$hook" 2>/dev/null || true)"
  [ -z "$path" ] || ! user_can_change "$path" || flag "the $hook $path is within the job user's reach"
done
for dir in /etc/periodic /usr/local/etc/periodic /etc/periodic.conf.local; do
  [ ! -e "$dir" ] || ! user_can_change "$dir" || flag "$dir is within the job user's reach"
done
if crontab -l -u root 2>/dev/null | grep -q .; then flag "root has a crontab; check it by hand"; fi
[ "$bad" = 0 ] || exit 1
echo lock-daemons-ok
LOCK

  # Run once in the golden VM as the job user: install the runner, then prove
  # the hook refuses a fork PR and accepts a same-repo push.
  cat > "$dir/guest-user-setup.sh" <<SETUP
#!/bin/bash
set -euo pipefail
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
GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="\$tmp/push.json" GITHUB_REPOSITORY="$REPO" GITHUB_JOB=checks \\
  /bin/bash "\$ci/job-started-hook.sh" || { echo "the hook refused a same-repo push"; exit 1; }
if GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="\$tmp/fork.json" GITHUB_REPOSITORY="$REPO" GITHUB_JOB=checks \\
  /bin/bash "\$ci/job-started-hook.sh"; then
  echo "the hook accepted a fork PR"; exit 1
fi
rm -rf "\$tmp"
echo guest-user-setup-ok
SETUP

  # Run once in the golden VM as root: the user setup above, then the
  # firewall, then take admin rights away from the job user. Each step is
  # proved before the image is kept.
  cat > "$dir/guest-setup.sh" <<SETUP
#!/bin/bash
set -euo pipefail
echo "tart exec runs this as uid \$(id -u)"
if [ "\$(id -u)" != 0 ]; then exec sudo -n /bin/bash "\$0" "\$@"; fi
share="$GUEST_SHARE"
user="$GUEST_USER"
as_user() { sudo -u "\$user" -H "\$@"; }

as_user /bin/bash "\$share/guest-user-setup.sh" > /tmp/guest-user-setup.log 2>&1 || true
cat /tmp/guest-user-setup.log
grep -qx guest-user-setup-ok /tmp/guest-user-setup.log || { echo "user setup failed"; exit 1; }

gw="\$(/sbin/route -n get default 2>/dev/null | awk '/gateway:/ {print \$2}')"
[ -n "\$gw" ] || { echo "no default gateway"; exit 1; }
[ "\$(/sbin/route -n get default 2>/dev/null | awk '/interface:/ {print \$2}')" = en0 ] \\
  || { echo "the default route is not on en0; the firewall rules assume it is"; exit 1; }
# The Mac (AirPlay, SSH), CGNAT/Tailscale, the LAN ranges, an address that
# goes nowhere, and IPv6. None may connect once the firewall is on.
probes="\$gw:5000 \$gw:7000 \$gw:22 100.100.100.100:53 10.255.255.1:9 172.16.0.1:80 192.168.255.254:80 [2606:4700:4700::1111]:53"
# shellcheck disable=SC2086 # one argument per probe
as_user /usr/bin/python3 -I "\$share/net-probe.py" \$probes > /tmp/probe-before.log 2>&1 || true

mkdir -p /Library/TranscriptedCI
[ -f /etc/pf.conf.apple ] || cp /etc/pf.conf /etc/pf.conf.apple
install -o root -g wheel -m 644 "\$share/pf.conf" /etc/pf.conf
install -o root -g wheel -m 755 "\$share/firewall.sh" /Library/TranscriptedCI/firewall.sh
install -o root -g wheel -m 644 "\$share/com.transcripted.ci-firewall.plist" /Library/LaunchDaemons/com.transcripted.ci-firewall.plist
/bin/bash /Library/TranscriptedCI/firewall.sh || { echo "the firewall did not load"; exit 1; }
[ "\$(cat /var/run/transcripted-ci-firewall.ok)" = "\$(sysctl -n kern.bootsessionuuid)" ] || { echo "the firewall did not confirm"; exit 1; }
/sbin/pfctl -z >/dev/null 2>&1 || true
# shellcheck disable=SC2086 # one argument per probe
as_user /usr/bin/python3 -I "\$share/net-probe.py" \$probes > /tmp/probe-after.log 2>&1 || true
echo "before the firewall:"; cat /tmp/probe-before.log
echo "with the firewall:"; cat /tmp/probe-after.log
[ "\$(grep -c . /tmp/probe-after.log)" = "\$(echo "\$probes" | wc -w | tr -d ' ')" ] || { echo "the network probe did not run"; exit 1; }
if grep -q " open " /tmp/probe-after.log; then echo "the firewall is on but the VM can still reach a blocked address"; exit 1; fi
# pf's own counters must show it stopped those packets, so this can't pass
# just because nothing happened to be listening.
blocked="\$(/sbin/pfctl -s labels 2>/dev/null | awk '\$1 == "transcripted-ci" {n += \$3} END {print n + 0}')"
[ "\$blocked" -gt 0 ] || { echo "pf blocked nothing during the probe"; exit 1; }
echo "pf blocked \$blocked packets during the probe"
as_user /usr/bin/curl -fsS -m 30 -o /dev/null https://api.github.com/zen \\
  || { echo "the VM can't reach GitHub through the firewall"; exit 1; }

# No admin rights for the job user, so a job can't turn the firewall off.
dseditgroup -o edit -d "\$user" -t user admin 2>/dev/null || true
dsmemberutil flushcache 2>/dev/null || true
for f in /etc/sudoers.d/*; do
  [ -f "\$f" ] || continue
  if grep -Eq "^[[:space:]]*\${user}[[:space:]]" "\$f"; then rm -f "\$f"; fi
done
if grep -Eq "^[[:space:]]*\${user}[[:space:]]" /etc/sudoers; then
  sed -E "/^[[:space:]]*\${user}[[:space:]]/d" /etc/sudoers > /tmp/sudoers.new
  visudo -c -f /tmp/sudoers.new >/dev/null || { echo "could not edit /etc/sudoers"; exit 1; }
  install -o root -g wheel -m 440 /tmp/sudoers.new /etc/sudoers
fi
if dsmemberutil checkmembership -U "\$user" -G admin | grep -q "is a member"; then
  echo "\$user is still an admin"; exit 1
fi
/bin/bash "\$share/lock-daemons.sh" "\$user" > /tmp/lock-daemons.log 2>&1 || true
cat /tmp/lock-daemons.log
grep -qx lock-daemons-ok /tmp/lock-daemons.log || { echo "a root daemon is within the job user's reach"; exit 1; }
members="\$(dscl . -read /Groups/admin GroupMembership 2>/dev/null | sed 's/^GroupMembership://' | xargs)"
[ -z "\$members" ] || [ "\$members" = root ] || { echo "the admin group still has: \$members"; exit 1; }
if as_user sudo -n -k true >/dev/null 2>&1; then echo "\$user can still sudo without a password"; exit 1; fi
if printf 'admin\n' | as_user sudo -S -k -p "" true >/dev/null 2>&1; then echo "\$user can still sudo"; exit 1; fi
sync
echo guest-setup-ok
SETUP
  chmod 755 "$dir"/*.sh
}

guest_exec() { "$TART" exec "$@" </dev/null; }

# wait_for_guest <vm> <tart pid>: exec works, desktop logged in, share mounted.
wait_for_guest() {
  local vm="$1" pid="$2" deadline=$((SECONDS + BOOT_TIMEOUT))
  until guest_exec "$vm" true >/dev/null 2>&1; do
    kill -0 "$pid" 2>/dev/null || { log "$vm stopped while booting"; return 1; }
    [ "$SECONDS" -lt "$deadline" ] || { log "$vm never answered tart exec"; return 1; }
    sleep 3
  done
  until [ "$(guest_exec "$vm" stat -f %Su /dev/console 2>/dev/null)" = "$GUEST_USER" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { log "$vm never logged in to its desktop"; return 1; }
    sleep 3
  done
  until guest_exec "$vm" test -f "$GUEST_SHARE/guest-setup.sh" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || { log "$vm never mounted the shared folder"; return 1; }
    sleep 3
  done
}

# Builds a new golden VM next to the old one and swaps it in only once it is
# proved. Every failure cleans up and returns 1; it never relies on set -e,
# so it behaves the same inside `if` and `||`.
build_golden() {
  local share="$STATE/share/golden" cpu mem gb pid=""
  mkdir -p "$STATE/logs"
  golden_failed() {
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    delete_vm "$BUILD_VM"
    rm -rf "$share"
    log "CI image build failed: $1 (logs in $STATE/logs)"
    return 1
  }
  if vm_exists "$BASE_VM" && [ "$(cat "$STATE/base-image" 2>/dev/null)" != "$IMAGE" ]; then
    log "the pinned CI image changed; replacing the old download"
    delete_vm "$BASE_VM"
  fi
  if ! vm_exists "$BASE_VM"; then
    gb="$(free_gb)"
    [ "${gb:-0}" -ge "$MIN_FREE_GB" ] || { golden_failed "need about $MIN_FREE_GB GB free to download the CI image, have ${gb:-0} GB"; return 1; }
    log "downloading the CI image $IMAGE (tens of GB, this takes a while)"
    "$TART" clone "$IMAGE" "$BASE_VM" || { golden_failed "could not download $IMAGE"; return 1; }
    echo "$IMAGE" > "$STATE/base-image"
  fi
  cpu="${MAC_RUNNER_CPU:-$(( $(sysctl -n hw.ncpu) / 2 ))}"
  [ "$cpu" -ge 4 ] || cpu=4
  mem="${MAC_RUNNER_MEMORY_MB:-8192}"

  delete_vm "$BUILD_VM"
  rm -rf "$share"
  { mkdir -p "$share" && chmod 700 "$share"; } || { golden_failed "shared folder"; return 1; }
  download_runner "$share/runner.tar.gz" || { golden_failed "runner download"; return 1; }
  write_guest_files "$share" || { golden_failed "guest files"; return 1; }
  "$TART" clone "$BASE_VM" "$BUILD_VM" || { golden_failed "clone"; return 1; }
  "$TART" set "$BUILD_VM" --cpu "$cpu" --memory "$mem" || { golden_failed "VM size"; return 1; }
  log "booting $BUILD_VM to set it up"
  "$TART" run "$BUILD_VM" --no-graphics --no-audio --no-clipboard --dir "ci:$share:ro" \
    > "$STATE/logs/$BUILD_VM.log" 2>&1 < /dev/null &
  pid=$!
  wait_for_guest "$BUILD_VM" "$pid" || { golden_failed "boot"; return 1; }
  local setup_log="$STATE/logs/$BUILD_VM-setup.log"
  guest_exec "$BUILD_VM" /bin/bash "$GUEST_SHARE/guest-setup.sh" > "$setup_log" 2>&1 || true
  if ! grep -qx guest-setup-ok "$setup_log"; then
    tail -n 20 "$setup_log" >&2
    golden_failed "guest setup"
    return 1
  fi
  "$TART" stop "$BUILD_VM" --timeout 120 >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
  pid=""

  delete_vm "$OLD_GOLDEN_VM"
  if vm_exists "$GOLDEN_VM"; then
    "$TART" rename "$GOLDEN_VM" "$OLD_GOLDEN_VM" || { golden_failed "moving the old image aside"; return 1; }
  fi
  if ! "$TART" rename "$BUILD_VM" "$GOLDEN_VM"; then
    if vm_exists "$OLD_GOLDEN_VM"; then "$TART" rename "$OLD_GOLDEN_VM" "$GOLDEN_VM" || true; fi
    golden_failed "swapping in the new image"
    return 1
  fi
  delete_vm "$OLD_GOLDEN_VM"
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
  local vm name
  for vm in $(vm_names); do
    case "$vm" in "$JOB_PREFIX"*|"$BUILD_VM") delete_vm "$vm" ;; esac
  done
  rm -rf "$STATE/share"/"$JOB_PREFIX"*
  for name in $(gh api "repos/$REPO/actions/runners?per_page=100" --jq \
      ".runners[] | select(.name | test(\"$RUNNER_NAME_RE\")) | select(.busy | not) | .name" 2>/dev/null); do
    delete_runner "$name"
  done
}

# Runs one waiting job in a fresh VM. Returns 0 once the VM's runner was seen
# (whether or not a job ran), 1 when it never connected, so the caller backs
# off. A registration is only minted once the VM has booted.
run_one_job() {
  local stamp name vm share pid="" before vmpids="" jit p
  stamp="$(date +%s)"
  name="$LABEL-$stamp"
  vm="$JOB_PREFIX$stamp"
  share="$STATE/share/$vm"
  mkdir -p "$share"
  chmod 700 "$share"

  local result=1 seen=0 registered=0 started=0 gone=0 throttled=0 minted=0 connected_at=0 busy_since=0 lost_since=0 now state
  finish() {
    set_heartbeat offline
    [ "$minted" = "0" ] || delete_runner "$name"
    delete_vm "$vm"
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    rm -rf "$share"
    if [ "$result" != "0" ]; then
      log "$vm failed; last Tart output: $(tail -n 3 "$STATE/logs/job.log" 2>/dev/null | tr '\n' ' ')"
    fi
    return "$result"
  }

  if ! "$TART" clone "$GOLDEN_VM" "$vm" > "$STATE/logs/job.log" 2>&1; then
    finish
    return
  fi
  before="$(vm_processes)"
  nice -n 10 "$TART" run "$vm" --no-graphics --no-audio --no-clipboard --dir "ci:$share:ro" \
    >> "$STATE/logs/job.log" 2>&1 < /dev/null &
  pid=$!
  # Keep the Mac from idle-sleeping for as long as this VM runs.
  caffeinate -i -w "$pid" >/dev/null 2>&1 &
  log "$vm booting"

  local began deadline
  began="$(date +%s)"
  deadline=$((began + BOOT_TIMEOUT + JOB_MAX_SECONDS))
  until guest_exec "$vm" true >/dev/null 2>&1; do
    if ! kill -0 "$pid" 2>/dev/null; then log "$vm stopped while booting"; finish; return; fi
    if [ $(( $(date +%s) - began )) -gt "$BOOT_TIMEOUT" ]; then log "$vm never booted"; finish; return; fi
    set_heartbeat busy
    sleep 5
  done

  # Lower the VM's own process too; it isn't a child of tart. Only when
  # exactly one VM process appeared, so another app's VM that started at
  # the same moment is never slowed down by mistake.
  local new_pids=""
  for p in $(vm_processes); do
    printf '%s\n' "$before" | grep -qx "$p" || new_pids="$new_pids $p"
  done
  if [ "$(echo "$new_pids" | wc -w | tr -d ' ')" = "1" ]; then
    vmpids="$new_pids"
    for p in $vmpids; do renice -n 10 -p "$p" >/dev/null 2>&1 || true; done
  else
    log "could not tell which VM process is $vm; leaving priorities alone"
  fi

  if ! jit="$(mint_jit "$name")" || [ -z "$jit" ]; then
    log "could not get a runner registration"
    finish
    return
  fi
  minted=1
  (umask 077; printf '%s' "$jit" > "$share/jitconfig")
  jit=""
  local minted_at
  minted_at="$(date +%s)"

  while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"
    [ "$now" -lt "$deadline" ] || { log "$vm hit its time limit"; break; }
    state="$(runner_state "$name")"
    [ "$state" = "gone" ] || gone=0
    [ "$state" = "offline" ] || lost_since=0
    case "$state" in busy|idle|offline) registered=1 ;; esac
    case "$state" in
      busy)
        seen=1
        started=1
        [ "$busy_since" -ne 0 ] || busy_since="$now"
        set_heartbeat busy
        [ $((now - busy_since)) -lt "$JOB_MAX_SECONDS" ] || { log "$vm ran past the job time limit"; break; }
        # During a call the job drops to background priority (efficiency
        # cores, throttled disk) instead of failing.
        if [ "$(mic_in_use)" = "1" ]; then
          if [ "$throttled" = "0" ] && [ -n "$vmpids" ]; then
            for p in $vmpids; do taskpolicy -b -p "$p" >/dev/null 2>&1 || true; done
            throttled=1
            log "mic in use: $vm slowed down"
          fi
        elif [ "$throttled" = "1" ]; then
          for p in $vmpids; do taskpolicy -B -p "$p" >/dev/null 2>&1 || true; done
          throttled=0
          log "mic free: $vm back to normal priority"
        fi
        ;;
      idle)
        seen=1
        [ "$connected_at" -ne 0 ] || connected_at="$now"
        set_heartbeat busy
        if [ "$started" = "0" ] && [ $((now - connected_at)) -gt "$PICKUP_SECONDS" ]; then
          log "no job came for $vm"
          break
        fi
        ;;
      gone)
        # Ephemeral runners deregister after their one job. Only once the
        # registration has shown up at all, and twice in a row, so a lagging
        # runner list can't end a job that hasn't started.
        if [ "$registered" = "1" ]; then
          gone=$((gone + 1))
          if [ "$gone" -ge 2 ]; then
            seen=1
            log "runner $name finished (saw it running: $started)"
            break
          fi
        elif [ $((now - minted_at)) -gt "$BOOT_TIMEOUT" ]; then
          log "runner $name never showed up on GitHub"
          break
        else
          set_heartbeat busy
        fi
        ;;
      offline|error)
        set_heartbeat busy
        if [ "$seen" = "0" ] && [ $((now - minted_at)) -gt "$BOOT_TIMEOUT" ]; then
          log "$vm never connected its runner"
          break
        fi
        if [ "$seen" = "1" ] && [ "$state" = "offline" ]; then
          [ "$lost_since" -ne 0 ] || lost_since="$now"
          if [ $((now - lost_since)) -gt "$LOST_SECONDS" ]; then
            log "$vm's runner dropped off GitHub mid-job; giving up on it"
            break
          fi
        fi
        ;;
    esac
    sleep "$INTERVAL"
  done
  [ "$seen" = "0" ] || result=0
  finish
}

rotate_log() {
  local file="$STATE/serve.log"
  if [ -f "$file" ] && [ "$(wc -c < "$file")" -gt 5242880 ]; then
    # launchd keeps the file open for appending, so copy and truncate.
    cp "$file" "$file.1" && : > "$file"
  fi
}

serve() {
  set +e
  state_dir_ok "$STATE" || die "bad state folder $STATE"
  mkdir -p "$STATE/logs"
  cleanup_leftovers
  local backoff=0 retry_at=0 now waiting oldest block backing_off run age
  local last_free=0 quota_checked=0 quota_low=0 pause_for rerouted
  rm -f "$STATE/STOPPED"
  while true; do
    rotate_log
    now="$(date +%s)"
    # install/rebuild ask the service to park here, between jobs, before they
    # stop it. A job that shows up meanwhile goes back to GitHub.
    if [ -f "$STATE/STOP" ]; then
      set_heartbeat paused
      # Send anything already waiting back to GitHub first, and only say
      # "stopped" once a pass finds nothing left, so the installer can't
      # stop this service halfway through a cancel and re-run.
      if ! waiting="$(waiting_mac_jobs)"; then
        sleep "$INTERVAL"
        continue
      fi
      if [ -n "$waiting" ]; then
        rm -f "$STATE/STOPPED"
        for run in $(printf '%s\n' "$waiting" | awk '{print $1}' | sort -u); do
          reroute_run "$run"
          set_heartbeat paused
        done
        continue
      fi
      [ -f "$STATE/STOPPED" ] || { echo "$$" > "$STATE/STOPPED"; log "parked for install/rebuild"; }
      sleep "$INTERVAL"
      continue
    fi
    rm -f "$STATE/STOPPED"
    if [ "$now" -lt "$retry_at" ]; then backing_off=1; else backing_off=0; fi
    if [ $((now - quota_checked)) -ge 600 ]; then
      quota_checked="$now"
      if api_quota_low; then
        [ "$quota_low" = "1" ] || log "the gh API quota is low; polling slowly and not taking new runs"
        quota_low=1
      else
        quota_low=0
      fi
    fi
    # A new job can only be on its way here if this Mac said "free" lately.
    if [ "$quota_low" = "0" ] && [ $((now - last_free)) -lt "$FREE_GRACE" ]; then
      pause_for="$INTERVAL"
    else
      pause_for="$SLOW_INTERVAL"
    fi
    if ! vm_exists "$GOLDEN_VM"; then
      set_heartbeat offline
      log "no CI image; run: bash $STATE/mac-runner.sh rebuild"
      sleep 300
      continue
    fi
    if ! waiting="$(waiting_mac_jobs)"; then
      set_heartbeat offline
      sleep "$pause_for"
      continue
    fi

    if [ -z "$waiting" ]; then
      if golden_is_stale && [ "$(is_paused)" = "0" ]; then
        set_heartbeat offline
        log "CI image is older than $GOLDEN_MAX_AGE_DAYS days; rebuilding"
        if ! /bin/bash "$STATE/mac-runner.sh" build-golden; then
          log "rebuild failed; keeping the old image for another day"
          echo $(( $(date +%s) - (GOLDEN_MAX_AGE_DAYS - 1) * 86400 )) > "$STATE/golden-built-at"
        fi
        continue
      fi
      if [ "$quota_low" = "1" ]; then backing_off=1; fi
      block="$(offer_block "$(is_paused)" "$(on_ac)" "$(disk_ok)" "$(running_vms)" "$(mic_in_use)" "$backing_off")"
      set_heartbeat "$block"
      if [ -z "$block" ]; then
        last_free="$now"
        pause_for="$INTERVAL"
      fi
      sleep "$pause_for"
      continue
    fi

    # A job is waiting for this Mac. Stop offering it to new runs first.
    block="$(start_block "$(disk_ok)" "$(running_vms)" "$backing_off")"
    set_heartbeat "${block:-busy}"
    if [ -z "$block" ]; then
      if run_one_job; then
        backoff=0
        retry_at=0
      else
        backoff="$(next_backoff "$backoff")"
        retry_at=$(( $(date +%s) + backoff ))
        log "trying again in ${backoff}s"
      fi
      continue
    fi
    set_heartbeat "$block"
    oldest=0
    while read -r run age; do
      [ -n "$run" ] || continue
      [ "$age" -le "$oldest" ] || oldest="$age"
    done <<< "$waiting"
    if [ "$oldest" -gt "$REROUTE_SECONDS" ]; then
      log "a job has waited ${oldest}s and this Mac can't start it ($block)"
      rerouted=0
      for run in $(printf '%s\n' "$waiting" | awk -v max="$REROUTE_SECONDS" '$2 > max {print $1}' | sort -u); do
        [ "$rerouted" -lt 3 ] || break
        reroute_run "$run"
        rerouted=$((rerouted + 1))
        set_heartbeat "$block"
      done
    fi
    sleep "$INTERVAL"
  done
}

# --- owner commands ------------------------------------------------------------------

service_loaded() { launchctl print "gui/$(id -u)/$AGENT" >/dev/null 2>&1; }

# Parks the service between jobs (see serve), then stops it, so install and
# rebuild never work on the CI image at the same time as the service. The
# caller restarts it with start_service; restart_on_failure covers errors.
stop_service_between_jobs() {
  service_loaded || return 0
  rm -f "$STATE/STOPPED"
  touch "$STATE/STOP"
  log "waiting for the CI service to finish any running job"
  until [ -f "$STATE/STOPPED" ]; do
    service_loaded || break
    sleep 5
  done
  launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
}

# restart_on_failure: an EXIT trap for install/rebuild. If they die after
# stopping the service, start it again on the old image.
restart_on_failure() {
  local status=$?
  rm -f "$STATE/STOP" "$STATE/STOPPED"
  [ "$status" -ne 0 ] || return 0
  if [ -f "$HOME/Library/LaunchAgents/$AGENT.plist" ] && ! service_loaded; then
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$AGENT.plist" 2>/dev/null \
      && echo "mac-runner: restarted the CI service on the old image" >&2
  fi
}

start_service() {
  local plist="$HOME/Library/LaunchAgents/$AGENT.plist" _
  rm -f "$STATE/STOP" "$STATE/STOPPED"
  launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null && break
    sleep 1
  done
  service_loaded || die "the CI service did not start"
  log "CI service running"
}

install() {
  require_host
  require_gh_admin
  local here vm_script
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  vm_script="$here/../vm/transcripted-vm.sh"
  [ -f "$vm_script" ] || die "run install from a repo checkout (it reads the pinned Tart from scripts/vm/transcripted-vm.sh)"
  if [ -e "$STATE" ] && [ ! -f "$STATE/$STATE_MARKER" ]; then
    { [ -d "$STATE" ] && [ -z "$(ls -A "$STATE")" ]; } || die "$STATE exists but was not made by this script; move it away first"
  fi
  mkdir -p "$STATE/logs" "$STATE/share"
  : > "$STATE/$STATE_MARKER"
  chmod 700 "$STATE"
  local gb
  gb="$(free_gb)"
  if [ ! -x "$TART" ] || ! vm_exists "$BASE_VM"; then
    [ "${gb:-0}" -ge "$MIN_FREE_GB" ] || die "need about $MIN_FREE_GB GB free for the CI image; this Mac has ${gb:-0} GB"
  fi

  # Only this setup's runners may be registered: any other runner would have
  # no job-started hook and no throwaway VM.
  local others
  others="$(gh api "repos/$REPO/actions/runners?per_page=100" --jq \
    ".runners[] | select(.name | test(\"$RUNNER_NAME_RE\") | not) | \"\(.name) (\(.status), labels: \([.labels[].name] | join(\",\")))\"")"
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

  # Re-running install updates a live setup: wait for the running job, stop
  # the service, then carry on. A pause the owner set stays set.
  trap restart_on_failure EXIT
  stop_service_between_jobs

  if [ "$here/mac-runner.sh" != "$STATE/mac-runner.sh" ]; then
    cp "$here/mac-runner.sh" "$STATE/mac-runner.sh.new"
    mv "$STATE/mac-runner.sh.new" "$STATE/mac-runner.sh"
  fi
  install_tart "$vm_script"
  if ! build_mic_helper "$STATE/mic-in-use"; then
    log "WARNING: could not build the microphone check; the Mac will take jobs during calls"
  fi

  set_heartbeat offline
  build_golden || die "could not build the CI image; see $STATE/logs"

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
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$STATE/serve.log</string>
  <key>StandardErrorPath</key><string>$STATE/serve.log</string>
</dict>
</plist>
PLIST
  plutil -lint "$plist" >/dev/null
  start_service
  trap - EXIT
  status
}

rebuild() {
  require_host
  require_gh_admin
  [ -x "$TART" ] || die "not installed; run install first"
  trap restart_on_failure EXIT
  stop_service_between_jobs
  build_golden || log "rebuild failed; the old image is still in place"
  start_service
  trap - EXIT
}

status() {
  echo "runners on $REPO:"
  gh api "repos/$REPO/actions/runners?per_page=100" --jq \
    '.runners[] | "  \(.name): \(.status)\(if .busy then ", busy" else "" end) [\([.labels[].name] | join(","))]"'
  echo "heartbeat: $(gh variable get "$HEARTBEAT_VAR" --repo "$REPO" 2>/dev/null || echo unset) (now $(date +%s))"
  echo "jobs waiting for this Mac: $(waiting_mac_jobs 2>/dev/null | grep -c . || true)"
  if [ "$(is_paused)" = "1" ]; then echo "paused: yes"; else echo "paused: no"; fi
  if [ -f "$STATE/STOP" ]; then
    echo "parked for install/rebuild: yes (if no install is running, run resume)"
  fi
  if service_loaded; then echo "CI service: loaded"; else echo "CI service: not loaded"; fi
  if [ -x "$TART" ]; then
    echo "CI VMs: $(vm_names | tr '\n' ' ')"
  else
    echo "CI VMs: Tart not installed"
  fi
  echo "VMs running on this Mac (any app): $(running_vms) of $MAX_VMS"
  echo "disk: $(du -sh "$STATE" 2>/dev/null | awk '{print $1}') used, $(free_gb) GB free"
}

pause() {
  state_dir_ok "$STATE" || die "bad state folder $STATE"
  mkdir -p "$STATE"
  touch "$STATE/PAUSED"
  set_heartbeat paused
  log "paused: new runs go to GitHub. Jobs already sent here still finish; status shows when none are left"
}

resume() {
  rm -f "$STATE/PAUSED" "$STATE/STOP" "$STATE/STOPPED"
  log "resumed"
}

uninstall() {
  require_host
  [ -f "$STATE/$STATE_MARKER" ] || die "$STATE was not made by this script (no $STATE_MARKER); not deleting it"
  # Local teardown first, so it works even when gh is logged out.
  launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$AGENT.plist"
  if [ -x "$TART" ]; then
    local vm
    for vm in $(vm_names); do delete_vm "$vm"; done
  fi
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh variable delete "$HEARTBEAT_VAR" --repo "$REPO" >/dev/null 2>&1 || true
    local name run
    for name in $(gh api "repos/$REPO/actions/runners?per_page=100" --jq \
        ".runners[] | select(.name | test(\"$RUNNER_NAME_RE\")) | .name" 2>/dev/null); do
      delete_runner "$name"
    done
    for run in $(waiting_mac_jobs 2>/dev/null | awk '{print $1}' | sort -u); do
      reroute_run "$run"
    done
  else
    log "gh is not logged in: delete the $HEARTBEAT_VAR repo variable and any transcripted-mac runners by hand"
  fi
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
  decision="$(hook_decision "${GITHUB_EVENT_NAME:-}" "${GITHUB_REPOSITORY:-}" "$payload_repo" "$head_repo" "$REPO" "${GITHUB_JOB:-}")"
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
  build-golden) build_golden ;;
  job-started-hook) job_started_hook ;;
  *) sed -n '2,14p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac
