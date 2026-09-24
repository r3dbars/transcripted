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
SUPERVISE_PY="$SCRIPT_DIR/supervise.py"

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
# 1 = allow `up --vnc` on open (unencrypted) Wi-Fi. See cmd_up.
TVM_ALLOW_VNC_ON_OPEN_WIFI="${TVM_ALLOW_VNC_ON_OPEN_WIFI:-0}"
# Bump when GUEST_PREP changes; first-run rebuilds an older clean snapshot.
GOLDEN_PREP_VERSION=3
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
  up [--vnc] [--audio] [--window]
                            boot the clone headless (commands only, no screen access).
                            --vnc = also turn on the screen (screenshot/click/type/key).
                            Tart's VNC port then listens on EVERY network interface
                            (password-protected; Tart can't limit it), so it's refused on
                            open Wi-Fi. Keep the VM down when you're done.
                            --audio = pass the Mac's default mic/speakers through (see the
                            doc first: it opens the Mac's default mic).
                            --window = normal Tart window instead
  reset [--vnc] [--audio]   down + delete + new + up in one go
  down                      shut the clone down
  rm                        delete the clone
  status                    VMs, IP, transport, VNC (password hidden)
  vnc-check                 fail if other machines on the network can reach the VNC port
  soak [SECONDS]            watch the VM for SECONDS (default 300); fail if it stops
  diagnose                  why did the VM stop? Tart's exit line, host sleep/wake,
                            crash reports, disk, and the guest's shutdown cause
  save <snapshot>           keep the stopped clone as a named snapshot
  restore <snapshot>        replace the clone with a copy of a snapshot

Inside the guest:
  exec -- <cmd...>          run a command in the guest (as the GUI user)
  sh                        interactive shell in the guest (ssh)
  install-app [--version V | --latest | --dmg PATH] [--no-quarantine] [--keep-telemetry]
                            install Transcripted like a user would (DMG -> /Applications).
                            Analytics + crash reports are switched off unless --keep-telemetry
  launch | quit             open or quit Transcripted
  approve-download          get past the "downloaded from the Internet" prompt like a user:
                            click Open inside the prompt's window over VNC (or press Return
                            while it's in front). Otherwise clears the quarantine flag and
                            exits 3, so the bypass is never mistaken for a user's path
  windows                   the guest's window list: screen width, front window's app,
                            and the download prompt's box if one is showing
  logs [N]                  last N lines of the app's events.jsonl + app.jsonl
  wait-event NAME [--timeout S] [--new]
                            wait until the app logs event NAME in events.jsonl
                            (--new: ignore lines already there). Exit 1 on timeout
  cli -- <args...>          run the bundled transcripted-cli
  play <file-in-guest>      play audio in the guest (the "call audio" source)
  say "<text>"              speak text through the guest speakers
  share                     print the host folder shared into the guest

Screen (needs up --vnc; real virtual keyboard/mouse over ONE VNC session per boot):
  screenshot <out.png> [--shrink N]
  click X Y [--double] [--button right]
  click-default-button [--dry-run] [--within X,Y,W,H --points-wide N]
                            click the blue default button (e.g. Open), optionally only inside one window
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
setup_file() { echo "$TVM_HOME/run/$1.setup"; }

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
  if python3 "$SUPERVISE_PY" --self-test >/dev/null; then log "tart helper: ok"; else log "tart helper self-test failed"; ok=0; fi
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

pid_file() { echo "$TVM_HOME/run/$1.pid"; }
vnc_sock_file() { echo "$TVM_HOME/run/$1.vncsock"; }
vnc_pid_file() { echo "$TVM_HOME/run/$1.vncpid"; }
vnc_log_file() { echo "$TVM_HOME/logs/$1.vnc.log"; }

# A socket file alone isn't a session: serve may have been killed without cleaning up.
vnc_session_alive() {
  local pid
  [[ -S "$(vnc_sock_file "$1")" ]] || return 1
  pid="$(cat "$(vnc_pid_file "$1")" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Stop waiting as soon as the tart process is gone, and say how it ended.
tart_alive_or_die() {
  local vm="$1" pid
  pid="$(cat "$(pid_file "$vm")" 2>/dev/null || true)"
  if [[ -z "$pid" ]] || kill -0 "$pid" 2>/dev/null; then return 0; fi
  tail -n 5 "$(log_file "$vm")" 2>/dev/null | sed 's/^/[tvm]   /' >&2 || true
  die "$vm stopped while booting; run: diagnose"
}

wait_for_guest() {
  local vm="$1" deadline=$((SECONDS + TVM_BOOT_TIMEOUT)) found
  log "waiting for $vm to boot (up to ${TVM_BOOT_TIMEOUT}s)"
  rm -f "$(transport_file "$vm")"
  until guest_ip "$vm" 5 >/dev/null; do
    tart_alive_or_die "$vm"
    (( SECONDS < deadline )) || die "$vm never got an IP; see $(log_file "$vm")"
    sleep 3
  done
  until found="$(detect_transport "$vm" 2>/dev/null)"; do
    tart_alive_or_die "$vm"
    (( SECONDS < deadline )) || die "$vm booted but neither tart exec nor ssh answers"
    sleep 3
  done
  echo "$found" >"$(transport_file "$vm")"
  # The vanilla image auto-logs-in the admin user; wait for that GUI session.
  until [[ "$(guest_run "$vm" stat -f %Su /dev/console 2>/dev/null)" == "$TVM_GUEST_USER" ]]; do
    tart_alive_or_die "$vm"
    (( SECONDS < deadline )) || die "$vm is up but $TVM_GUEST_USER never logged in to the desktop"
    sleep 3
  done
  close_setup_assistant "$vm"
  log "$vm is up via $found at $(guest_ip "$vm")"
}

# macOS can put Setup Assistant's own screens over the desktop at login (run 3
# on the Mac: "Update Mac Automatically"). Nothing else opens while it's up, so
# wait for the Dock, and if Setup Assistant shows instead, record it and close
# it. Prints desktop-ready, gave-up or desktop-not-ready as its last line.
SETUP_GUARD='
closed=0
for _ in $(seq 1 45); do
  pid="$(pgrep -x "Setup Assistant" | head -n 1)"
  if [ -n "$pid" ]; then
    echo "setup-assistant running: $(ps -o user=,args= -p "$pid" 2>/dev/null)"
    if [ "$closed" -ge 3 ]; then echo "gave-up: it keeps coming back"; exit 0; fi
    if pkill -x "Setup Assistant"; then closed=$((closed + 1)); echo "closed it"; else echo "could not close it"; fi
    sleep 3
    continue
  fi
  if pgrep -x Dock >/dev/null; then
    sleep 3
    pgrep -x "Setup Assistant" >/dev/null || { echo "desktop-ready (closed Setup Assistant $closed times)"; exit 0; }
    continue
  fi
  sleep 2
done
echo "desktop-not-ready: no Dock after 90s"
'

close_setup_assistant() {
  local vm="$1" out file
  file="$(setup_file "$vm")"
  out="$(guest_run "$vm" bash -c "$SETUP_GUARD" 2>&1 || true)"
  printf '%s\n' "$out" >"$file"
  case "$out" in
    *"closed it"*) log "macOS Setup Assistant was covering the desktop after login; closed it (see $file)" ;;
  esac
  case "$out" in
    *desktop-ready*) ;;
    *) log "warning: the desktop never came up clear, so apps may not open (see $file)" ;;
  esac
}

