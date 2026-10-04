#!/bin/bash
# Refuse to delete an app bundle that is running. build.sh and build-beta.sh
# wipe build/Transcripted.app before rebuilding; when the owner runs the app
# straight from a worktree's build/ folder, that kills a live recording.
# Set FORCE_REBUILD_RUNNING=1 to rebuild anyway.

refuse_if_bundle_running() {
    local bundle="$1"
    local contents_dir
    local running_pids
    [ -d "$bundle" ] || return 0
    [ "${FORCE_REBUILD_RUNNING:-0}" = "1" ] && return 0

    # Contents/ covers the app and its helpers (llama-server, transcripted-live).
    # Match the resolved path, plus a relative launch from this folder
    # (./build/Transcripted.app/...). The relative pattern is anchored to the
    # start of an argument so another worktree's absolute path doesn't match.
    contents_dir="$(cd "$bundle" && pwd -P)/Contents/"
    # A relative match only counts when the process runs from this folder: another
    # worktree's build passes build/Transcripted.app/... to swiftc as a relative path.
    local here pid cwd
    here="$(pwd -P)"
    running_pids="$( {
        pgrep -f "$contents_dir" || true
        for pid in $(pgrep -f "(^|[[:space:]])(\./)?${bundle#./}/Contents/" || true); do
            cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
            # if, not &&: a false test as the last command of the loop fails the
            # pipeline, and build.sh runs under set -e.
            if [ "$cwd" = "$here" ]; then echo "$pid"; fi
        done
    } | sort -u)"
    [ -z "$running_pids" ] && return 0

    echo "Refusing to rebuild: $bundle is running (pid $(echo "$running_pids" | tr '\n' ' '| sed 's/ $//'))."
    echo "Quit Transcripted (and any helper it left running) and rerun, build in another"
    echo "worktree, or set FORCE_REBUILD_RUNNING=1 to delete it anyway."
    exit 1
}
