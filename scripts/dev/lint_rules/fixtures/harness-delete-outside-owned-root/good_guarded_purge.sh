# lint-fixture-path: scripts/vm/fixture.sh
# Resolve the home folder, insist it is the marked folder, and guard child deletes
# with a case arm on the owned root.
set -euo pipefail
TVM_HOME="${TVM_HOME:-$HOME/.sample-vm}"
HOME_MARKER=".sample-vm-home"

prepare_home() {
  mkdir -p "$TVM_HOME"
  local resolved
  resolved="$(cd "$TVM_HOME" && pwd -P)"
  [[ -f "$resolved/$HOME_MARKER" ]] || exit 1
  TVM_HOME="$resolved"
}

cmd_purge() {
  rm -rf "$TVM_HOME"
}

remove_share() {
  local dir="$TVM_HOME/share/$1"
  case "$dir" in
    "$TVM_HOME"/share/*) rm -rf "$dir" ;;
  esac
}