# Tart's VNC server (Virtualization.framework's private _VZVNCServer) listens
# on every network interface and Tart has no option to change that. Its
# password is random, but VNC only uses the first 8 characters. So VNC is off
# unless a run needs the screen, and never on open Wi-Fi.
refuse_open_wifi() {
  [[ "$(uname -s)" == Darwin && "$TVM_ALLOW_VNC_ON_OPEN_WIFI" != 1 ]] || return 0
  local mode
  mode="$(system_profiler SPAirPortDataType -json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for entry in data.get("SPAirPortDataType", []):
    for iface in entry.get("spairport_airport_interfaces", []):
        current = iface.get("spairport_current_network_information")
        if current:
            print(current.get("spairport_security_mode", "unknown"))
' 2>/dev/null || true)"
  case "$mode" in
    *none*|*owe*|*wep*|*open*)
      die "this Mac is on open Wi-Fi ($mode). Tart's VNC port would be reachable by anyone on it, so up --vnc is refused. Use a private network, or set TVM_ALLOW_VNC_ON_OPEN_WIFI=1 if you accept that." ;;
  esac
  return 0
}

# One VNC connection for the VM's whole life. Apple's VNC server crashed
# tart (assertion in -[_VZVNCServer _setupVirtualMachineAccessor]) when a new
# client connected after Transcripted launched, on both real runs, so screen
# commands never reconnect: they go through this session's local socket.
start_vnc_session() {
  local vm="$1" url="$2" sock
  sock="$(vnc_sock_file "$vm")"
  rm -f "$sock"
  (umask 077; : >"$(vnc_log_file "$vm")")
  TVM_VNC_URL="$url" python3 "$SUPERVISE_PY" --name "VNC session" --log "$(vnc_log_file "$vm")" \
    --pidfile "$(vnc_pid_file "$vm")" -- python3 "$VNC_PY" --socket "$sock" serve >/dev/null \
    || die "the VNC session did not start; see $(vnc_log_file "$vm")"
  local deadline=$((SECONDS + 30))
  until [[ -S "$sock" ]]; do
    if (( SECONDS >= deadline )) || grep -q "VNC session exited\|VNC session was stopped" "$(vnc_log_file "$vm")" 2>/dev/null; then
      tail -n 5 "$(vnc_log_file "$vm")" 2>/dev/null | sed 's/^/[tvm]   /' >&2 || true
      die "the VNC session did not connect; see $(vnc_log_file "$vm")"
    fi
    sleep 0.5
  done
}

