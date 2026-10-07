# Auto-merge gate

`scripts/ops/auto-merge-gate.py` merges low-risk cleanup PRs without waiting on the owner. Everything else still waits for Justin.

## What it merges

Only PRs in a lane listed in `.agents/auto-merge-lanes.json`:

| Lane | Branch prefix | May touch | Size limit |
|---|---|---|---|
| `test-shape` | `cleanup/test-shape/` | test files, its baseline | 400 lines |
| `source-pins` | `cleanup/source-pins/` | test files, its baseline | 400 lines |
| `file-size` | `cleanup/file-size/` | Sources outside the protected areas, tests, folder `AGENTS.md` files, the hand-kept source lists, its baseline | 1,600 lines (moves count twice) |

No lane may touch `deny_always`: the TranscriptedCore, Meeting, Speech and Observability modules, `.github/`, release and CI scripts, the cask and appcast, `Package.swift`, `.agents/modules.json`, the lane file itself, the root `AGENTS.md` and `WORKFLOW.md`.

## What a PR needs

All of these, checked on every run:

1. Main is green: the latest finished Swift CI run on main succeeded.
2. Author `r3dbars`, branch in this repo, branch in an enabled lane.
3. Label `cleanup`. No `needs owner review`, `do not merge` or `hold` label.
4. Every changed file inside the lane, none protected, within the size limit.
5. `build-and-test` and `repo-hygiene` succeeded on the head commit.
6. No conflicts, no review requesting changes, no unresolved review thread.
7. Codex reviewed the head commit, or reacted 👍 to the PR after it was pushed.

Each run merges at most 3 PRs, and at most one per lane, so main's CI runs between batches.

## Running it

```bash
python3 scripts/ops/auto-merge-gate.py            # dry run: what would merge, and why the rest wait
python3 scripts/ops/auto-merge-gate.py --pr 2040  # explain one PR
python3 scripts/ops/auto-merge-gate.py --apply    # merge
```

A Codex automation on the owner's Mac runs `--apply` every 30 minutes, signed in to `gh` as `r3dbars`. Merges made this way trigger the normal push CI on main.

## When something goes wrong

- **A merged PR broke something:** revert it, then set that lane's `enabled` to `false` in `.agents/auto-merge-lanes.json` until the cause has a check.
- **Stop one PR:** add the `hold` label.
- **Stop everything:** pause the Codex automation, or set every lane's `enabled` to `false`.

Adding a lane or widening a lane's globs is an owner-reviewed edit. Merging is still not shipping: releases stay manual.
