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

# The helper that runs tart detached checks itself first (CI runs this file,
# so this is also where the helper's self-test runs in CI).
if python3 "$(dirname "$SCRIPT")/supervise.py" --self-test >"$ROOT/out" 2>&1; then
  ok "supervise.py self-test"
else
  bad "supervise.py self-test"; sed 's/^/     /' "$ROOT/out"
fi

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
# A fake `tart run` logs its argv, prints a VNC URL (port $FAKE_VNC_PORT) when
# asked for VNC, and waits; `list` says "running" while it lives.
# FAKE_RUN_MODE=die makes it exit at once, like a VM killed at boot.

cat >"$TVM_HOME/tart.app/Contents/MacOS/tart" <<'EOF2'
#!/usr/bin/env bash
cmd="$1"; shift || true
alive() { [[ -f "$FAKE_VMS/.running" ]] && kill -0 "$(cat "$FAKE_VMS/.running")" 2>/dev/null; }
case "$cmd" in
  run)
    if [[ "$*" == *--help* ]]; then echo "--no-clipboard --no-audio --vnc-experimental --no-graphics --dir"; exit 0; fi
    [[ "${FAKE_RUN_MODE:-}" == die ]] && exit 3
    echo "argv: $*"
    [[ "$*" == *--vnc-experimental* ]] && echo "VNC server is running at vnc://:pw@127.0.0.1:${FAKE_VNC_PORT:-9}"
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
  exec) [[ "${1:-}" == --help ]] && exit 0; shift
    if [[ "$*" == *console* ]]; then echo admin
    elif [[ "$*" == *desktop-ready* ]]; then echo "${FAKE_SETUP_OUT:-desktop-ready (closed Setup Assistant 0 times)}"
    else "$@"; fi ;;
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
   && [[ -f "$TVM_HOME/logs/upvm.prev.log" ]]; then
  ok "up starts tart through the helper and keeps the previous log"
else
  bad "up did not start tart through the helper"; sed 's/^/     /' "$ROOT/out"
fi
if grep -q -- "--no-graphics" "$UPLOG" && ! grep -q -- "--vnc" "$UPLOG" && [[ ! -e "$TVM_HOME/run/upvm.vnc" ]]; then
  ok "plain up boots headless with no VNC port"
else
  bad "plain up turned on VNC"; sed 's/^/     /' "$UPLOG"
fi
expect_refused "screenshot without screen access" bash "$SCRIPT" --vm upvm screenshot "$ROOT/x.png"
grep -q "up --vnc" "$ROOT/out" && ok "the refusal says to use up --vnc" || bad "no hint to use up --vnc"
if [[ "$(ps -o pgid= -p "$(cat "$TVM_HOME/run/upvm.pid")" | tr -d ' ')" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]]; then
  ok "the VM runs outside the caller's process group"
else
  bad "the VM shares the caller's process group"
fi
expect_refused "up --vnc on a VM already running without it" bash "$SCRIPT" --vm upvm up --vnc
grep -q "without a VNC session" "$ROOT/out" && ok "the --vnc refusal says why" || bad "--vnc refusal message missing"
if run --vm upvm down && sleep 1 && grep -q "exited normally" "$UPLOG" && [[ ! -e "$TVM_HOME/run/upvm.pid" ]]; then
  ok "down stops tart and the log records a normal exit"
else
  bad "down misbehaved"; sed 's/^/     /' "$ROOT/out" "$UPLOG"
fi

# --- Setup Assistant covering the desktop is closed and recorded -----------------
if FAKE_SETUP_OUT=$'setup-assistant running: admin Setup Assistant -MiniBuddyYes\nclosed it\ndesktop-ready (closed Setup Assistant 1 times)' \
     run --vm upvm up && grep -q "Setup Assistant was covering the desktop" "$ROOT/out" \
   && grep -q "MiniBuddyYes" "$TVM_HOME/run/upvm.setup"; then
  ok "up closes Setup Assistant and records what it showed"
else
  bad "Setup Assistant at login was not handled"; sed 's/^/     /' "$ROOT/out"
fi
run --vm upvm down || true
if FAKE_SETUP_OUT="desktop-not-ready: no Dock after 90s" run --vm upvm up && grep -q "desktop never came up clear" "$ROOT/out"; then
  ok "up warns when the desktop never comes up"
else
  bad "no warning when the desktop never came up"; sed 's/^/     /' "$ROOT/out"
fi
run --vm upvm down || true