cmd_up() {
  local vm="$1" window=0 audio=0 vnc=0
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vnc) vnc=1 ;;
      --window) window=1 ;;
      --audio) audio=1 ;;
      *) die "up: unknown option $1" ;;
    esac
    shift
  done
  (( ! (vnc && window) )) || die "pick one of --vnc and --window"
  need_tart
  protect_snapshot "$vm"
  vm_exists "$vm" || die "no VM named $vm. Run: new"
  if vm_running "$vm"; then
    if (( vnc )) && ! vnc_session_alive "$vm"; then
      die "$vm is already running without a VNC session; run down first, then up --vnc"
    fi
    log "$vm is already running"
    return 0
  fi
  if (( vnc )); then
    refuse_open_wifi
    log "VNC on: its port is reachable from this network, guarded only by a weak password. Use it on a network you trust, and run down when done."
  fi
  mkdir -p "$(share_dir "$vm")"
  rm -f "$(vnc_file "$vm")" "$(vnc_sock_file "$vm")"
  # No clipboard sharing: host clipboard contents must not leak into paste-back tests.
  local args=(run "$vm" --no-clipboard --dir "tvm:$(share_dir "$vm")")
  if (( audio )); then
    log "host audio ON: the guest mic is this Mac's default input. Set it to the built-in mic first (AirPods would flip into call mode)."
  else
    # Guest still gets a silent speaker, so call-audio capture can be tested.
    args+=(--no-audio)
  fi
  if (( vnc )); then
    # --no-graphics stops Tart from also opening Screen Sharing on the host.
    args+=(--vnc-experimental --no-graphics)
  elif (( ! window )); then
    args+=(--no-graphics)
  fi
  # Fail clearly if this Tart build lacks a flag we rely on.
  local help_text flag
  help_text="$("$TART" run --help 2>&1 || true)"
  for flag in "${args[@]}"; do
    [[ "$flag" == --* && "$flag" != --dir ]] || continue
    [[ "$help_text" == *"$flag"* ]] || die "this Tart ($("$TART" --version 2>/dev/null)) has no 'run $flag'; expected Tart $TVM_TART_VERSION"
  done
  log "booting $vm$( (( vnc )) && echo " with screen access (VNC)")"
  # Keep the previous boot's log: after a VM dies, it says how.
  local vm_log
  vm_log="$(log_file "$vm")"
  if [[ -f "$vm_log" ]]; then mv -f "$vm_log" "${vm_log%.log}.prev.log"; fi
  (umask 077; : >"$vm_log")
  # supervise.py starts tart in its own session (so a tool that kills the
  # caller's process group or tree cannot take the VM with it), keeps the Mac
  # from idle-sleeping, and logs exactly how tart ended.
  python3 "$SUPERVISE_PY" --log "$vm_log" --pidfile "$(pid_file "$vm")" -- "$TART" "${args[@]}" >/dev/null \
    || die "tart did not start; see $vm_log"
  if (( vnc )); then
    local deadline=$((SECONDS + 60)) url=""
    until [[ -n "$url" ]]; do
      url="$(grep -Eo 'vnc://[^[:space:]"]+' "$vm_log" 2>/dev/null | tail -1 | sed 's/[.,]*$//' || true)"
      [[ -n "$url" ]] && break
      tart_alive_or_die "$vm"
      (( SECONDS < deadline )) || die "Tart never printed a VNC URL; see $vm_log"
      sleep 1
    done
    (umask 077; echo "$url" >"$(vnc_file "$vm")")
    start_vnc_session "$vm" "$url"
    log "screen access on. Tart's VNC port listens on every network interface (password-protected; vnc-check shows who can reach it). Run down when you're done."
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
  # The VNC session exits by itself when tart's VNC server goes away.
  rm -f "$(vnc_file "$vm")" "$(transport_file "$vm")" "$(pid_file "$vm")" "$(vnc_pid_file "$vm")"
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
    echo "vnc:       $(sed -E 's#(vnc://:)[^@]*@#\1***@#' "$(vnc_file "$vm")" 2>/dev/null || echo "off (up --vnc turns it on)")"
    echo "screen:    $(vnc_session_alive "$vm" && echo "VNC session open" || echo "no VNC session")"
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
# The Cirrus image reopens a Terminal window from its own build at every
# login. Close it and stop apps and windows coming back after a restart.
killall Terminal 2>/dev/null || true
rm -rf "$HOME/Library/Saved Application State/com.apple.Terminal.savedState"
defaults write com.apple.Terminal NSQuitAlwaysKeepsWindows -bool false
defaults write com.apple.loginwindow TALLogoutSavesState -bool false
defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool false
defaults -currentHost write com.apple.loginwindow TALAppsToRelaunchAtLogin -array
# Mark Setup Assistant as done for this build, so it does not show its own
# screens at login ("Update Mac Automatically" covered the desktop on run 3).
echo "setup assistant before prep: $(defaults read com.apple.SetupAssistant 2>&1 | tr -s " \n" " " | cut -c1-800)"
build="$(sw_vers -buildVersion)"
version="$(sw_vers -productVersion)"
defaults write com.apple.SetupAssistant LastSeenBuddyBuildVersion -string "$build"
defaults write com.apple.SetupAssistant LastSeenCloudProductVersion -string "$version"
defaults write com.apple.SetupAssistant GestureMovieSeen -string none
for key in DidSeeCloudSetup DidSeeSiriSetup DidSeePrivacy DidSeeScreenTime DidSeeAppearanceSetup \
  DidSeeAccessibility DidSeeTrueTonePrivacy DidSeeTouchIDSetup DidSeeActivationLock DidSeeApplePaySetup \
  DidSeeiCloudLoginForStorageServices DidSeeSyncSetup DidSeeSyncSetup2 DidSeeIntelligence DidSeeTermsOfAddress; do
  defaults write com.apple.SetupAssistant "$key" -bool true
