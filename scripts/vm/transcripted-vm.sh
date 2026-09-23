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
TVM_IMAGE="${TVM_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-vanilla:latest}"
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

log() { printf '[tvm] %s\n' "$*" >&2; }
die() { printf '[tvm] error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
transcripted-vm.sh: clean macOS VM for Transcripted new-user tests (Tart).

One-time setup (host):
  doctor                    check this Mac can run the VM
  install-tart              install Tart (Homebrew if present, else GitHub release)
  golden [--force]          download macOS 26 image and build the clean snapshot

Each test run:
  new                       fresh clone of the clean snapshot (deletes old clone)
  up [--window]             boot the clone (VNC by default; --window = normal window)
  reset                     down + delete + new + up in one go
  down                      shut the clone down
  rm                        delete the clone
  status                    VMs, IP, VNC URL, transport
  save <snapshot>           keep the stopped clone as a named snapshot
  restore <snapshot>        replace the clone with a copy of a snapshot

Inside the guest:
  exec -- <cmd...>          run a command in the guest (as the GUI user)
  sh                        interactive shell in the guest (ssh)
  install-app [--version V | --latest | --dmg PATH] [--no-quarantine]
                            install Transcripted like a user would (DMG -> /Applications)
  launch | quit             open or quit Transcripted
  logs [N]                  last N lines of the app's events.jsonl + app.jsonl
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

Global: --vm NAME (default $TVM_VM or transcripted-test). Env knobs at the top of
this file: TVM_CPU, TVM_MEMORY_MB, TVM_DISPLAY, TVM_IMAGE, TVM_HOME ...
EOF
}

# ----------------------------------------------------------------------------
# Tart binary

