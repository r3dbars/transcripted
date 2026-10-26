# lint-fixture-path: scripts/dev/bench-cold-start.sh
#!/bin/bash
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
native_launch_ready() {
    /usr/bin/python3 "$REPO_ROOT/scripts/ops/native-smoke-isolation.py" || return $?
}
BENCH_APP="build/Transcripted.app"
native_launch_ready
/usr/bin/open -n -g -F -W "$BENCH_APP"