done
gatekeeper="$(spctl --status 2>&1 || true)"
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
{"purpose":"transcripted-clean-test-vm","image":"$TVM_IMAGE","macos":"$(sw_vers -productVersion)","build":"$(sw_vers -buildVersion)","prep":$TVM_PREP,"gatekeeper":"$gatekeeper","prepared_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
JSON
S cp "$marker_tmp" "$TVM_MARKER"
S chmod 644 "$TVM_MARKER"
rm -f "$marker_tmp"
echo "guest prep ok: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), Gatekeeper: $gatekeeper"
'

cmd_golden() {
  local force=0
  [[ "${1:-}" == "--force" ]] && force=1
  need_tart
  if vm_exists "$TVM_GOLDEN" && (( ! force )); then
    log "clean snapshot $TVM_GOLDEN already exists (golden --force rebuilds it)"
    [[ "$(cat "$TVM_HOME/golden.prep" 2>/dev/null)" == "$GOLDEN_PREP_VERSION" ]] \
      || log "note: it was prepared by an older version of this script; golden --force brings it up to date (no big download)"
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
  guest_user_bash "$TVM_GOLDEN" "TVM_PASS=$(printf '%q' "$TVM_GUEST_PASS") TVM_MARKER=$(printf '%q' "$GUEST_MARKER") TVM_IMAGE=$(printf '%q' "$TVM_IMAGE") TVM_PREP=$GOLDEN_PREP_VERSION; $GUEST_PREP"
  log "shutting the clean snapshot down; it is never booted again"
  guest_run "$TVM_GOLDEN" bash -c "if sudo -n true 2>/dev/null; then sudo shutdown -h now; else printf '%s\n' $(printf '%q' "$TVM_GUEST_PASS") | sudo -S -p '' shutdown -h now; fi" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 120))
  while vm_running "$TVM_GOLDEN" && (( SECONDS < deadline )); do sleep 3; done
  cmd_down "$TVM_GOLDEN"
  rm -rf "$(share_dir "$TVM_GOLDEN")"
  ALLOW_GOLDEN=0
  echo "$GOLDEN_PREP_VERSION" >"$TVM_HOME/golden.prep"
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

