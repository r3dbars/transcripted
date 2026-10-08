# Codex job: docs drift

Runs nightly at 11:00 PM as a Codex automation on the owner's Mac. It keeps the folder `AGENTS.md` files and `docs/` true to the code, because agents act on what those files say. Its PRs use the `docs` auto-merge lane (`.agents/auto-merge-lanes.json`), so they can merge without Justin once checks and Codex review pass.

## What to look at

1. `python3 scripts/dev/check-doc-paths.py`: every doc naming a path that no longer exists.
2. What changed on `main` in the last 24 hours: `git log --since=24.hours --first-parent -m --name-only origin/main` (merges diffed against their first parent, so every file a PR brought in shows up). For each folder with code changes, read its `AGENTS.md` (and any `docs/` page that covers it) and check that what it says still matches the code: file names, type names, commands, flags, defaults, counts.

## Fixing

- One folder or one doc per PR. At most 2 PRs per night.
- Change only what is now wrong. Don't rewrite style, reorganize, or add new guidance.
- Branch from `origin/main` as `garden/docs/<folder-or-doc>`, in its own git worktree.
- Stay inside the `docs` lane: folder `AGENTS.md` files (not the root one), `docs/*.md` except release, QA, download and credential docs and the protected docs under "Never" below, and `Tests/README.md`. If a fix needs anything else, open an issue for Justin instead, labeled `documentation` and `waiting-on-human`.
- Keep each PR under 300 changed lines.
- Run `bash check.sh`.
- Commit as `r3dbars <r3dbars@users.noreply.github.com>` with no AI co-author lines. Never force-push.
- Open a draft PR labeled `gardener` (create it if missing). The body lists each stale statement, what the code says now, and the file and line that proves it.

Before opening a PR, list the files of every open PR (`gh pr list --state open --limit 1000 --json number,files`) and skip a doc that another open PR already changes. `--search` only matches PR text, not changed files.

## Never

- edit the root `AGENTS.md`, `WORKFLOW.md`, `docs/automations/`, `docs/auto-merge-gate.md`, `docs/threat-model.md` or `.agents/`. If one of these drifted, open an issue as above
- change code to match a doc. When the doc is right and the code is wrong, open an issue instead
- merge, approve, or enable auto-merge

## Report

One line per PR or issue opened, with its link. On a quiet night, one line: "Docs match the code."
