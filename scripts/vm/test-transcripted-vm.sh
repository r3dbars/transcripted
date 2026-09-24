#!/usr/bin/env bash
# Guard tests for scripts/vm/transcripted-vm.sh: every path that can delete
# host files must refuse hostile VM names and TVM_HOME values, and must never
# touch data outside its own marked ~/.transcripted-vm folder.
#
# Runs anywhere with bash + python3 (macOS or Linux CI). No Tart, no VM:
# a fake `tart` stands in, and everything happens under a temp HOME.
#
# Usage: bash scripts/vm/test-transcripted-vm.sh

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/transcripted-vm.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

export HOME="$ROOT/home"
export TVM_HOME="$HOME/.transcripted-vm"
unset TVM_VM TVM_BASE TVM_GOLDEN
FAKE_VMS="$ROOT/vms"
export FAKE_VMS
mkdir -p "$HOME" "$FAKE_VMS"
# Every hostile path below points inside $ROOT (never at / or the real HOME),
# so even a regressed script can only damage this temp folder.
cd "$ROOT"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# Files that must survive every case.
CANARIES=(
  "$HOME/transcripted/keep"
  "$HOME/Library/Application Support/Transcripted/keep"
  "$ROOT/notours/.transcripted-vm/keep"
  "$ROOT/drive/keep"
)
for canary in "${CANARIES[@]}"; do mkdir -p "$(dirname "$canary")"; echo keep >"$canary"; done

canaries_intact() {
  local canary
  for canary in "${CANARIES[@]}"; do [[ -f "$canary" ]] || return 1; done
}

run() { bash "$SCRIPT" "$@" >"$ROOT/out" 2>&1; }

expect_refused() {
  local desc="$1"; shift
  if "$@" >"$ROOT/out" 2>&1; then
    bad "$desc (command succeeded)"; sed 's/^/     /' "$ROOT/out"
  elif ! canaries_intact; then
    bad "$desc (a canary file was deleted)"
  else
    ok "$desc"
  fi
}

# --- set up a real, marked TVM_HOME with a fake tart -------------------------

run help || true
[[ ! -e "$TVM_HOME" ]] && ok "help creates nothing" || bad "help created $TVM_HOME"

run status || true  # creates and marks TVM_HOME, then stops: no tart yet
[[ -f "$TVM_HOME/.transcripted-vm-home" ]] && ok "TVM_HOME gets its marker" || bad "no marker in $TVM_HOME"

mkdir -p "$TVM_HOME/tart.app/Contents/MacOS"
cat >"$TVM_HOME/tart.app/Contents/MacOS/tart" <<'EOF'
#!/usr/bin/env bash
cmd="$1"; shift || true
case "$cmd" in
  list) python3 - "$FAKE_VMS" <<'PY'
import json, os, sys
root = sys.argv[1]
print(json.dumps([{"Name": n, "Source": "local", "State": "stopped", "Running": False} for n in sorted(os.listdir(root))]))
PY
  ;;
  clone) mkdir -p "$FAKE_VMS/$2" ;;
  delete) rm -rf "${FAKE_VMS:?}/$1" ;;
  --version) echo fake ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TVM_HOME/tart.app/Contents/MacOS/tart"
mkdir -p "$FAKE_VMS/transcripted-base" "$FAKE_VMS/transcripted-clean" "$FAKE_VMS/keeper"

# --- hostile VM names ----------------------------------------------------------

expect_refused "--vm ../../transcripted rm" bash "$SCRIPT" --vm ../../transcripted rm
expect_refused "--vm to real app data rm" bash "$SCRIPT" --vm "../../Library/Application Support/Transcripted" rm
expect_refused "TVM_VM with a slash" env TVM_VM=a/b bash "$SCRIPT" rm
expect_refused "--vm starting with a dash" bash "$SCRIPT" --vm -rf rm
expect_refused "--vm .." bash "$SCRIPT" --vm .. rm
expect_refused "--vm with spaces" bash "$SCRIPT" --vm "a b" rm
expect_refused "empty --vm" bash "$SCRIPT" --vm "" rm
expect_refused "TVM_GOLDEN with ../" env TVM_GOLDEN=../x bash "$SCRIPT" status
expect_refused "save to a bad snapshot name" bash "$SCRIPT" save ../../transcripted
expect_refused "restore from a bad snapshot name" bash "$SCRIPT" restore ../../transcripted