# Get past macOS's "downloaded from the Internet" prompt the way a user does:
# click its Open button over the VNC session (virtual mouse), or press Return
# since Open is the default button. Ask Gatekeeper first, while the flag is
# still on, and refuse if it would reject the app: a broken notarization must
# fail here, not slip through. Every click and key press is aimed at the
# prompt's own window, checked in the guest each time, and stops as soon as
# the app is up. "Up" means the process exists AND no prompt is showing:
# macOS starts the Transcripted process before asking and holds it until
# Open, so the process alone proves nothing (run 5 skipped the click on it).
# Clearing the quarantine flag is only the last resort; it exits
# $BYPASS_EXIT so the report can't call it a user's path.
BYPASS_EXIT=3
cmd_approve_download() {
  local vm="$1" try windows box points front
  guest_user_bash "$vm" '
set -euo pipefail
if ! verdict="$(spctl --assess --type execute -vv /Applications/Transcripted.app 2>&1)"; then
  printf "%s\n" "$verdict"
  echo "Gatekeeper REJECTS this app; a real user could not open it. Leaving the prompt alone." >&2
  exit 1
fi
printf "Gatekeeper: %s\n" "$verdict"' || return 1
  if app_started "$vm" 1; then
    echo "Transcripted is already running and no download prompt is showing"
    return 0
  fi
  if ! vnc_session_alive "$vm"; then
    log "no screen access (up --vnc); clearing the quarantine flag instead of clicking Open (no user does this)"
  else
    for try in 1 2 3; do
      if (( try > 1 )) && app_started "$vm" 1; then
        echo "download prompt approved over VNC (the app took a while to start)"
        return 0
      fi
      if ! windows="$(prompt_windows "$vm")" || [[ "$windows" != *"screen "* ]]; then
        log "warning: can't read the guest's window list, so not clicking blind"
        printf '%s\n' "$windows" | sed 's/^/[tvm]   /' >&2
        break
      fi
      echo "window list (try $try): $(tr '\n' ';' <<<"$windows")"
      points="$(sed -n 's/^screen //p' <<<"$windows")"
      box="$(sed -n 's/^prompt //p' <<<"$windows" | head -n 1)"
      front="$(sed -n 's/^front //p' <<<"$windows")"
      if [[ -z "$box" ]]; then
        if app_started "$vm" 15; then
          echo "Transcripted started with no download prompt on screen (Gatekeeper didn't ask)"
          return 0
        fi
        log "warning: no download prompt on screen and Transcripted isn't running (front: ${front:-?})"
        break
      fi
      if (( try < 3 )); then
        # The first click on a prompt that isn't in front may only bring it forward.
        if (cmd_vnc "$vm" click-default-button --within "${box// /,}" --points-wide "$points") && app_started "$vm" 15; then
          echo "download prompt approved: clicked Open over VNC, like a user (try $try)"
          return 0
        fi
      elif [[ "$front" == CoreServicesUIAgent ]]; then
        if (cmd_vnc "$vm" key return) && app_started "$vm" 15; then
          echo "download prompt approved: pressed Return (Open is the default button)"
          return 0
        fi
      else
        log "warning: the download prompt isn't in front (${front:-?} is), so not pressing Return"
      fi
    done
    log "warning: could not get past the download prompt over VNC; clearing the quarantine flag instead (no user does this)"
  fi
  # Also end the process macOS is holding behind the prompt, so what starts
  # next is a fresh, unquarantined launch.
  guest_user_bash "$vm" '
xattr -dr com.apple.quarantine /Applications/Transcripted.app
pkill -x Transcripted 2>/dev/null && sleep 2 || true
killall CoreServicesUIAgent 2>/dev/null || true
open -a /Applications/Transcripted.app'
  if app_started "$vm" 30 lenient; then
    echo "download prompt BYPASSED: quarantine flag cleared (fallback, not a user's path)"
    return "$BYPASS_EXIT"
  fi
  die "Transcripted did not start after the download prompt"
}

# What's on the guest's screen, from macOS's window list (no Accessibility
# grant needed for owners and bounds). Prints "screen <width in points>",
# "front <owner of the frontmost window>", and "prompt X Y W H" for each
# window of CoreServicesUIAgent, which draws the download prompt.
prompt_windows() {
  guest_user_bash "$1" 'osascript -l JavaScript -e "$1"' "$PROMPT_WINDOWS_JS" 2>&1
}
PROMPT_WINDOWS_JS='
ObjC.import("CoreGraphics");
function run() {
  var list = $.CGWindowListCopyWindowInfo(1 | 16, 0);
  var wins = list ? ObjC.deepUnwrap(ObjC.castRefToObject(list)) || [] : [];
  if (!wins.length) return "no windows";
  var wide = 0;
  try { wide = $.CGDisplayBounds($.CGMainDisplayID()).size.width; } catch (e) {}
  if (!(wide > 0)) wide = $.CGDisplayPixelsWide($.CGMainDisplayID());
  var skip = ["Window Server", "Dock", "SystemUIServer", "Control Center", "Spotlight", "Notification Center", "WindowManager", "TextInputMenuAgent"];
  var out = ["screen " + Math.round(wide)], front = "";
  wins.forEach(function (w) {
    var owner = w.kCGWindowOwnerName || "", layer = w.kCGWindowLayer, b = w.kCGWindowBounds || {};
    var ours = owner === "CoreServicesUIAgent";
    if (layer < 0 || (layer >= 24 && !ours) || skip.indexOf(owner) >= 0 || !(b.Width > 40 && b.Height > 40)) return;
    if (!front) front = owner;
    if (ours) out.push("prompt " + [b.X, b.Y, b.Width, b.Height].map(Math.round).join(" "));
  });
  out.push("front " + (front || "-"));
  return out.join("\n");
}'

# app_started VM SECONDS [lenient]: wait up to SECONDS for Transcripted to be
# really running: its process exists and no download prompt is on screen.
# A window list that can't be read counts as "not started", except in
# lenient mode (after the quarantine fallback, where no process is held).
app_started() {
  guest_user_bash "$1" '
for _ in $(seq 1 "$1"); do
  if pgrep -x Transcripted >/dev/null; then
    windows="$(osascript -l JavaScript -e "$2" 2>&1 || true)"
    case "$windows" in
      *"prompt "*) ;;
      *"screen "*) exit 0 ;;
      *) [ "$3" = lenient ] && exit 0 ;;
    esac
  fi
  sleep 1
done
exit 1' "$2" "$PROMPT_WINDOWS_JS" "${3:-strict}"
}

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
# Health checks

