# lint-fixture-path: scripts/vm/fixture.sh
# Shape of the VM script before ef308af42: purge deletes whatever TVM_HOME says.
set -euo pipefail
TVM_HOME="${TVM_HOME:-$HOME/.sample-vm}"

log() { echo "[vm] $*"; }

cmd_purge() {
  [[ "${1:-}" == "--yes" ]] || exit 1
  log "deleting $TVM_HOME"
  rm -rf "$TVM_HOME"
}