# --- up --vnc: ONE VNC connection for the whole boot ---------------------------
# Reconnecting to Apple's VNC server crashed tart on a real Mac, so every
# screen command must reuse the session `up --vnc` opened.

python3 - "$(dirname "$SCRIPT")" "$ROOT/fakevnc" <<'PY' &
import os, sys, time
sys.path.insert(0, sys.argv[1])
import vnc
events, conns = [], []
listener, port = vnc._fake_vnc_server(events, conns)
with open(sys.argv[2] + ".port", "w") as handle:
    handle.write(str(port))
def save_events():
    # Replace the file in one step, so a reader never sees it half-written.
    with open(sys.argv[2] + ".events.tmp", "w") as handle:
        handle.write("\n".join(events) + "\n")
    os.replace(sys.argv[2] + ".events.tmp", sys.argv[2] + ".events")
deadline = time.time() + 60
while time.time() < deadline and not os.path.exists(sys.argv[2] + ".stop"):
    save_events()
    time.sleep(0.1)
save_events()
for conn in conns:
    try:
        conn.shutdown(2)
    except OSError:
        pass
PY
FAKE_VNC_PID=$!
for _ in $(seq 50); do [[ -s "$ROOT/fakevnc.port" ]] && break; sleep 0.1; done
export FAKE_VNC_PORT
FAKE_VNC_PORT="$(cat "$ROOT/fakevnc.port")"

if run --vm upvm up --vnc && [[ -S "$TVM_HOME/run/upvm.vncsock" ]]; then
  ok "up --vnc opens one VNC session"
else
  bad "up --vnc did not open a VNC session"; sed 's/^/     /' "$ROOT/out" "$TVM_HOME/logs/upvm.vnc.log"
fi
if run --vm upvm screenshot "$ROOT/a.png" && run --vm upvm key cmd-q && run --vm upvm click 1 1 \
   && run --vm upvm screenshot "$ROOT/b.png" && [[ -s "$ROOT/b.png" ]]; then
  ok "screen commands work through the session"
else
  bad "screen commands failed"; sed 's/^/     /' "$ROOT/out"
fi
sleep 0.3
connects="$(grep -c '^connect$' "$ROOT/fakevnc.events" || true)"
[[ "$connects" == 1 ]] && ok "four screen commands used one VNC connection" || bad "VNC connections: $connects (want 1)"

