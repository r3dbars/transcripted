# lint-fixture-path: scripts/dev/bench-cold-start.sh
#!/bin/bash
set -euo pipefail
WORK_DIR="$(mktemp -d)"
BENCH_APP="$WORK_DIR/Transcripted.app"
cp -R build/Transcripted.app "$BENCH_APP"
run_home="$WORK_DIR/home"
/usr/bin/open -n -g -F -W \
    --env "HOME=$run_home" \
    "$BENCH_APP"