TART=""
find_tart() {
  if [[ -n "$TART" ]]; then return 0; fi
  if command -v tart >/dev/null 2>&1; then
    TART="$(command -v tart)"
  elif [[ -x "$TVM_HOME/tart.app/Contents/MacOS/tart" ]]; then
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

cmd_doctor() {
  local ok=1
  [[ "$(uname -s)" == "Darwin" ]] || { log "not macOS: Tart needs a Mac host"; ok=0; }
  [[ "$(uname -m)" == "arm64" ]] || { log "not Apple Silicon: macOS guests need an M-series Mac"; ok=0; }
  if command -v sw_vers >/dev/null 2>&1; then
    log "host macOS $(sw_vers -productVersion)"
  fi
  command -v python3 >/dev/null 2>&1 || { log "python3 missing (install Xcode Command Line Tools)"; ok=0; }
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local free_gb
    free_gb="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
    log "free disk: ${free_gb} GB (need about ${TVM_MIN_FREE_GB} GB for the image + clones)"
    (( free_gb >= TVM_MIN_FREE_GB )) || { log "not enough free disk"; ok=0; }
  fi
  if find_tart; then
    log "tart: $TART ($("$TART" --version 2>/dev/null || echo unknown version))"
    "$TART" list 2>/dev/null | sed 's/^/[tvm]   /' >&2 || true
  else
    log "tart: not installed (run install-tart)"
  fi
  python3 "$VNC_PY" --self-test >/dev/null && log "vnc driver: ok" || { log "vnc driver self-test failed"; ok=0; }
  (( ok )) && log "doctor: ok" || die "doctor found problems above"
}

cmd_install_tart() {
  if find_tart; then log "tart already installed: $TART"; return 0; fi
  if command -v brew >/dev/null 2>&1; then
    log "installing Tart with Homebrew"
    brew install cirruslabs/cli/tart
  else
    log "no Homebrew; installing Tart from its GitHub release into $TVM_HOME"
    mkdir -p "$TVM_HOME"
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/tart.tar.gz" https://github.com/cirruslabs/tart/releases/latest/download/tart.tar.gz
    tar -xzf "$tmp/tart.tar.gz" -C "$tmp"
    rm -rf "$TVM_HOME/tart.app"
    mv "$tmp/tart.app" "$TVM_HOME/tart.app"
    rm -rf "$tmp"
  fi
  find_tart || die "Tart install finished but the binary was not found"
  log "tart installed: $TART ($("$TART" --version 2>/dev/null || true))"
}

# ----------------------------------------------------------------------------
# Guest transport: `tart exec` (guest agent over vsock, no network needed) when
# it works, else SSH with the image's default password.

transport_file() { echo "$TVM_HOME/$1.transport"; }

askpass_script() {
  local path="$TVM_HOME/askpass.sh"
  if [[ ! -x "$path" ]]; then
    mkdir -p "$TVM_HOME"
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

ssh_guest() {
  local vm="$1"; shift
  local ip
  ip="$(guest_ip "$vm" 10)" || die "no IP for $vm (is it running?)"
  SSH_ASKPASS="$(askpass_script)" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" TVM_GUEST_PASS="$TVM_GUEST_PASS" \
    ssh "${ssh_opts[@]}" "$@" "$TVM_GUEST_USER@$ip"
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
  local vm="$1" file
  file="$(transport_file "$vm")"
  if [[ -s "$file" ]]; then cat "$file"; return 0; fi
  local found
  found="$(detect_transport "$vm")" || die "cannot reach $vm (tried tart exec and ssh)"
  echo "$found" >"$file"
  echo "$found"
}

# Run argv in the guest. No stdin.
guest_run() {
  local vm="$1"; shift
  case "$(transport "$vm")" in
    exec) "$TART" exec "$vm" "$@" </dev/null ;;
    ssh)
      local quoted="" arg
      for arg in "$@"; do quoted+="$(printf '%q' "$arg") "; done
      ssh_guest "$vm" "$quoted" </dev/null
      ;;
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

share_dir() { echo "$TVM_HOME/share/$1"; }
log_file() { echo "$TVM_HOME/$1.log"; }
vnc_file() { echo "$TVM_HOME/$1.vnc"; }

wait_for_guest() {
  local vm="$1" deadline=$((SECONDS + TVM_BOOT_TIMEOUT))
  log "waiting for $vm to boot (up to ${TVM_BOOT_TIMEOUT}s)"
  rm -f "$(transport_file "$vm")"
  until guest_ip "$vm" 5 >/dev/null; do
    (( SECONDS < deadline )) || die "$vm never got an IP; see $(log_file "$vm")"
    sleep 3
  done
  until detect_transport "$vm" >"$(transport_file "$vm").tmp" 2>/dev/null; do
    (( SECONDS < deadline )) || die "$vm booted but neither tart exec nor ssh answers"
    sleep 3
  done
  mv "$(transport_file "$vm").tmp" "$(transport_file "$vm")"
  # The vanilla image auto-logs-in the admin user; wait for that GUI session.
  until [[ "$(guest_run "$vm" stat -f %Su /dev/console 2>/dev/null)" == "$TVM_GUEST_USER" ]]; do
    (( SECONDS < deadline )) || die "$vm is up but $TVM_GUEST_USER never logged in to the desktop"
    sleep 3
  done
  log "$vm is up via $(cat "$(transport_file "$vm")") at $(guest_ip "$vm")"
}

cmd_up() {
  local vm="$1" window=0
  shift
  [[ "${1:-}" == "--window" ]] && window=1
  need_tart
  vm_exists "$vm" || die "no VM named $vm. Run: new"
  if vm_running "$vm"; then log "$vm is already running"; return 0; fi
  mkdir -p "$(share_dir "$vm")"
  local args=(run "$vm" --dir "tvm:$(share_dir "$vm")")
  if (( window )); then
    rm -f "$(vnc_file "$vm")"
  else
    args+=(--vnc-experimental)
  fi
  log "booting $vm"
  nohup "$TART" "${args[@]}" >"$(log_file "$vm")" 2>&1 </dev/null &
  echo $! >"$TVM_HOME/$vm.pid"
  disown || true
  if (( ! window )); then
    local deadline=$((SECONDS + 60)) url=""
    until [[ -n "$url" ]]; do
      url="$(grep -Eo 'vnc://[^[:space:]"]+' "$(log_file "$vm")" 2>/dev/null | tail -1 | sed 's/[.,]*$//' || true)"
      [[ -n "$url" ]] && break
      (( SECONDS < deadline )) || die "Tart never printed a VNC URL; see $(log_file "$vm")"
      sleep 1
    done
    echo "$url" >"$(vnc_file "$vm")"
    chmod 600 "$(vnc_file "$vm")"
  fi
  wait_for_guest "$vm"
}

cmd_down() {
  local vm="$1"
  need_tart
  if ! vm_running "$vm"; then log "$vm is not running"; return 0; fi
  log "shutting down $vm"
  "$TART" stop "$vm" --timeout 60 >/dev/null 2>&1 || "$TART" stop "$vm" >/dev/null 2>&1 || true
  rm -f "$(vnc_file "$vm")" "$(transport_file "$vm")" "$TVM_HOME/$vm.pid"
}

cmd_rm() {
  local vm="$1"
  need_tart
  [[ "$vm" != "$TVM_GOLDEN" && "$vm" != "$TVM_BASE" ]] || die "refusing to delete the clean snapshot ($vm); use golden --force"
  cmd_down "$vm"
  if vm_exists "$vm"; then "$TART" delete "$vm"; log "deleted $vm"; fi
  rm -rf "$(share_dir "$vm")"
}

cmd_new() {
  local vm="$1"
  need_tart
  vm_exists "$TVM_GOLDEN" || die "no clean snapshot yet. Run: golden"
  [[ "$vm" != "$TVM_GOLDEN" ]] || die "pick a test VM name, not the snapshot name"
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
  need_tart
  ! vm_running "$vm" || die "shut $vm down first (down), then save"
  if vm_exists "$snap"; then "$TART" delete "$snap"; fi
  "$TART" clone "$vm" "$snap"
  log "saved $vm as snapshot $snap"
}