# --- the clean snapshot is untouchable -----------------------------------------

expect_refused "rm the clean snapshot" bash "$SCRIPT" --vm transcripted-clean rm
expect_refused "rm the base image" bash "$SCRIPT" --vm transcripted-base rm
expect_refused "boot the clean snapshot" bash "$SCRIPT" --vm transcripted-clean up
expect_refused "exec in the clean snapshot" bash "$SCRIPT" --vm transcripted-clean exec -- true
expect_refused "save over the clean snapshot" bash "$SCRIPT" --vm keeper save transcripted-clean
expect_refused "save over the base image" bash "$SCRIPT" --vm keeper save transcripted-base
expect_refused "save a VM onto itself" bash "$SCRIPT" --vm keeper save keeper
expect_refused "restore over the clean snapshot" bash "$SCRIPT" --vm transcripted-clean restore keeper
[[ -d "$FAKE_VMS/transcripted-clean" && -d "$FAKE_VMS/transcripted-base" && -d "$FAKE_VMS/keeper" ]] \
  && ok "no VM was deleted by a refused command" || bad "a VM disappeared"

# --- a valid rm only removes its own share folder ------------------------------

mkdir -p "$TVM_HOME/share/scratch-vm" "$TVM_HOME/share/other-vm"
echo x >"$TVM_HOME/share/other-vm/file"
if run --vm scratch-vm rm && [[ ! -e "$TVM_HOME/share/scratch-vm" && -f "$TVM_HOME/share/other-vm/file" ]] && canaries_intact; then
  ok "rm removes only share/<vm>"
else
  bad "rm of a valid VM removed the wrong things"; sed 's/^/     /' "$ROOT/out"
fi

# --- hostile TVM_HOME values never reach purge ---------------------------------

ln -s "$ROOT/notours" "$ROOT/linkparent"
mkdir -p "$ROOT/symhome"
ln -s "$ROOT/notours/.transcripted-vm" "$ROOT/symhome/.transcripted-vm"
touch "$ROOT/notours/.transcripted-vm/.transcripted-vm-home.decoy"

expect_refused "purge with TVM_HOME=\$HOME" env TVM_HOME="$HOME" bash "$SCRIPT" purge --yes
expect_refused "purge with TVM_HOME=\$HOME//" env TVM_HOME="$HOME//" bash "$SCRIPT" purge --yes
expect_refused "purge with TVM_HOME=the checkout" env TVM_HOME="$HOME/transcripted" bash "$SCRIPT" purge --yes
expect_refused "purge with TVM_HOME=a whole drive" env TVM_HOME="$ROOT/drive" bash "$SCRIPT" purge --yes
expect_refused "purge with TVM_HOME=relative" env TVM_HOME=.transcripted-vm bash "$SCRIPT" purge --yes
expect_refused "purge with a .. in TVM_HOME" env TVM_HOME="$HOME/x/../.transcripted-vm" bash "$SCRIPT" purge --yes
expect_refused "purge of a folder we did not create" env TVM_HOME="$ROOT/notours/.transcripted-vm" bash "$SCRIPT" purge --yes
expect_refused "purge through a symlinked .transcripted-vm" env TVM_HOME="$ROOT/symhome/.transcripted-vm" bash "$SCRIPT" purge --yes
expect_refused "purge through a symlinked parent" env TVM_HOME="$ROOT/linkparent/.transcripted-vm" bash "$SCRIPT" purge --yes
expect_refused "purge without --yes" bash "$SCRIPT" purge
[[ -d "$TVM_HOME" ]] && ok "real TVM_HOME still there after refused purges" || bad "TVM_HOME vanished"

