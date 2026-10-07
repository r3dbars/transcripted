# Auto-merge gate

`scripts/ops/auto-merge-gate.py` merges low-risk PRs without waiting on the owner: cleanup, doc fixes and small tested bug fixes. Everything else still waits for Justin.

## What it merges

Transcripted runs at **auto-merge level 3**. Only PRs in a lane listed in `.agents/auto-merge-lanes.json` merge without the owner:

| Lane | Level | Branch prefix | Label | May touch | Size limit |
|---|---|---|---|---|---|
| `test-shape` | 1 | `cleanup/test-shape/` | `cleanup` | test files, its baseline | 400 lines |
| `source-pins` | 1 | `cleanup/source-pins/` | `cleanup` | test files, its baseline | 400 lines |
| `file-size` | 1 | `cleanup/file-size/` | `cleanup` | Sources outside the protected areas, tests, folder `AGENTS.md` files, the hand-kept source lists, its baseline | 1,600 lines (moves count twice) |
| `module-edges` | 2 | `cleanup/module-edges/` | `cleanup` | same as `file-size`, with its own baseline | 600 lines |
| `docs` | 2 | `garden/docs/` | `gardener` | folder `AGENTS.md` files, `docs/*.md` except release, QA, download and credential docs | 300 lines |
| `bug-fix` | 3 | `codex/issue-` | `bug` | Sources outside the protected areas and outside UI, App and Capture, plus tests | 300 lines |

The `bug-fix` lane asks for more than the others:

- At least one test file changes, so the fix comes with a test.
- The PR body holds the `## App verification` summary from `bash scripts/dev/verify-change.sh` for the head commit, with no FAIL, no uncovered files and no live check owed to Justin.
- Two reviewers from different models reviewed the head commit: Codex (`chatgpt-codex-connector`) and Claude (`claude`).

No lane may touch `deny_always`: the TranscriptedCore, Meeting, Speech and Observability modules, `.github/`, release and CI scripts, the cask, appcast and release docs, `Package.swift`, `.agents/modules.json`, the lane file, this doc, the root `AGENTS.md` and `WORKFLOW.md`. UI, copy and new features always wait for the owner.

## What a PR needs

All of these, checked on every run:

1. Main is green: the latest finished Swift CI run on main succeeded.
2. Author `r3dbars`, branch in this repo, branch in an enabled lane.
3. The lane's label. No `needs owner review`, `do not merge` or `hold` label.
4. Every changed file inside the lane, none protected, within the size limit.
5. `build-and-test` and `repo-hygiene` succeeded on the head commit.
6. No conflicts, no review requesting changes, no unresolved review thread.
7. Every reviewer the lane requires reviewed the head commit, or reacted 👍 after it was pushed. Codex by default; Codex and Claude for `bug-fix`.
8. `bug-fix` only: a test changed, and the app verification summary is clean and matches the head commit.

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
