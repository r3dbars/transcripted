#!/bin/bash
# Point this clone's git hooks at the repo's .githooks/ folder (pre-push runs
# lint.py --range on the pushed commits, check-rule-registry.py and the private denylist guard).
# Safe to run again. core.hooksPath lives in the shared .git/config, so it
# covers every worktree of this clone; the relative path resolves inside each
# worktree.
#
#   bash scripts/dev/install-git-hooks.sh           # set it (refuses to replace another hooks path)
#   bash scripts/dev/install-git-hooks.sh --force   # replace whatever is set
#   bash scripts/dev/install-git-hooks.sh --check   # exit 0 if set, 1 if not

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

want=".githooks"
mode="${1:-install}"
current="$(git config --get core.hooksPath || true)"

case "$mode" in
    --check)
        if [ "$current" = "$want" ]; then
            echo "git hooks: core.hooksPath = $want"
            exit 0
        fi
        echo "git hooks: not installed (core.hooksPath = '${current:-unset}'). Run: bash scripts/dev/install-git-hooks.sh"
        exit 1
        ;;
    install|--force) ;;
    *)
        echo "usage: $0 [--force|--check]" >&2
        exit 2
        ;;
esac

if [ ! -d "$want" ]; then
    echo "install-git-hooks: $root/$want is missing" >&2
    exit 1
fi
chmod +x "$want"/* 2>/dev/null || true

if [ "$current" = "$want" ]; then
    echo "git hooks: already installed (core.hooksPath = $want)"
    exit 0
fi
if [ -n "$current" ] && [ "$mode" != "--force" ]; then
    echo "install-git-hooks: core.hooksPath is already '$current'. Rerun with --force to replace it." >&2
    exit 1
fi

git config core.hooksPath "$want"
echo "git hooks: installed (core.hooksPath = $want). Skip once with git push --no-verify."