cmd_restore() {
  local vm="$1" snap="${2:-}"
  [[ -n "$snap" ]] || die "usage: restore <snapshot-name>"
  need_tart
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
    echo "vnc:       $(cat "$(vnc_file "$vm")" 2>/dev/null || echo none)"
    echo "share:     $(share_dir "$vm") (guest: $GUEST_SHARE)"
  else
    echo "vm:        $vm (not running)"
  fi
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
    log "downloading $TVM_IMAGE (tens of GB; this is the slow part)"
    "$TART" clone "$TVM_IMAGE" "$TVM_BASE"
  fi
  if vm_exists "$TVM_GOLDEN"; then
    vm_running "$TVM_GOLDEN" && "$TART" stop "$TVM_GOLDEN" >/dev/null 2>&1 || true
    "$TART" delete "$TVM_GOLDEN"
  fi
  "$TART" clone "$TVM_BASE" "$TVM_GOLDEN"
  "$TART" set "$TVM_GOLDEN" --cpu "$TVM_CPU" --memory "$TVM_MEMORY_MB" --display "$TVM_DISPLAY"
  cmd_up "$TVM_GOLDEN"
  guest_user_bash "$TVM_GOLDEN" "TVM_PASS=$(printf '%q' "$TVM_GUEST_PASS") TVM_MARKER=$(printf '%q' "$GUEST_MARKER") TVM_IMAGE=$(printf '%q' "$TVM_IMAGE"); $GUEST_PREP"
  log "shutting the clean snapshot down; it is never booted again"
  guest_run "$TVM_GOLDEN" bash -c "if sudo -n true 2>/dev/null; then sudo shutdown -h now; else printf '%s\n' $(printf '%q' "$TVM_GUEST_PASS") | sudo -S -p '' shutdown -h now; fi" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 120))
  while vm_running "$TVM_GOLDEN" && (( SECONDS < deadline )); do sleep 3; done
  cmd_down "$TVM_GOLDEN"
  rm -rf "$(share_dir "$TVM_GOLDEN")"
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
  local version="" dmg="" quarantine=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="${2:?}"; shift 2 ;;
      --latest) version="$(latest_version)"; shift ;;
      --dmg) dmg="${2:?}"; shift 2 ;;
      --no-quarantine) quarantine=0; shift ;;
      *) die "install-app: unknown option $1" ;;
    esac
  done
  [[ -n "$version" || -n "$dmg" ]] || die "install-app needs --version V, --latest or --dmg PATH"
  local source
  if [[ -n "$dmg" ]]; then
    [[ -f "$dmg" ]] || die "no such DMG: $dmg"
    mkdir -p "$(share_dir "$vm")"
    cp "$dmg" "$(share_dir "$vm")/install.dmg"
    source="share"
    log "installing $(basename "$dmg") from the host"
  else
    source="$TVM_RELEASES_URL/download/v$version/Transcripted-$version.dmg"
    log "installing Transcripted $version from GitHub releases"
  fi
  guest_user_bash "$vm" '
set -euo pipefail
source="$1" share="$2" quarantine="$3"
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
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Transcripted.app/Contents/Info.plist | sed "s/^/installed Transcripted /"
' "$source" "$GUEST_SHARE" "$quarantine"
}

cmd_launch() { guest_user_bash "$1" 'open -a /Applications/Transcripted.app && echo launched'; }
cmd_quit() { guest_user_bash "$1" 'pkill -x Transcripted && echo quit || echo "not running"'; }

cmd_logs() {
  local vm="$1" lines="${2:-40}"
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

cmd_sh() {
  local vm="$1"
  ssh_guest "$vm" -t
}

cmd_play() { guest_user_bash "$1" 'afplay "$1"' "${2:?usage: play <file-in-guest>}"; }
cmd_say() { guest_user_bash "$1" 'say "$1"' "${2:?usage: say <text>}"; }

cmd_share() { mkdir -p "$(share_dir "$1")"; echo "host:  $(share_dir "$1")"; echo "guest: $GUEST_SHARE"; }

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
  mkdir -p "$TVM_HOME"
  local vm="$TVM_VM"
  if [[ "${1:-}" == "--vm" ]]; then vm="${2:?--vm needs a name}"; shift 2; fi
  local command="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "$command" in
    help|-h|--help) usage ;;
    doctor) cmd_doctor ;;
    install-tart) cmd_install_tart ;;
    golden) cmd_golden "$@" ;;
    new) cmd_new "$vm" ;;
    up) cmd_up "$vm" "$@" ;;
    down) cmd_down "$vm" ;;
    rm) cmd_rm "$vm" ;;
    reset) need_tart; cmd_reset "$vm" "$@" ;;
    status) cmd_status "$vm" ;;
    save) cmd_save "$vm" "$@" ;;
    restore) cmd_restore "$vm" "$@" ;;
    exec|sh|install-app|launch|quit|logs|cli|play|say)
      need_tart
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
      esac
      ;;
    share) cmd_share "$vm" ;;
    screenshot|click|move|drag|scroll|type|key|info) cmd_vnc "$vm" "$command" "$@" ;;
    *) usage >&2; die "unknown command: $command" ;;
  esac
}

main "$@"
