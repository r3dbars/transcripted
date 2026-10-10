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

No lane may touch `deny_always`: the TranscriptedCore, Meeting, Speech and Observability modules, `.github/`, release and CI scripts, the cask, appcast and release docs, `Package.swift`, `.agents/modules.json`, the lane file, this doc, the root `AGENTS.md` and `WORKFLOW.md`. UI, copy and new features always wait for the owner.

## What a PR needs

All of these, checked on every run:

0. The PR risk triage (`scripts/ops/risk-triage.py`, `docs/agent-merge-policy.md`) doesn't call it `risk:high`. This gate never merges a high-risk PR, whatever its lane allows: deleted tests, tests renamed out of the test folders, folder `AGENTS.md` files and medium PRs over 400 lines all wait for a person.
0a. A trusted, clean AI verdict exists for the head commit. It must come from a `risk-triage.yml` `pull_request_target` run for this PR's exact head and have no unresolved P0/P1 (see `docs/agent-merge-policy.md`, "Which verdicts count"). No verdict means no merge.

1. Main is green: the latest finished Swift CI run on main succeeded.
2. Author `r3dbars`, branch in this repo, branch in an enabled lane.
3. The lane's label. No hold label: `needs owner review`, `do not merge`, `hold`, `waiting-on-human` or `blocked`. That's the shared `HOLD_LABELS` list in `scripts/ops/risk-triage.py`, plus anything in the lane file's `blocking_labels`.
4. Every changed path inside the lane, none protected, within the size limit. The gate reads every page of the REST PR files API and checks both `filename` and `previous_filename` for renames; deletions check the removed path. Missing or malformed rename metadata and a file count that disagrees with GitHub's total block merging.
5. `build-and-test` and `repo-hygiene` succeeded on the head commit.
6. No conflicts, no review requesting changes, no unresolved review thread.
7. Every reviewer the lane requires reviewed the head commit, or reacted 👍 after it was pushed. Today that's Codex (`chatgpt-codex-connector`) for every lane; a lane can require more with `reviewers_required`.
8. `bug-fix` only: a test changed, and the app verification summary is clean and matches the head commit.

Agents open lane PRs as drafts. Once a draft passes everything except the review, the gate marks it ready for review, so Codex reviews it; a later run merges it after that review.

Each run merges at most 3 PRs, and at most one per lane, so main's CI runs between batches.

## Baselines and held PRs

A PR in any lane may change a debt baseline (`.agents/*-baseline.json`) only when the change lowers counts or drops entries, compared with the PR's merge base. That holds even for a baseline the lane's allow globs name, so a lane PR can never raise its own baseline. Anything else in a baseline (a higher count, a new entry, including a moved one, a repeated list entry, or a changed or deleted top-level setting like `limit` or `_comment`) keeps the PR out of the lane. The other baselines are re-checked against the code by `repo-hygiene`, a required check. `.agents/concurrency-baseline.json` is never eligible: only the Swift concurrency census can say a lower count is true, and that isn't a required check. Which baselines changed comes from the same rename-aware REST file list as rule 4, so renaming a baseline away counts as changing it. If GitHub can't serve a baseline during a run, the PR just waits for the next run.

When a PR can never pass in its lane (it touches protected files, has files outside the lane, or is over the size limit), the gate comments why and labels it `waiting-on-human`, so it shows up on Justin's morning list instead of waiting silently. It comments once (the comment carries a hidden marker, so a retry after a failed label doesn't post twice), and it never labels or comments on a fork, a PR from an author outside `allowed_authors`, or a PR in a disabled lane.

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
