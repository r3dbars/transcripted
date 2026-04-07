#!/bin/bash
# Set up Transcripted's `.deps-libs` / `.deps-modules` symlinks so the Xcode
# project and `swift test` can resolve the prebuilt FluidAudio + MLX +
# TranscriptedCore mega-library that Draft's `build-deps.sh` produces.
#
# Background
# ----------
# TranscriptedCore's Package.swift declares `-I ./.deps-modules` and
# `-L ./.deps-libs` unsafeFlags against a prebuilt static library
# (`libDraftDeps.a`) that Draft builds via its unified SPM graph. The pbxproj
# mirrors those search paths via `$(SRCROOT)/.deps-libs` and
# `$(SRCROOT)/.deps-modules`.
#
# Previously these paths were committed symlinks pointing at a hard-coded
# sibling Draft checkout. That broke whenever Transcripted was checked out to
# a different depth, or when the user wanted to consume a Draft worktree
# instead of the main checkout. This script replaces the committed symlinks
# with gitignored symlinks that we create at setup time from whichever Draft
# checkout we can discover.
#
# Discovery order
# ---------------
#   1. `$TRANSCRIPTED_DRAFT_ROOT`           — explicit override
#   2. Sibling worktree with the same name  — e.g. when both repos are checked
#      out as `<repo>/.claude/worktrees/<branch-name>`, prefer the Draft
#      worktree at the same position.
#   3. `<repo-parent>/../Draft/.claude/worktrees/transcripted-merge` — the
#      canonical Draft worktree for the current merge work.
#   4. `<repo-parent>/../Draft`             — Draft main checkout fallback.
#
# The script fails with a clear error if none of these paths exist or if the
# discovered Draft checkout does not yet have `deps-libs/libDraftDeps.a`
# (caller must run `bash build-deps.sh` in Draft first).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# Resolve the main checkout even when this script is running from a detached git
# worktree under /tmp. `git rev-parse --git-common-dir` points at the shared
# .git dir for the primary checkout, which lets us recover the real sibling repo
# layout (e.g. ~/code/Transcripted next to ~/code/Draft).
PRIMARY_CODE_PARENT=""
if COMMON_GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"; then
    case "$COMMON_GIT_DIR" in
        /*) ;;
        *) COMMON_GIT_DIR="$REPO_ROOT/$COMMON_GIT_DIR" ;;
    esac
    if [ -d "$COMMON_GIT_DIR" ]; then
        PRIMARY_REPO_ROOT="$(cd "$COMMON_GIT_DIR/.." && pwd)"
        PRIMARY_CODE_PARENT="$(cd "$PRIMARY_REPO_ROOT/.." && pwd)"
    fi
fi

log() { echo "[build-transcripted-deps] $*"; }

# ---------------------------------------------------------------------------
# 1. Discover Draft checkout
# ---------------------------------------------------------------------------

DRAFT_ROOT=""
SEARCHED=()

try_draft_root() {
    local candidate="$1"
    SEARCHED+=("$candidate")
    if [ -d "$candidate" ] && [ -f "$candidate/build-deps.sh" ]; then
        DRAFT_ROOT="$candidate"
        return 0
    fi
    return 1
}

# (1) Explicit override
if [ -n "$TRANSCRIPTED_DRAFT_ROOT" ]; then
    if try_draft_root "$TRANSCRIPTED_DRAFT_ROOT"; then
        log "Using TRANSCRIPTED_DRAFT_ROOT override: $DRAFT_ROOT"
    else
        log "ERROR: TRANSCRIPTED_DRAFT_ROOT='$TRANSCRIPTED_DRAFT_ROOT' does not point at a Draft checkout"
        exit 1
    fi
fi

# (2) Sibling worktree with the same name
if [ -z "$DRAFT_ROOT" ]; then
    # Detect whether we're running from a .claude/worktrees/<name> directory.
    # If so, try the matching Draft worktree first.
    case "$REPO_ROOT" in
        */.claude/worktrees/*)
            WORKTREE_NAME="$(basename "$REPO_ROOT")"
            # Walk up past `<name>/worktrees/.claude/` to reach the repo that
            # contains this worktree, then one more level to the parent dir
            # that holds both repos.
            REPO_CONTAINER="$(cd "$REPO_ROOT/../../.." && pwd)"
            CODE_PARENT="$(cd "$REPO_CONTAINER/.." && pwd)"
            try_draft_root "$CODE_PARENT/Draft/.claude/worktrees/$WORKTREE_NAME" && \
                log "Matched sibling Draft worktree: $DRAFT_ROOT"
            ;;
    esac
fi

# (3) Canonical merge worktree
if [ -z "$DRAFT_ROOT" ]; then
    case "$REPO_ROOT" in
        */.claude/worktrees/*)
            REPO_CONTAINER="$(cd "$REPO_ROOT/../../.." && pwd)"
            CODE_PARENT="$(cd "$REPO_CONTAINER/.." && pwd)"
            ;;
        *)
            if [ -n "$PRIMARY_CODE_PARENT" ]; then
                CODE_PARENT="$PRIMARY_CODE_PARENT"
            else
                CODE_PARENT="$(cd "$REPO_ROOT/.." && pwd)"
            fi
            ;;
    esac
    try_draft_root "$CODE_PARENT/Draft/.claude/worktrees/transcripted-merge" && \
        log "Matched canonical Draft worktree: $DRAFT_ROOT"
fi

# (4) Draft main checkout
if [ -z "$DRAFT_ROOT" ]; then
    if [ -z "$CODE_PARENT" ]; then
        if [ -n "$PRIMARY_CODE_PARENT" ]; then
            CODE_PARENT="$PRIMARY_CODE_PARENT"
        else
            CODE_PARENT="$(cd "$REPO_ROOT/.." && pwd)"
        fi
    fi

    try_draft_root "$CODE_PARENT/Draft" && \
        log "Matched Draft main checkout: $DRAFT_ROOT"
fi

if [ -z "$DRAFT_ROOT" ]; then
    log "ERROR: Could not locate a Draft checkout. Searched:"
    for path in "${SEARCHED[@]}"; do
        log "  - $path"
    done
    log ""
    log "Set TRANSCRIPTED_DRAFT_ROOT=/path/to/Draft to override, or clone"
    log "Draft alongside Transcripted (e.g. ~/code/Draft and ~/code/Transcripted)."
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Verify Draft has built its deps
# ---------------------------------------------------------------------------

DRAFT_LIBS="$DRAFT_ROOT/deps-libs"
DRAFT_MODULES="$DRAFT_ROOT/deps-modules"

if [ ! -f "$DRAFT_LIBS/libDraftDeps.a" ] || [ ! -d "$DRAFT_MODULES" ]; then
    log "ERROR: Draft's unified dependency library has not been built yet."
    log "  Expected: $DRAFT_LIBS/libDraftDeps.a"
    log "  Expected: $DRAFT_MODULES/"
    log ""
    log "Run this first:"
    log "  cd '$DRAFT_ROOT' && bash build-deps.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Create / refresh local symlinks
# ---------------------------------------------------------------------------

link_deps() {
    local target="$1"
    local link_name="$2"
    local link_path="$REPO_ROOT/$link_name"

    if [ -L "$link_path" ]; then
        rm "$link_path"
    elif [ -e "$link_path" ]; then
        log "ERROR: $link_path exists and is not a symlink. Refusing to overwrite."
        exit 1
    fi

    ln -s "$target" "$link_path"
    log "Linked $link_name -> $target"
}

link_deps "$DRAFT_LIBS" ".deps-libs"
link_deps "$DRAFT_MODULES" ".deps-modules"

log ""
log "Done. You can now:"
log "  - xcodebuild -project Transcripted.xcodeproj -scheme Transcripted build"
log "  - swift test"
