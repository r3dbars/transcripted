# lint-fixture-path: scripts/ops/stop-latency-bench.sh
#!/bin/bash
APP_NAME="Transcripted"
APP_BUNDLE="build/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
HOME="$(mktemp -d)" \
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
"$APP_BINARY"
