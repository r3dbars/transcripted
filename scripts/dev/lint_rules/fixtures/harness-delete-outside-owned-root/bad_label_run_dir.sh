# lint-fixture-path: scripts/dev/fixture.sh
# A bench that clears a run folder named by --label: `--label ../..` clears OUT_DIR's parent.
set -euo pipefail
OUT_DIR="build/bench"
LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    *) shift ;;
  esac
done
RUN_DIR="$OUT_DIR/$LABEL"
mkdir -p "$RUN_DIR"
rm -rf "$RUN_DIR/work"
