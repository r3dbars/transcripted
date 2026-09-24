#!/usr/bin/env bash
# transcripted-vm.sh: a clean, throwaway macOS VM for testing Transcripted's
# new-user setup without touching the host's real data or permissions.
#
# Built on Tart (https://tart.run), which wraps Apple's Virtualization.framework.
# One pristine "golden" VM is prepared once and never booted again. Every test
# run clones it (APFS copy-on-write, so a clone takes seconds and almost no
# disk), boots the clone, and throws it away afterwards. A fresh clone has a
# fresh TCC database, fresh preferences and no Transcripted data at all.
#
# Everything this script creates lives under $TVM_HOME (default
# ~/.transcripted-vm): the pinned Tart app, Tart's own VM + image storage
# (TART_HOME), logs, and the shared folder. `purge --yes` removes all of it.
#
# An agent drives the VM through:
#   - `exec`/`sh`       run commands inside the guest (logs, CLI, file checks)
#   - `screenshot`, `click`, `type`, `key`, ...
#                       real screen + virtual keyboard/mouse over VNC, which is
#                       what clicks macOS permission prompts (see vnc.py)
#   - `share`           a host folder mounted in the guest for files both ways
#
# Read docs/clean-vm-testing.md first. It says what a VM can and cannot test.
#
# Usage: bash scripts/vm/transcripted-vm.sh <command> [args]   (--help for list)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VNC_PY="$SCRIPT_DIR/vnc.py"

TVM_HOME="${TVM_HOME:-$HOME/.transcripted-vm}"
# Tart 2.37.0, checked 2026-09-23. Bump both together.
TVM_TART_VERSION="${TVM_TART_VERSION:-2.37.0}"
TVM_TART_SHA256="${TVM_TART_SHA256:-d531752c4dad5d4214ac7ff540cefc2647df1fca2338d413d3c01754f54b356b}"
# Cirrus Labs vanilla macOS 26.6.2 (tag 26.6.2 == latest on 2026-09-23), pinned by digest.
TVM_IMAGE="${TVM_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-vanilla@sha256:eeec54bfe1f076e27786c5d92b89187a05b1d109b5071eb2dcdf02d596e34640}"
TVM_BASE="${TVM_BASE:-transcripted-base}"
TVM_GOLDEN="${TVM_GOLDEN:-transcripted-clean}"
TVM_VM="${TVM_VM:-transcripted-test}"
TVM_CPU="${TVM_CPU:-4}"
TVM_MEMORY_MB="${TVM_MEMORY_MB:-8192}"
TVM_DISPLAY="${TVM_DISPLAY:-1440x900}"
TVM_MIN_FREE_GB="${TVM_MIN_FREE_GB:-60}"
TVM_GUEST_USER="${TVM_GUEST_USER:-admin}"
TVM_GUEST_PASS="${TVM_GUEST_PASS:-admin}"
TVM_BOOT_TIMEOUT="${TVM_BOOT_TIMEOUT:-300}"
TVM_RELEASES_URL="${TVM_RELEASES_URL:-https://github.com/r3dbars/transcripted/releases}"
TVM_RELEASES_API="${TVM_RELEASES_API:-https://api.github.com/repos/r3dbars/transcripted/releases/latest}"

APP_PATH="/Applications/Transcripted.app"
APP_SUPPORT_REL="Library/Application Support/Transcripted"
GUEST_SHARE="/Volumes/My Shared Files/tvm"
GUEST_MARKER="/Users/Shared/transcripted-test-vm.json"

# Set only while `golden` is building the clean snapshot.
ALLOW_GOLDEN=0

log() { printf '[tvm] %s\n' "$*" >&2; }
die() { printf '[tvm] error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
transcripted-vm.sh: clean macOS VM for Transcripted new-user tests (Tart).

First real run on a Mac (one command; writes a report, never uses host audio):
  first-run                 doctor + install-tart + golden + a smoke boot/install/launch,
                            plus the hardware checks from docs/clean-vm-testing.md

One-time setup (host):
  doctor                    check this Mac can run the VM
  install-tart              install the pinned Tart into ~/.transcripted-vm (checksum + signature checked)
  golden [--force]          download the pinned macOS 26 image and build the clean snapshot
  purge --yes               delete every VM, the image cache and ~/.transcripted-vm

Each test run:
  new                       fresh clone of the clean snapshot (deletes old clone)
  up [--audio] [--window]   boot the clone. Host audio is OFF unless --audio (see the doc
                            before using it: it opens the Mac's default mic).
                            --window = normal Tart window instead of VNC
  reset [--audio]           down + delete + new + up in one go
  down                      shut the clone down
  rm                        delete the clone
  status                    VMs, IP, transport, VNC (password hidden)
  save <snapshot>           keep the stopped clone as a named snapshot
  restore <snapshot>        replace the clone with a copy of a snapshot

Inside the guest:
  exec -- <cmd...>          run a command in the guest (as the GUI user)
  sh                        interactive shell in the guest (ssh)
  install-app [--version V | --latest | --dmg PATH] [--no-quarantine] [--keep-telemetry]
                            install Transcripted like a user would (DMG -> /Applications).
                            Analytics + crash reports are switched off unless --keep-telemetry
  launch | quit             open or quit Transcripted
  logs [N]                  last N lines of the app's events.jsonl + app.jsonl
  wait-event NAME [--timeout S] [--new]
                            wait until the app logs event NAME in events.jsonl
                            (--new: ignore lines already there). Exit 1 on timeout
  cli -- <args...>          run the bundled transcripted-cli
  play <file-in-guest>      play audio in the guest (the "call audio" source)
  say "<text>"              speak text through the guest speakers
  share                     print the host folder shared into the guest

Screen (VNC, real virtual keyboard/mouse):
  screenshot <out.png> [--shrink N]
  click X Y [--double] [--button right]
  move X Y | drag X1 Y1 X2 Y2 | scroll X Y up|down
  type "<text>"
  key <combo...>            e.g. key cmd-q   key return   key cmd-shift-4

Global: --vm NAME anywhere before `--` (default $TVM_VM or transcripted-test).
  To type the literal text "--vm", put it after `--`: type -- "--vm".
TVM_HOME must end in /.transcripted-vm (default ~/.transcripted-vm).
Env knobs at the top of this file: TVM_CPU, TVM_MEMORY_MB, TVM_DISPLAY, TVM_HOME ...
EOF
}

# ----------------------------------------------------------------------------
# Names and paths. Every VM/snapshot name ends up in host paths and `rm -rf`,
# so it is validated before anything else happens.

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != *..* ]] || die "bad VM name '$1' (letters, digits, . _ - only)"
}