# Tart's VNC server listens on every interface; prove whether other machines
# can actually connect by dialing the port on each of this Mac's own network
# addresses (the same local address a neighbor would hit).
cmd_vnc_check() {
  local vm="$1" url port
  url="$(cat "$(vnc_file "$vm")" 2>/dev/null)" || die "no VNC port for $vm (boot it with: up --vnc)"
  port="${url##*:}"
  port="${port%%/*}"
  [[ "$port" =~ ^[0-9]+$ ]] || die "could not read the VNC port from the saved URL"
  python3 - "$port" <<'VNCCHECK'
import ipaddress, plistlib, socket, subprocess, sys

port = int(sys.argv[1])

def listing(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True).stdout
    except OSError:
        return None

out = listing(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fcn"])
if out is None:
    sys.exit("FAIL: lsof is missing, so the VNC listener cannot be checked")
listens = sorted({line[1:] for line in out.splitlines() if line.startswith("n")})
owners = sorted({line[1:] for line in out.splitlines() if line.startswith("c")})
if not listens:
    sys.exit(f"FAIL: nothing listens on VNC port {port}")
print(f"port {port} listens on: {', '.join(listens)} (process: {', '.join(owners) or '?'})")
loopback_only = all(addr.rsplit(":", 1)[0] in ("127.0.0.1", "[::1]", "localhost") for addr in listens)

# The private network Tart's VMs sit on (vmnet shared mode). Only the VMs can
# reach it, so an answer there is not exposure. Everything else counts,
# including other bridges (Thunderbolt Bridge, Internet Sharing).
vm_net = ipaddress.ip_network("192.168.64.0/24")
try:
    with open("/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist", "rb") as handle:
        prefs = plistlib.load(handle)
    vm_net = ipaddress.ip_network(f"{prefs['Shared_Net_Address']}/{prefs['Shared_Net_Mask']}", strict=False)
except (OSError, KeyError, ValueError, plistlib.InvalidFileException):
    pass

# (interface, address) for every address this Mac has, IPv4 and IPv6,
# leaving out loopback and IPv6 link-local.
addresses = []
iface = "?"
for line in (listing(["ifconfig"]) or listing(["ip", "-o", "addr", "show"]) or "").splitlines():
    parts = line.split()
    if not parts:
        continue
    if not line[0].isspace():
        iface = parts[1] if parts[0].rstrip(":").isdigit() else parts[0].rstrip(":")
    for family in ("inet", "inet6"):
        if family in parts[:-1]:
            raw = parts[parts.index(family) + 1].split("/")[0].split("%")[0]
            try:
                address = ipaddress.ip_address(raw)
            except ValueError:
                continue
            if address.is_loopback or address.is_link_local:
                continue
            if (iface, address) not in addresses:
                addresses.append((iface, address))

def vnc_answers(host):
    # A completed TCP handshake is not enough: a sandbox may refuse the
    # connection only after the kernel accepted it. Count it as reachable
    # only when a VNC server actually says hello ("RFB 003.008").
    try:
        with socket.create_connection((str(host), port), timeout=1.5) as conn:
            conn.settimeout(2)
            hello = b""
            while len(hello) < 4:
                chunk = conn.recv(12)
                if not chunk:
                    break
                hello += chunk
            return hello.startswith(b"RFB ")
    except OSError:
        return False

if not vnc_answers("127.0.0.1"):
    sys.exit("FAIL: the VNC server does not answer even from this Mac, so nothing else can be proven")
print("from this Mac (127.0.0.1): VNC answers")
exposed = []
tested = 0
for name, address in addresses:
    vm_network = address in vm_net
    hit = vnc_answers(address)
    where = "the VMs' private network" if vm_network else "the network"
    print(f"from {where} ({name} {address}): {'VNC ANSWERS' if hit else 'no answer'}")
    if not vm_network:
        tested += 1
        if hit:
            exposed.append(str(address))
if exposed:
    sys.exit("FAIL: other machines on the network can reach the VM's VNC port. Tart has no setting to "
             "limit it. It's password-protected; keep the VM down when idle and never use --vnc on shared Wi-Fi.")
if not loopback_only and not tested:
    sys.exit("FAIL: VNC listens on every interface and this Mac has no network address to test against")
print("ok: only this Mac can reach the VNC port" + ("" if loopback_only else " (it listens on every interface, but connections from the network get no VNC answer)"))
VNCCHECK
}

cmd_soak() {
  local vm="$1" seconds="${2:-300}" started=$SECONDS
  [[ "$seconds" =~ ^[0-9]+$ ]] || die "soak takes a number of seconds"
  vm_running "$vm" || die "$vm is not running"
  while (( SECONDS - started < seconds )); do
    sleep 10
    if ! vm_running "$vm"; then
      echo "$vm stopped after about $((SECONDS - started))s of watching ($(date -u +%H:%M:%SZ))"
      tail -n 5 "$(log_file "$vm")" 2>/dev/null || true
      return 1
    fi
  done
  echo "$vm still running after ${seconds}s"
}

# Everything that could explain a VM that stopped. Never fails.
cmd_diagnose() {
  local vm="$1" pid
  set +e
  echo "== $vm: $(vm_state "$vm" || true) ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  pid="$(cat "$(pid_file "$vm")" 2>/dev/null)"
  if [[ -n "$pid" ]]; then
    kill -0 "$pid" 2>/dev/null && echo "tart pid $pid is alive" || echo "tart pid $pid is gone"
  fi
  echo; echo "== VM log, this boot (last lines; a [tvm] line says how tart ended)"
  tail -n 30 "$(log_file "$vm")" 2>/dev/null || echo "(none)"
  echo; echo "== VNC session log"
  tail -n 10 "$(vnc_log_file "$vm")" 2>/dev/null || echo "(none)"
  echo; echo "== VM log, previous boot"
  tail -n 15 "$(dirname "$(log_file "$vm")")/$vm.prev.log" 2>/dev/null || echo "(none)"
  echo; echo "== host sleep/wake, most recent"
  pmset -g log 2>/dev/null | grep -E '^[0-9-]+ [0-9:]+ [+-][0-9]+[[:space:]]+(Sleep|Wake|DarkWake)[[:space:]]' | tail -n 10 || echo "(pmset log not readable)"
  echo; echo "== host disk"
  df -h "$TVM_HOME" 2>/dev/null
  echo; echo "== host crash reports for tart or Virtualization (last 2 days)"
  find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports -maxdepth 1 -mtime -2 \
    \( -iname '*tart*' -o -iname '*virtualization*' \) 2>/dev/null | tail -n 10
  echo; echo "== host log for tart and the VM process (last 30 min)"
  log show --last 30m --style compact \
    --predicate 'process == "tart" OR process BEGINSWITH "com.apple.Virtualization"' 2>&1 | tail -n 40
  echo; echo "== host firewall"
  /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>&1
  if vm_running "$vm"; then
    echo; echo "== guest"
    guest_user_bash "$vm" '
echo "uptime: $(uptime)"
echo "memory: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, $(memory_pressure 2>/dev/null | tail -n 1)"
log show --last boot --style compact --predicate "eventMessage CONTAINS \"shutdown cause\"" 2>/dev/null | tail -n 3
echo "crash/panic reports:"; ls -t /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | head -n 15' 2>&1
  fi
  set -e
  return 0
}

# ----------------------------------------------------------------------------
# First real run: one command that does setup plus a smoke run, collects the
# hardware facts the doc lists under "What the first real run showed", and writes a
# report. Each step runs as its own invocation so one failure still leaves a
# useful report. Host audio stays off throughout.

cmd_first_run() {
  local self="$SCRIPT_DIR/transcripted-vm.sh" stamp dir report failed=0 bypassed=0
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
    local out rc=0 result
    out="$("$@" 2>&1)" || rc=$?
    if [[ $rc == 0 ]]; then
      result=ok
    elif [[ "$required" == bypassable && $rc == "$BYPASS_EXIT" ]]; then
      # It worked, but not the way a user gets there; never report it as plain ok.
      result="ok via bypass (not a user's path)"
      bypassed=1
      rc=0
    else
      result="FAILED (exit $rc)"
    fi
    {
      echo
      echo "## $title: $result ($(date -u +%H:%M:%SZ))"
      echo
      echo '```'
      printf '%s\n' "$out" | tail -n 60
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
  if [[ "$(cat "$TVM_HOME/golden.prep" 2>/dev/null)" == "$GOLDEN_PREP_VERSION" ]]; then
    step "build clean snapshot (slow the first time)" required bash "$self" golden || return 1
  else
    step "build clean snapshot (slow the first time; rebuilt because the prep changed)" required bash "$self" golden --force || return 1
  fi
  step "boot a fresh clone with screen access (no host audio)" required bash "$self" --vm "$TVM_VM" reset --vnc || return 1
  step "status" optional bash "$self" --vm "$TVM_VM" status
  step "macOS setup screens after login (closed if they covered the desktop)" optional cat "$(setup_file "$TVM_VM")"
  step "guest user and transport" optional bash "$self" --vm "$TVM_VM" exec -- bash -c 'echo "user=$(id -un) uid=$(id -u) console=$(stat -f %Su /dev/console) macOS=$(sw_vers -productVersion)"; ls /Volumes/"My Shared Files" 2>&1; system_profiler SPAudioDataType 2>/dev/null | grep -E "^ {8}[^ ].*:$" || true'
  step "VNC reachable from the network? (Tart can't prevent it; this records who can reach it)" optional bash "$self" --vm "$TVM_VM" vnc-check
  step "Gatekeeper in the guest" optional bash "$self" --vm "$TVM_VM" exec -- bash -c 'spctl --status; cat /Users/Shared/transcripted-test-vm.json 2>/dev/null'
  step "VNC handshake" optional bash "$self" --vm "$TVM_VM" info
  step "screenshot: desktop" optional bash "$self" --vm "$TVM_VM" screenshot "$dir/01-desktop.png"
  step "install latest Transcripted (marked as downloaded)" required bash "$self" --vm "$TVM_VM" install-app --latest || return 1
  # A downloaded app opens behind macOS's "downloaded from the Internet"
  # prompt and does not start until it is approved, so photograph the prompt
  # first, approve it, and only then wait for the app.
  step "launch" optional bash "$self" --vm "$TVM_VM" launch
  step "wait for the download prompt, then read the window list" optional bash -c 'sleep 10; bash "$1" --vm "$2" windows' _ "$self" "$TVM_VM"
  step "screenshot: download prompt" optional bash "$self" --vm "$TVM_VM" screenshot "$dir/02-download-prompt.png"
  step "Gatekeeper check, then approve the download prompt" bypassable bash "$self" --vm "$TVM_VM" approve-download
  step "launch again" optional bash "$self" --vm "$TVM_VM" launch
  step "app_launched event" optional bash "$self" --vm "$TVM_VM" wait-event app_launched --timeout 180
  step "screenshot: first screen" optional bash "$self" --vm "$TVM_VM" screenshot "$dir/03-first-screen.png"
  step "app logs" optional bash "$self" --vm "$TVM_VM" logs 20
  # Could screenshots come from inside the guest instead of VNC? Records
  # whether screencapture works there without a Screen Recording grant.
  step "guest screencapture (test)" optional bash -c '
    bash "$1" --vm "$2" exec -- bash -c "screencapture -x /tmp/tvm-sc.png && ls -l /tmp/tvm-sc.png && cp /tmp/tvm-sc.png \"$3/guest-screencapture.png\"" &&
    cp "$4/guest-screencapture.png" "$5/06-guest-screencapture.png"' _ "$self" "$TVM_VM" "$GUEST_SHARE" "$(share_dir "$TVM_VM")" "$dir"
  # Last time the VM died a few minutes after launch; watch it for a while.
  step "VM stays up for 5 minutes" optional bash "$self" --vm "$TVM_VM" soak 300
  step "screenshot: after 5 minutes" optional bash "$self" --vm "$TVM_VM" screenshot "$dir/04-after-5-min.png"
  step "diagnose (how the VM is doing, or why it stopped)" optional bash "$self" --vm "$TVM_VM" diagnose
  step "shut down" optional bash "$self" --vm "$TVM_VM" down

  {
    echo
    if (( failed )); then
      echo "## Result: some optional steps failed$( (( bypassed )) && echo ", and the download prompt was BYPASSED, not approved like a user")"
    elif (( bypassed )); then
      echo "## Result: steps ok, but the download prompt was BYPASSED, not approved like a user"
    else
      echo "## Result: all steps ok"
    fi
    echo
    echo "Screenshots: $dir"
    echo "02-download-prompt.png should show macOS's \"downloaded from the Internet\" prompt; 03-first-screen.png should show Transcripted's first screen; 06-guest-screencapture.png exists only if in-guest screenshots work."
  } >>"$report"
  log "first-run finished; report: $report"
  echo "$report"
}

# ----------------------------------------------------------------------------
# Screen

cmd_vnc() {
  local vm="$1"; shift
  local sock
  sock="$(vnc_sock_file "$vm")"
  if ! vnc_session_alive "$vm"; then
    [[ -s "$(vnc_file "$vm")" ]] || die "no screen access for $vm (boot it with: up --vnc)"
    tail -n 3 "$(vnc_log_file "$vm")" 2>/dev/null | sed 's/^/[tvm]   /' >&2 || true
    die "the VNC session for $vm has ended (it never reconnects: that crashed tart). Run: diagnose"
  fi
  # Never connect directly: only the one session talks to Apple's VNC server.
  env -u TVM_VNC_URL TVM_VNC_SOCKET="$sock" python3 "$VNC_PY" "$@"
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
    vnc-check) cmd_vnc_check "$vm" ;;
    soak) need_tart; cmd_soak "$vm" "$@" ;;
    diagnose) need_tart; cmd_diagnose "$vm" ;;
    save) cmd_save "$vm" "$@" ;;
    restore) cmd_restore "$vm" "$@" ;;
    first-run) cmd_first_run ;;
    exec|sh|install-app|launch|quit|approve-download|windows|logs|cli|play|say|wait-event)
      need_tart
      protect_snapshot "$vm"
      vm_running "$vm" || die "$vm is not running. Run: up"
      case "$command" in
        exec) cmd_exec "$vm" "$@" ;;
        sh) cmd_sh "$vm" ;;
        install-app) cmd_install_app "$vm" "$@" ;;
        launch) cmd_launch "$vm" ;;
        quit) cmd_quit "$vm" ;;
        approve-download) cmd_approve_download "$vm" ;;
        windows) prompt_windows "$vm" ;;
        logs) cmd_logs "$vm" "$@" ;;
        cli) cmd_cli "$vm" "$@" ;;
        play) cmd_play "$vm" "$@" ;;
        say) cmd_say "$vm" "$@" ;;
        wait-event) cmd_wait_event "$vm" "$@" ;;
      esac
      ;;
    share) cmd_share "$vm" ;;
    screenshot|click|click-default-button|move|drag|scroll|type|key|info) cmd_vnc "$vm" "$command" "$@" ;;
    *) usage >&2; die "unknown command: $command" ;;
  esac
}

main "$@"
