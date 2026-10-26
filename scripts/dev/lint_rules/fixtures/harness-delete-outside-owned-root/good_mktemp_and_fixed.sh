# lint-fixture-path: scripts/models/fixture.sh
# Deletes of mktemp folders (also from a trap), fixed paths under the script's own
# folder, and literal paths are fine.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sample-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
WORK="$STAGE/work"
rm -rf "$WORK"
BUILD_DIR="$REPO_ROOT/build/sample"
rm -rf "$BUILD_DIR"
rm -rf build/tmp
OUT="${SAMPLE_OUT:-$REPO_ROOT/out}"
rm -rf "$OUT/report.json"

swap_in_place() {
  local final="$1"
  rm -rf "${final}.old"
}
