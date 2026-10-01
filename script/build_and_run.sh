#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_APP="$TASK_ROOT/build/Transcripted.app"
MODE="${1:-run}"

case "$MODE" in
  run|--verify|--logs|--debug|--build-only|--launch-only) ;;
  *) echo "Usage: $0 [--verify|--logs|--debug|--build-only|--launch-only]" >&2; exit 2 ;;
esac

# A running copy might own a call. Never quit it or rebuild its bundle while
# it is running; let the user finish and quit through the native app.
python3 - "$TASK_APP/Contents/MacOS/Transcripted" "$MODE" <<'PY'
import subprocess
import sys
target = sys.argv[1]
rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
own = []
other = False
for row in rows:
    parts = row.strip().split(None, 1)
    if len(parts) != 2: continue
    command = parts[1]
    if command == target: own.append(int(parts[0]))
    elif command.endswith('/Transcripted.app/Contents/MacOS/Transcripted'): other = True
if own or (other and sys.argv[2] != '--build-only'):
    raise SystemExit('Finish any active meeting and quit Transcripted, then run this script again to test the companion build.')
PY

if [ "$MODE" != --launch-only ]; then
  bash "$TASK_ROOT/build.sh" --no-open
  python3 "$TASK_ROOT/Tools/TranscriptedCompanion/package.py" --no-build
fi
if [ "$MODE" = --build-only ]; then exit 0; fi
if [ ! -x "$TASK_APP/Contents/MacOS/Transcripted" ]; then
  echo "Build the companion app first with $TASK_ROOT/script/build_and_run.sh --build-only" >&2
  exit 1
fi

if [ "$MODE" = --debug ]; then
  exec lldb "$TASK_APP/Contents/MacOS/Transcripted"
fi
/usr/bin/open -n "$TASK_APP"
if [ "$MODE" = --verify ]; then
  python3 - "$TASK_APP/Contents/MacOS/Transcripted" <<'PY'
import subprocess
import sys
import time
for attempt in range(30):
    rows = subprocess.check_output(['ps', '-axo', 'command='], text=True).splitlines()
    if sys.argv[1] in [row.strip() for row in rows]:
        print('The companion build is running.')
        break
    time.sleep(0.2)
else:
    raise SystemExit('The app did not remain running. Inspect the native launch diagnostics.')
PY
elif [ "$MODE" = --logs ]; then
  exec /usr/bin/log stream --info --style compact --predicate 'process == "Transcripted"'
fi