# --- up: tart runs under the helper, and its end is logged ---------------------
# A fake `tart run` prints a VNC URL and waits; `list` says "running" while it
# lives. FAKE_RUN_MODE=die makes it exit at once, like a VM killed at boot.

cat >"$TVM_HOME/tart.app/Contents/MacOS/tart" <<'EOF2'
#!/usr/bin/env bash
cmd="$1"; shift || true
alive() { [[ -f "$FAKE_VMS/.running" ]] && kill -0 "$(cat "$FAKE_VMS/.running")" 2>/dev/null; }
case "$cmd" in
  run)
    if [[ "$*" == *--help* ]]; then echo "--no-clipboard --no-audio --vnc-experimental --no-graphics --dir"; exit 0; fi
    [[ "${FAKE_RUN_MODE:-}" == die ]] && exit 3
    echo "VNC server is running at vnc://:pw@127.0.0.1:5999"
    echo $$ >"$FAKE_VMS/.running"
    trap 'echo "Stopping VM..."; rm -f "$FAKE_VMS/.running"; exit 0' INT
    while :; do sleep 1; done ;;
  list) python3 - "$FAKE_VMS" "$(alive && echo 1)" <<'PY'
import json, os, sys
root, alive = sys.argv[1], sys.argv[2] == "1"
print(json.dumps([{"Name": n, "Source": "local", "State": "running" if alive and n == "upvm" else "stopped"}
                  for n in sorted(os.listdir(root)) if not n.startswith(".")]))
PY
  ;;
  ip) alive && echo 192.168.64.5 ;;
  exec) [[ "${1:-}" == --help ]] && exit 0; shift; if [[ "$*" == *console* ]]; then echo admin; else "$@"; fi ;;
  stop) kill -INT "$(cat "$FAKE_VMS/.running")"; sleep 1 ;;
  clone) mkdir -p "$FAKE_VMS/$2" ;;
  delete) rm -rf "${FAKE_VMS:?}/$1" ;;
  --version) echo fake ;;
esac
EOF2
mkdir -p "$FAKE_VMS/upvm"
UPLOG="$TVM_HOME/logs/upvm.log"

if FAKE_RUN_MODE=die run --vm upvm up; then
  bad "up succeeded although tart died at boot"
elif grep -q "stopped while booting" "$ROOT/out" && grep -q "exited with status 3" "$UPLOG"; then
  ok "up stops at once when tart dies, and the log says how"
else
  bad "a tart that died at boot was not reported"; sed 's/^/     /' "$ROOT/out" "$UPLOG"
fi

if run --vm upvm up && [[ -s "$TVM_HOME/run/upvm.pid" ]] && grep -q "tart started" "$UPLOG" \
   && [[ -f "$TVM_HOME/logs/upvm.prev.log" ]] && ! grep -q -- "sandbox-exec" "$UPLOG"; then
  ok "up starts tart through the helper and keeps the previous log"
else
  bad "up did not start tart through the helper"; sed 's/^/     /' "$ROOT/out"
fi
if [[ "$(ps -o pgid= -p "$(cat "$TVM_HOME/run/upvm.pid")" | tr -d ' ')" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]]; then
  ok "the VM runs outside the caller's process group"
else
  bad "the VM shares the caller's process group"
fi
expect_refused "up --lockdown on a VM already running without it" bash "$SCRIPT" --vm upvm up --lockdown
grep -q "WITHOUT --lockdown" "$ROOT/out" && ok "lockdown refusal says why" || bad "lockdown refusal message missing"
if run --vm upvm down && sleep 1 && grep -q "exited normally" "$UPLOG" && [[ ! -e "$TVM_HOME/run/upvm.pid" ]]; then
  ok "down stops tart and the log records a normal exit"
else
  bad "down misbehaved"; sed 's/^/     /' "$ROOT/out" "$UPLOG"
fi

# --- a real purge removes only TVM_HOME ----------------------------------------

if run purge --yes && [[ ! -e "$TVM_HOME" ]] && canaries_intact; then
  ok "purge --yes removes TVM_HOME and nothing else"
else
  bad "purge --yes misbehaved"; sed 's/^/     /' "$ROOT/out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