protect_snapshot() {
  local name="$1"
  if [[ "$name" == "$TVM_BASE" || ( "$name" == "$TVM_GOLDEN" && "$ALLOW_GOLDEN" != 1 ) ]]; then
    die "$name is the clean snapshot; it is never booted, changed or overwritten (golden --force rebuilds it)"
  fi
}

# TVM_HOME is the one folder `purge` deletes, so it must be unmistakably ours:
# an absolute path whose last part is exactly .transcripted-vm, with no . or ..
# parts, holding a marker file this script wrote when it created the folder.
HOME_NAME=".transcripted-vm"
HOME_MARKER=".transcripted-vm-home"

check_home() {
  local h="$TVM_HOME"
  while [[ "$h" == */ && "$h" != / ]]; do h="${h%/}"; done
  [[ "$h" == /* ]] || die "TVM_HOME must be an absolute path"
  [[ "/$h/" != */../* && "/$h/" != */./* && "$h" != *//* ]] || die "TVM_HOME must not contain . or .. parts: $TVM_HOME"
  [[ "$(basename "$h")" == "$HOME_NAME" ]] || die "TVM_HOME must end in /$HOME_NAME (got $TVM_HOME)"
  TVM_HOME="$h"
}

# Create TVM_HOME (or adopt an empty one) and prove it is ours.
prepare_home() {
  if [[ ! -e "$TVM_HOME" ]]; then
    mkdir -p "$TVM_HOME"
    : >"$TVM_HOME/$HOME_MARKER"
  elif [[ ! -f "$TVM_HOME/$HOME_MARKER" ]]; then
    [[ -d "$TVM_HOME" && -z "$(ls -A "$TVM_HOME")" ]] \
      || die "$TVM_HOME exists but was not created by this script (no $HOME_MARKER); refusing to use it"
    : >"$TVM_HOME/$HOME_MARKER"
  fi
  local resolved
  resolved="$(cd "$TVM_HOME" && pwd -P)"
  [[ "$(basename "$resolved")" == "$HOME_NAME" ]] || die "$TVM_HOME resolves to $resolved, which is not a $HOME_NAME folder"
  TVM_HOME="$resolved"
  chmod 700 "$TVM_HOME"
  mkdir -p "$TVM_HOME/logs" "$TVM_HOME/run" "$TVM_HOME/share"
}

share_dir() { echo "$TVM_HOME/share/$1"; }
log_file() { echo "$TVM_HOME/logs/$1.log"; }
vnc_file() { echo "$TVM_HOME/run/$1.vnc"; }
transport_file() { echo "$TVM_HOME/run/$1.transport"; }

# ----------------------------------------------------------------------------
# Tart binary (pinned, lives in $TVM_HOME)

TART=""
find_tart() {
  if [[ -n "$TART" ]]; then return 0; fi
  if [[ -x "$TVM_HOME/tart.app/Contents/MacOS/tart" ]]; then
    TART="$TVM_HOME/tart.app/Contents/MacOS/tart"
  else
    return 1
  fi
}

need_tart() {
  find_tart || die "Tart is not installed. Run: bash scripts/vm/transcripted-vm.sh install-tart"
}

# Prints "running", "stopped" or nothing (no such local VM).
vm_state() {
  "$TART" list --source local --format json 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
for vm in json.load(sys.stdin):
    if vm.get("Name") == name:
        running = vm.get("Running") is True or str(vm.get("State", "")).lower() == "running"
        print("running" if running else "stopped")
' "$1" 2>/dev/null || true
}

vm_exists() { [[ -n "$(vm_state "$1")" ]]; }
vm_running() { [[ "$(vm_state "$1")" == "running" ]]; }

# ----------------------------------------------------------------------------
# Host checks and install

free_gb() {
  mkdir -p "$TVM_HOME"
  local gb
  gb="$(df -g "$TVM_HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
  echo "${gb:-0}"
}

check_free_space() {
  local gb
  gb="$(free_gb)"
  log "free disk: ${gb} GB (need about ${TVM_MIN_FREE_GB} GB: 24 GB image download + VMs)"
  (( gb >= TVM_MIN_FREE_GB )) || die "not enough free disk on this Mac"
}

cmd_doctor() {
  local ok=1
  [[ "$(uname -s)" == "Darwin" ]] || { log "not macOS: Tart needs a Mac host"; ok=0; }
  [[ "$(uname -m)" == "arm64" ]] || { log "not Apple Silicon: macOS guests need an M-series Mac"; ok=0; }
  if command -v sw_vers >/dev/null 2>&1; then
    local version
    version="$(sw_vers -productVersion)"
    log "host macOS $version"
    (( ${version%%.*} >= 26 )) || { log "the guest is macOS 26; the host needs macOS 26 or newer"; ok=0; }
  fi
  command -v python3 >/dev/null 2>&1 || { log "python3 missing (install Xcode Command Line Tools)"; ok=0; }
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local gb
    gb="$(free_gb)"
    log "free disk: ${gb} GB (need about ${TVM_MIN_FREE_GB} GB)"
    (( gb >= TVM_MIN_FREE_GB )) || { log "not enough free disk"; ok=0; }
  fi
  if find_tart; then
    log "tart: $TART ($("$TART" --version 2>/dev/null || echo unknown version); pinned $TVM_TART_VERSION)"
    "$TART" list 2>/dev/null | sed 's/^/[tvm]   /' >&2 || true
  else
    log "tart: not installed (run install-tart)"
  fi
  if python3 "$VNC_PY" --self-test >/dev/null; then log "vnc driver: ok"; else log "vnc driver self-test failed"; ok=0; fi
  if (( ok )); then log "doctor: ok"; else die "doctor found problems above"; fi
}

cmd_install_tart() {
  if find_tart; then log "tart already installed: $TART"; return 0; fi
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: tmp is local
  trap "rm -rf '$tmp'" EXIT
  log "downloading Tart $TVM_TART_VERSION"
  curl -fsSL -o "$tmp/tart.tar.gz" "https://github.com/cirruslabs/tart/releases/download/$TVM_TART_VERSION/tart.tar.gz"
  local got
  got="$(shasum -a 256 "$tmp/tart.tar.gz" | awk '{print $1}')"
  [[ "$got" == "$TVM_TART_SHA256" ]] || die "Tart download checksum mismatch (got $got, want $TVM_TART_SHA256)"
  tar -xzf "$tmp/tart.tar.gz" -C "$tmp"
  codesign --verify --deep --strict "$tmp/tart.app" || die "Tart's code signature did not verify"
  spctl -a -t exec "$tmp/tart.app" >/dev/null 2>&1 || log "warning: Gatekeeper did not assess tart.app as notarized"
  rm -rf "$TVM_HOME/tart.app"
  mv "$tmp/tart.app" "$TVM_HOME/tart.app"
  rm -rf "$tmp"
  trap - EXIT
  find_tart || die "Tart install finished but the binary was not found"
  log "tart installed: $TART ($("$TART" --version 2>/dev/null || true))"
}

# ----------------------------------------------------------------------------
# Guest transport: `tart exec` (guest agent over vsock, no network needed) when
# it works, else SSH with the image's default password.

askpass_script() {
  local path="$TVM_HOME/askpass.sh"
  if [[ ! -x "$path" ]]; then
    printf '#!/bin/sh\nprintf "%%s\\n" "${TVM_GUEST_PASS:-admin}"\n' >"$path"
    chmod 700 "$path"
  fi
  echo "$path"
}

# shellcheck disable=SC2054 # commas belong to ssh option values
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive
          -o ConnectTimeout=10)

guest_ip() { "$TART" ip "$1" --wait "${2:-5}" 2>/dev/null; }

# ssh_guest VM [ssh flags...] [remote command...]
# Leading words starting with "-" are ssh flags; the rest is the remote command,
# which must come after the destination.
ssh_guest() {
  local vm="$1"; shift
  local flags=()
  while [[ $# -gt 0 && "$1" == -* ]]; do flags+=("$1"); shift; done
  local ip
  ip="$(guest_ip "$vm" 10)" || die "no IP for $vm (is it running?)"
  SSH_ASKPASS="$(askpass_script)" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" TVM_GUEST_PASS="$TVM_GUEST_PASS" \
    ssh "${ssh_opts[@]}" ${flags[@]+"${flags[@]}"} "$TVM_GUEST_USER@$ip" "$@"
}

detect_transport() {
  local vm="$1"
  if "$TART" exec --help >/dev/null 2>&1 && "$TART" exec "$vm" true >/dev/null 2>&1; then
    echo exec
  elif ssh_guest "$vm" true </dev/null >/dev/null 2>&1; then
    echo ssh
  else
    return 1
  fi
}

transport() {
  local vm="$1" file found
  file="$(transport_file "$vm")"
  if [[ -s "$file" ]]; then cat "$file"; return 0; fi
  found="$(detect_transport "$vm")" || return 1
  echo "$found" >"$file"
  echo "$found"
}

# Run argv in the guest. No stdin.
guest_run() {
  local vm="$1"; shift
  local how
  how="$(transport "$vm")" || die "cannot reach $vm (tried tart exec and ssh)"
  case "$how" in
    exec) "$TART" exec "$vm" "$@" </dev/null ;;
    ssh)
      local quoted="" arg
      for arg in "$@"; do quoted+="$(printf '%q' "$arg") "; done
      ssh_guest "$vm" "$quoted" </dev/null
      ;;
    *) die "unknown transport '$how' for $vm" ;;
  esac
}

# Run a bash script in the guest as the logged-in GUI user, even when the
# transport lands as root (so `open`, `say` and ~ paths behave like a user's).
guest_user_bash() {
  local vm="$1" script="$2"; shift 2
  local wrap
  wrap='if [ "$(id -u)" = 0 ]; then u='"$TVM_GUEST_USER"'; exec launchctl asuser "$(id -u "$u")" sudo -u "$u" -H bash -c "$0" tvm "$@"; else exec bash -c "$0" tvm "$@"; fi'
  guest_run "$vm" bash -c "$wrap" "$script" "$@"
}

# ----------------------------------------------------------------------------
# VM lifecycle

wait_for_guest() {
  local vm="$1" deadline=$((SECONDS + TVM_BOOT_TIMEOUT)) found
  log "waiting for $vm to boot (up to ${TVM_BOOT_TIMEOUT}s)"
  rm -f "$(transport_file "$vm")"
  until guest_ip "$vm" 5 >/dev/null; do
    (( SECONDS < deadline )) || die "$vm never got an IP; see $(log_file "$vm")"
    sleep 3
  done
  until found="$(detect_transport "$vm" 2>/dev/null)"; do
    (( SECONDS < deadline )) || die "$vm booted but neither tart exec nor ssh answers"
    sleep 3
  done
  echo "$found" >"$(transport_file "$vm")"
  # The vanilla image auto-logs-in the admin user; wait for that GUI session.
  until [[ "$(guest_run "$vm" stat -f %Su /dev/console 2>/dev/null)" == "$TVM_GUEST_USER" ]]; do
    (( SECONDS < deadline )) || die "$vm is up but $TVM_GUEST_USER never logged in to the desktop"
    sleep 3
  done
  log "$vm is up via $found at $(guest_ip "$vm")"
}

cmd_up() {
  local vm="$1" window=0 audio=0
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --window) window=1 ;;
      --audio) audio=1 ;;
      *) die "up: unknown option $1" ;;
    esac
    shift
  done
  need_tart
  protect_snapshot "$vm"
  vm_exists "$vm" || die "no VM named $vm. Run: new"
  if vm_running "$vm"; then log "$vm is already running"; return 0; fi
  mkdir -p "$(share_dir "$vm")"
  # No clipboard sharing: host clipboard contents must not leak into paste-back tests.
  local args=(run "$vm" --no-clipboard --dir "tvm:$(share_dir "$vm")")
  if (( audio )); then
    log "host audio ON: the guest mic is this Mac's default input. Set it to the built-in mic first (AirPods would flip into call mode)."
  else
    # Guest still gets a silent speaker, so call-audio capture can be tested.
    args+=(--no-audio)
  fi
  if (( window )); then
    rm -f "$(vnc_file "$vm")"
  else
    # --no-graphics stops Tart from also opening Screen Sharing on the host.
    args+=(--vnc-experimental --no-graphics)
  fi
  # Fail clearly if this Tart build lacks a flag we rely on.
  local help_text flag
  help_text="$("$TART" run --help 2>&1 || true)"
  for flag in "${args[@]}"; do
    [[ "$flag" == --* && "$flag" != --dir ]] || continue
    [[ "$help_text" == *"$flag"* ]] || die "this Tart ($("$TART" --version 2>/dev/null)) has no 'run $flag'; expected Tart $TVM_TART_VERSION"
  done
  log "booting $vm"
  (umask 077; nohup "$TART" "${args[@]}" >"$(log_file "$vm")" 2>&1 </dev/null &
   echo $! >"$TVM_HOME/run/$vm.pid")
  if (( ! window )); then
    local deadline=$((SECONDS + 60)) url=""
    until [[ -n "$url" ]]; do
      url="$(grep -Eo 'vnc://[^[:space:]"]+' "$(log_file "$vm")" 2>/dev/null | tail -1 | sed 's/[.,]*$//' || true)"
      [[ -n "$url" ]] && break
      (( SECONDS < deadline )) || die "Tart never printed a VNC URL; see $(log_file "$vm")"
      sleep 1
    done
    (umask 077; echo "$url" >"$(vnc_file "$vm")")
  fi
  wait_for_guest "$vm"
}

cmd_down() {
  local vm="$1"
  need_tart
  if vm_running "$vm"; then
    log "shutting down $vm"
    "$TART" stop "$vm" --timeout 60 >/dev/null 2>&1 || "$TART" stop "$vm" >/dev/null 2>&1 || true
  else
    log "$vm is not running"
  fi
  rm -f "$(vnc_file "$vm")" "$(transport_file "$vm")" "$TVM_HOME/run/$vm.pid"
}

cmd_rm() {
  local vm="$1"
  need_tart
  protect_snapshot "$vm"
  cmd_down "$vm"
  if vm_exists "$vm"; then "$TART" delete "$vm"; log "deleted $vm"; fi
  local dir
  dir="$(share_dir "$vm")"
  [[ "$(dirname "$dir")" == "$TVM_HOME/share" ]] || die "refusing to delete $dir"
  rm -rf "$dir"
}

cmd_new() {
  local vm="$1"
  need_tart
  protect_snapshot "$vm"
  [[ "$vm" != "$TVM_GOLDEN" ]] || die "pick a test VM name, not the snapshot name"
  vm_exists "$TVM_GOLDEN" || die "no clean snapshot yet. Run: golden"
  if vm_exists "$vm"; then cmd_rm "$vm"; fi
  "$TART" clone "$TVM_GOLDEN" "$vm"
  log "cloned clean snapshot -> $vm"
}

cmd_reset() {
  local vm="$1"; shift
  cmd_new "$vm"
  cmd_up "$vm" "$@"
}

cmd_save() {
  local vm="$1" snap="${2:-}"
  [[ -n "$snap" ]] || die "usage: save <snapshot-name>"
  valid_name "$snap"
  need_tart
  protect_snapshot "$vm"
  [[ "$snap" != "$TVM_GOLDEN" ]] || die "$snap is the clean snapshot; save under another name"
  protect_snapshot "$snap"
  [[ "$snap" != "$vm" ]] || die "snapshot name must differ from the VM name"
  vm_exists "$vm" || die "no VM named $vm"
  ! vm_running "$vm" || die "shut $vm down first (down), then save"
  if vm_exists "$snap"; then "$TART" delete "$snap"; fi
  "$TART" clone "$vm" "$snap"
  log "saved $vm as snapshot $snap"
}

cmd_restore() {
  local vm="$1" snap="${2:-}"
  [[ -n "$snap" ]] || die "usage: restore <snapshot-name>"
  valid_name "$snap"
  need_tart
  protect_snapshot "$vm"
  [[ "$vm" != "$TVM_GOLDEN" ]] || die "cannot restore over the clean snapshot"
  [[ "$snap" != "$vm" ]] || die "snapshot name must differ from the VM name"
  vm_exists "$snap" || die "no snapshot named $snap"
  if vm_exists "$vm"; then cmd_rm "$vm"; fi
  "$TART" clone "$snap" "$vm"
  log "restored $snap -> $vm"
}

cmd_status() {
  local vm="$1"
  need_tart
  "$TART" list
  if vm_exists "$vm" && vm_running "$vm"; then
    echo "vm:        $vm (running)"
    echo "ip:        $(guest_ip "$vm" 2 || echo unknown)"
    echo "transport: $(cat "$(transport_file "$vm")" 2>/dev/null || echo unknown)"
    echo "vnc:       $(sed -E 's#(vnc://:)[^@]*@#\1***@#' "$(vnc_file "$vm")" 2>/dev/null || echo none)"
    echo "share:     $(share_dir "$vm") (guest: $GUEST_SHARE)"
  else
    echo "vm:        $vm (not running)"
  fi
  echo "storage:   $TVM_HOME ($(du -sh "$TVM_HOME" 2>/dev/null | awk '{print $1}'))"
}

cmd_purge() {
  [[ "${1:-}" == "--yes" ]] || die "purge deletes every test VM, the clean snapshot and the image cache. Run: purge --yes"
  if find_tart; then
    local name
    for name in $("$TART" list --source local --format json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(v["Name"] for v in json.load(sys.stdin)))' 2>/dev/null); do
      "$TART" stop "$name" >/dev/null 2>&1 || true
    done
  fi
  # prepare_home already proved this is our marked .transcripted-vm folder.
  [[ -f "$TVM_HOME/$HOME_MARKER" && "$(basename "$TVM_HOME")" == "$HOME_NAME" ]] || die "refusing to purge $TVM_HOME"
  log "deleting $TVM_HOME"
  rm -rf "$TVM_HOME"
  log "purged. Nothing from the test VM is left on this Mac."
}

# ----------------------------------------------------------------------------
# Golden image

# Runs inside the golden VM once. Keeps the guest quiet and predictable, then
# proves there is no trace of Transcripted.
GUEST_PREP='
set -euo pipefail
S() { if sudo -n true 2>/dev/null; then sudo "$@"; else printf "%s\n" "$TVM_PASS" | sudo -S -p "" "$@"; fi; }
S pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null
S softwareupdate --schedule off >/dev/null 2>&1 || true
S defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
S defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
defaults -currentHost write com.apple.screensaver idleTime 0
osascript -e "set volume output volume 35" >/dev/null 2>&1 || true
mkdir -p "$HOME/tvm-fixtures"
cd "$HOME/tvm-fixtures"
say -v Samantha -o call-a.aiff "Hi, thanks for joining. Can you give me a quick update on the launch plan?" || say -o call-a.aiff "Hi, thanks for joining."
say -v Daniel -o call-b.aiff "Sure. We ship on Thursday, and I will send the notes after this call." || say -o call-b.aiff "Sure, we ship on Thursday."
for f in call-a call-b; do afconvert -f WAVE -d LEI16@16000 "$f.aiff" "$f.wav" && rm -f "$f.aiff"; done
leftovers=""
for p in /Applications/Transcripted.app "$HOME/Library/Application Support/Transcripted" "$HOME/Library/Preferences/com.justinbetker.draft.plist" "$HOME/Library/Application Support/FluidAudio"; do
  [ -e "$p" ] && leftovers="$leftovers $p"
done
[ -z "$leftovers" ] || { echo "golden image is not clean:$leftovers" >&2; exit 1; }
marker_tmp="$(mktemp)"
cat >"$marker_tmp" <<JSON
{"purpose":"transcripted-clean-test-vm","image":"$TVM_IMAGE","macos":"$(sw_vers -productVersion)","build":"$(sw_vers -buildVersion)","prepared_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
S cp "$marker_tmp" "$TVM_MARKER"
S chmod 644 "$TVM_MARKER"
rm -f "$marker_tmp"
echo "guest prep ok: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
'

cmd_golden() {
  local force=0
  [[ "${1:-}" == "--force" ]] && force=1
  need_tart
  if vm_exists "$TVM_GOLDEN" && (( ! force )); then
    log "clean snapshot $TVM_GOLDEN already exists (golden --force rebuilds it)"
    return 0
  fi
  if ! vm_exists "$TVM_BASE"; then
    check_free_space
    log "downloading $TVM_IMAGE (about 24 GB; this is the slow part)"
    "$TART" clone "$TVM_IMAGE" "$TVM_BASE"
  fi
  if vm_exists "$TVM_GOLDEN"; then
    if vm_running "$TVM_GOLDEN"; then "$TART" stop "$TVM_GOLDEN" >/dev/null 2>&1 || true; fi
    "$TART" delete "$TVM_GOLDEN"
  fi
  "$TART" clone "$TVM_BASE" "$TVM_GOLDEN"
  "$TART" set "$TVM_GOLDEN" --cpu "$TVM_CPU" --memory "$TVM_MEMORY_MB" --display "$TVM_DISPLAY"
  ALLOW_GOLDEN=1
  cmd_up "$TVM_GOLDEN"
  guest_user_bash "$TVM_GOLDEN" "TVM_PASS=$(printf '%q' "$TVM_GUEST_PASS") TVM_MARKER=$(printf '%q' "$GUEST_MARKER") TVM_IMAGE=$(printf '%q' "$TVM_IMAGE"); $GUEST_PREP"
  log "shutting the clean snapshot down; it is never booted again"
  guest_run "$TVM_GOLDEN" bash -c "if sudo -n true 2>/dev/null; then sudo shutdown -h now; else printf '%s\n' $(printf '%q' "$TVM_GUEST_PASS") | sudo -S -p '' shutdown -h now; fi" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 120))
  while vm_running "$TVM_GOLDEN" && (( SECONDS < deadline )); do sleep 3; done
  cmd_down "$TVM_GOLDEN"
  rm -rf "$(share_dir "$TVM_GOLDEN")"
  ALLOW_GOLDEN=0
  log "clean snapshot ready: $TVM_GOLDEN. Next: new, then up"
}

# ----------------------------------------------------------------------------
# App inside the guest

latest_version() {
  python3 - "$TVM_RELEASES_API" <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=30) as response:
    tag = json.load(response)["tag_name"]
print(tag[1:] if tag.startswith("v") else tag)
PY
}

cmd_install_app() {
  local vm="$1"; shift
  local version="" dmg="" quarantine=1 telemetry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="${2:?}"; shift 2 ;;
      --latest) version="$(latest_version)"; shift ;;
      --dmg) dmg="${2:?}"; shift 2 ;;
      --no-quarantine) quarantine=0; shift ;;
      --keep-telemetry) telemetry=1; shift ;;
      *) die "install-app: unknown option $1" ;;
    esac
  done
  [[ -n "$version" || -n "$dmg" ]] || die "install-app needs --version V, --latest or --dmg PATH"
  [[ -z "$version" || "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "bad version: $version"
  local source
  if [[ -n "$dmg" ]]; then
    [[ -f "$dmg" ]] || die "no such DMG: $dmg"
    mkdir -p "$(share_dir "$vm")"
    cp -- "$dmg" "$(share_dir "$vm")/install.dmg"
    source="share"
    log "installing $(basename "$dmg") from the host"
  else
    source="$TVM_RELEASES_URL/download/v$version/Transcripted-$version.dmg"
    log "installing Transcripted $version from GitHub releases"
  fi
  guest_user_bash "$vm" '
set -euo pipefail
source="$1" share="$2" quarantine="$3" telemetry="$4"
dmg="$HOME/Downloads/Transcripted.dmg"
mkdir -p "$HOME/Downloads"
if [ "$source" = share ]; then cp "$share/install.dmg" "$dmg"; else curl -fL --retry 3 -o "$dmg" "$source"; fi
if [ "$quarantine" = 1 ]; then
  # What a browser download stamps on the file, so Gatekeeper treats it like one.
  xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;$(uuidgen)" "$dmg"
fi
pkill -x Transcripted 2>/dev/null && sleep 2 || true
mnt="$(mktemp -d /tmp/tvm-dmg.XXXX)"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null
trap "hdiutil detach \"$mnt\" -quiet || true" EXIT
[ -d "$mnt/Transcripted.app" ] || { echo "no Transcripted.app in the DMG" >&2; exit 1; }
rm -rf /Applications/Transcripted.app
ditto "$mnt/Transcripted.app" /Applications/Transcripted.app
if [ "$quarantine" = 1 ]; then
  xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;$(uuidgen)" /Applications/Transcripted.app
fi
if [ "$telemetry" = 0 ]; then
  # Test runs must not land in the real PostHog funnel or Sentry.
  defaults write com.justinbetker.draft observability-anonymous-analytics-enabled -bool NO
  defaults write com.justinbetker.draft observability-crash-reporting-enabled -bool NO
fi
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Transcripted.app/Contents/Info.plist | sed "s/^/installed Transcripted /"
' "$source" "$GUEST_SHARE" "$quarantine" "$telemetry"
}

cmd_launch() { guest_user_bash "$1" 'open -a /Applications/Transcripted.app && echo launched'; }
cmd_quit() { guest_user_bash "$1" 'pkill -x Transcripted && echo quit || echo "not running"'; }

cmd_logs() {
  local vm="$1" lines="${2:-40}"
  [[ "$lines" =~ ^[0-9]+$ ]] || die "logs takes a line count"
  guest_user_bash "$vm" '
dir="$HOME/'"$APP_SUPPORT_REL"'/logs"
for f in events.jsonl app.jsonl; do
  echo "== $f"; tail -n "$1" "$dir/$f" 2>/dev/null || echo "(none yet)"
done' "$lines"
}

cmd_cli() {
  local vm="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  guest_user_bash "$vm" 'exec '"$APP_PATH"'/Contents/Helpers/transcripted-cli "$@"' "$@"
}

cmd_exec() {
  local vm="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  [[ $# -gt 0 ]] || die "usage: exec -- <command...>"
  guest_user_bash "$vm" 'exec "$@"' "$@"
}

cmd_sh() { ssh_guest "$1" -t; }
cmd_play() { guest_user_bash "$1" 'afplay "$1"' "${2:?usage: play <file-in-guest>}"; }
cmd_say() { guest_user_bash "$1" 'say "$1"' "${2:?usage: say <text>}"; }
cmd_share() { mkdir -p "$(share_dir "$1")"; echo "host:  $(share_dir "$1")"; echo "guest: $GUEST_SHARE"; }

cmd_wait_event() {
  local vm="$1"; shift
  local name="${1:-}" timeout=300 new=0
  [[ -n "$name" ]] && shift
  [[ "$name" =~ ^[a-z0-9_]+$ ]] || die "usage: wait-event NAME [--timeout S] [--new] (NAME like models_loaded)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="${2:?}"; shift 2 ;;
      --new) new=1; shift ;;
      *) die "wait-event: unknown option $1" ;;
    esac
  done
  [[ "$timeout" =~ ^[0-9]+$ ]] || die "wait-event: --timeout takes seconds"
  guest_user_bash "$vm" '
f="$HOME/'"$APP_SUPPORT_REL"'/logs/events.jsonl"
name="$1" timeout="$2" new="$3"
skip=0
if [ "$new" = 1 ] && [ -f "$f" ]; then skip=$(wc -l <"$f" | tr -d " "); fi
end=$(( $(date +%s) + timeout ))
while [ "$(date +%s)" -lt "$end" ]; do
  if [ -f "$f" ] && tail -n "+$((skip + 1))" "$f" | grep -F -m1 "\"event\":\"$name\"" ; then exit 0; fi
  sleep 2
done
echo "timed out after ${timeout}s waiting for event $name" >&2
exit 1' "$name" "$timeout" "$new"
}

# ----------------------------------------------------------------------------
# First real run: one command that does setup plus a smoke run, collects the
# hardware facts the doc lists under "Check on first real run", and writes a
# report. Each step runs as its own invocation so one failure still leaves a
# useful report. Host audio stays off throughout.

cmd_first_run() {
  local self="$SCRIPT_DIR/transcripted-vm.sh" stamp dir report failed=0
  export TVM_HOME TVM_VM
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$TVM_HOME/reports/first-run-$stamp"
  report="$dir/report.md"
  mkdir -p "$dir"
  {
    echo "# Clean VM first run $stamp"
    echo
    echo "Host: macOS $(sw_vers -productVersion 2>/dev/null || echo ?), $(uname -m), repo rev $(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo ?)"
  } >"$report"

  step() {
    local title="$1" required="$2"; shift 2
    log "first-run: $title"
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    {
      echo
      echo "## $title: $([[ $rc == 0 ]] && echo ok || echo "FAILED (exit $rc)")"
      echo
      echo '```'
      printf '%s
' "$out" | tail -n 60
      echo '```'
    } >>"$report"
    if (( rc != 0 )); then
      failed=1
      [[ "$required" == required ]] && { log "first-run: stopping after '$title'; report: $report"; echo "$report"; return 1; }
    fi
    return 0
  }

  step "doctor" required bash "$self" doctor || return 1
  step "install Tart $TVM_TART_VERSION" required bash "$self" install-tart || return 1
  need_tart
  step "tart run flags" optional bash -c '"$1" --version; "$1" run --help | grep -E -- "--(no-clipboard|no-audio|vnc-experimental|no-graphics|dir)"' _ "$TART"
  step "build clean snapshot (slow)" required bash "$self" golden || return 1
  step "boot a fresh clone (no host audio)" required bash "$self" --vm "$TVM_VM" reset || return 1
  step "status" optional bash "$self" --vm "$TVM_VM" status
  step "guest user and transport" optional bash "$self" --vm "$TVM_VM" exec -- bash -c 'echo "user=$(id -un) uid=$(id -u) console=$(stat -f %Su /dev/console) macOS=$(sw_vers -productVersion)"; ls /Volumes/"My Shared Files" 2>&1; system_profiler SPAudioDataType 2>/dev/null | grep -E "^ {8}[^ ].*:$" || true'
  step "VNC server bind (expect 127.0.0.1 only)" optional bash -c 'lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -i tart || echo "no tart listener found"'
  step "VNC handshake" optional bash "$self" --vm "$TVM_VM" info
  step "screenshot: desktop" optional bash "$self" --vm "$TVM_VM" screenshot "$dir/01-desktop.png"
  step "install latest Transcripted" required bash "$self" --vm "$TVM_VM" install-app --latest || return 1
  step "launch" optional bash "$self" --vm "$TVM_VM" launch
  step "app_launched event" optional bash "$self" --vm "$TVM_VM" wait-event app_launched --timeout 120
  step "screenshot: after launch" optional bash "$self" --vm "$TVM_VM" screenshot "$dir/02-after-launch.png"
  step "app logs" optional bash "$self" --vm "$TVM_VM" logs 20
  step "shut down" optional bash "$self" --vm "$TVM_VM" down

  {
    echo
    echo "## Result: $([[ $failed == 0 ]] && echo "all steps ok" || echo "some optional steps failed")"
    echo
    echo "Screenshots: $dir"
    echo "Look at 02-after-launch.png: the Gatekeeper dialog or onboarding should be on screen."
  } >>"$report"
  log "first-run finished; report: $report"
  echo "$report"
}

# ----------------------------------------------------------------------------
# Screen

cmd_vnc() {
  local vm="$1"; shift
  local url_file
  url_file="$(vnc_file "$vm")"
  [[ -s "$url_file" ]] || die "no VNC URL for $vm (boot it with: up, not up --window)"
  TVM_VNC_URL="$(cat "$url_file")" python3 "$VNC_PY" "$@"
}

# ----------------------------------------------------------------------------

main() {
  check_home
  valid_name "$TVM_BASE"
  valid_name "$TVM_GOLDEN"
  [[ "$TVM_BASE" != "$TVM_GOLDEN" ]] || die "TVM_BASE and TVM_GOLDEN must differ"

  # Pull `--vm NAME` out from anywhere before a `--`.
  local vm="$TVM_VM" args=() seen_dashdash=0
  while [[ $# -gt 0 ]]; do
    if (( ! seen_dashdash )) && [[ "$1" == "--vm" ]]; then
      vm="${2:?--vm needs a name}"; shift 2; continue
    fi
    [[ "$1" == "--" ]] && seen_dashdash=1
    args+=("$1"); shift
  done
  set -- ${args[@]+"${args[@]}"}
  valid_name "$vm"

  local command="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "$command" in
    help|-h|--help) usage; return 0 ;;
  esac

  prepare_home
  export TART_HOME="$TVM_HOME/tart-home"

  case "$command" in
    doctor) cmd_doctor ;;
    install-tart) cmd_install_tart ;;
    golden) cmd_golden "$@" ;;
    purge) cmd_purge "$@" ;;
    new) cmd_new "$vm" ;;
    up) cmd_up "$vm" "$@" ;;
    down) cmd_down "$vm" ;;
    rm) cmd_rm "$vm" ;;
    reset) need_tart; cmd_reset "$vm" "$@" ;;
    status) cmd_status "$vm" ;;
    save) cmd_save "$vm" "$@" ;;
    restore) cmd_restore "$vm" "$@" ;;
    first-run) cmd_first_run ;;
    exec|sh|install-app|launch|quit|logs|cli|play|say|wait-event)
      need_tart
      protect_snapshot "$vm"
      vm_running "$vm" || die "$vm is not running. Run: up"
      case "$command" in
        exec) cmd_exec "$vm" "$@" ;;
        sh) cmd_sh "$vm" ;;
        install-app) cmd_install_app "$vm" "$@" ;;
        launch) cmd_launch "$vm" ;;
        quit) cmd_quit "$vm" ;;
        logs) cmd_logs "$vm" "$@" ;;
        cli) cmd_cli "$vm" "$@" ;;
        play) cmd_play "$vm" "$@" ;;
        say) cmd_say "$vm" "$@" ;;
        wait-event) cmd_wait_event "$vm" "$@" ;;
      esac
      ;;
    share) cmd_share "$vm" ;;
    screenshot|click|move|drag|scroll|type|key|info) cmd_vnc "$vm" "$command" "$@" ;;
    *) usage >&2; die "unknown command: $command" ;;
  esac
}

main "$@"