# --- approve-download: aimed only at the prompt, and a bypass says so -------------
# Fake guest tools: `osascript` prints $FAKE_WINDOWS (the window list), and
# Transcripted "runs" once $ROOT/app-up exists, the quarantine flag was
# cleared and the app opened, or (FAKE_RETURN_STARTS=1) Return was pressed.
mkdir -p "$ROOT/fakebin"
cat >"$ROOT/fakebin/pgrep" <<'EOF2'
#!/usr/bin/env bash
[[ -f "$FAKE_ROOT/app-up" ]] && exit 0
# FAKE_START_AFTER=N: the app shows up on the Nth check (it was slow to start).
echo >>"$FAKE_ROOT/pgrep-calls"
[[ -n "${FAKE_START_AFTER:-}" ]] && (( $(wc -l <"$FAKE_ROOT/pgrep-calls") >= FAKE_START_AFTER )) && exit 0
[[ "${FAKE_RETURN_STARTS:-}" == 1 ]] && grep -q "^key ff0d down" "$FAKE_ROOT/fakevnc.events" && exit 0
exit 1
EOF2
cat >"$ROOT/fakebin/osascript" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_WINDOWS"
EOF2
printf '#!/usr/bin/env bash\necho "/Applications/Transcripted.app: accepted"\n' >"$ROOT/fakebin/spctl"
printf '#!/usr/bin/env bash\ntouch "$FAKE_ROOT/cleared"\n' >"$ROOT/fakebin/xattr"
printf '#!/usr/bin/env bash\n[[ -f "$FAKE_ROOT/cleared" ]] && touch "$FAKE_ROOT/app-up"; exit 0\n' >"$ROOT/fakebin/open"
printf '#!/usr/bin/env bash\nexit 0\n' >"$ROOT/fakebin/killall"
# CI may run this as root, which sends guest scripts through `launchctl asuser UID sudo -u USER -H`.
printf '#!/usr/bin/env bash\nshift 2; [[ "$1" == sudo ]] && shift 4; exec "$@"\n' >"$ROOT/fakebin/launchctl"
chmod +x "$ROOT/fakebin"/*
approve() {
  rm -f "$ROOT/cleared" "$ROOT/pgrep-calls"
  local rc=0
  FAKE_ROOT="$ROOT" PATH="$ROOT/fakebin:$PATH" bash "$SCRIPT" --vm upvm approve-download >"$ROOT/out" 2>&1 || rc=$?
  echo "$rc"
}
input_events() { grep -c '^key\|^pointer' "$ROOT/fakevnc.events" || true; }

touch "$ROOT/app-up"
rc="$(approve)"
[[ "$rc" == 0 ]] && grep -q "already running" "$ROOT/out" && ok "approve-download leaves a running app alone" \
  || { bad "approve-download with the app running (exit $rc)"; sed 's/^/     /' "$ROOT/out"; }
rm -f "$ROOT/app-up"

before="$(input_events)"
rc="$(FAKE_WINDOWS='execution error: no window server' approve)"
if [[ "$rc" == 3 ]] && grep -q "not clicking blind" "$ROOT/out" && grep -q "BYPASSED" "$ROOT/out" \
   && [[ "$(input_events)" == "$before" ]]; then
  ok "no window list: no clicks or keys, and the fallback exits 3 (bypass)"
else
  bad "approve-download without a window list (exit $rc)"; sed 's/^/     /' "$ROOT/out"
fi
rm -f "$ROOT/app-up"

before="$(input_events)"
rc="$(FAKE_WINDOWS=$'screen 1024\nprompt 400 300 260 200\nfront Finder' approve)"
if [[ "$rc" == 3 ]] && grep -q "isn't in front (Finder is), so not pressing Return" "$ROOT/out" \
   && [[ "$(input_events)" == "$before" ]]; then
  ok "a prompt that isn't in front gets no Return, and the fallback is marked as a bypass"
else
  bad "approve-download pressed keys at the wrong window (exit $rc)"; sed 's/^/     /' "$ROOT/out"
fi
rm -f "$ROOT/app-up"

# An app that starts slowly after a click is found before the next try, so
# nothing more is clicked and nothing is bypassed.
before="$(input_events)"
rc="$(FAKE_START_AFTER=2 FAKE_WINDOWS=$'screen 1024\nprompt 400 300 260 200\nfront Finder' approve)"
if [[ "$rc" == 0 ]] && grep -q "took a while" "$ROOT/out" && ! grep -q "BYPASSED\|not pressing" "$ROOT/out"; then
  ok "each retry first checks whether the app already started"
else
  bad "approve-download kept going after the app started (exit $rc)"; sed 's/^/     /' "$ROOT/out"
fi
rm -f "$ROOT/app-up"

rc="$(FAKE_RETURN_STARTS=1 FAKE_WINDOWS=$'screen 1024\nprompt 400 300 260 200\nfront CoreServicesUIAgent' approve)"
if [[ "$rc" == 0 ]] && grep -q "pressed Return" "$ROOT/out" && ! grep -q "BYPASSED" "$ROOT/out"; then
  ok "Return goes to the prompt when it is in front, and that counts as a user's path"
else
  bad "approve-download with the prompt in front (exit $rc)"; sed 's/^/     /' "$ROOT/out"
fi
rm -f "$ROOT/app-up"

run --vm upvm down || true
: >"$ROOT/fakevnc.stop"
wait "$FAKE_VNC_PID" 2>/dev/null || true
for _ in $(seq 50); do [[ -e "$TVM_HOME/run/upvm.vncsock" ]] || break; sleep 0.1; done
[[ ! -e "$TVM_HOME/run/upvm.vncsock" ]] && ok "the VNC session ends when the VNC server goes away" || bad "the VNC session outlived its server"
expect_refused "screenshot after the session ended" bash "$SCRIPT" --vm upvm screenshot "$ROOT/c.png"
# A session killed outright leaves its socket file behind; that isn't a live session.
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$TVM_HOME/run/upvm.vncsock"
echo 999999 >"$TVM_HOME/run/upvm.vncpid"
expect_refused "screenshot through a stale socket" bash "$SCRIPT" --vm upvm screenshot "$ROOT/c.png"
grep -q "no screen access\|has ended" "$ROOT/out" && ! grep -qi "connection refused" "$ROOT/out" && ok "a stale socket counts as no session" || bad "stale socket not recognized"

# --- a real purge removes only TVM_HOME ----------------------------------------

if run purge --yes && [[ ! -e "$TVM_HOME" ]] && canaries_intact; then
  ok "purge --yes removes TVM_HOME and nothing else"
else
  bad "purge --yes misbehaved"; sed 's/^/     /' "$ROOT/out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
