# Codex automations

Scheduled jobs that keep Transcripted moving without Justin. Each runs as a Codex automation on the owner's Mac. The automation's prompt only points at a playbook in this folder, so every change to a job's behavior goes through a reviewed PR.

| Job | Every | Playbook | What it does |
|---|---|---|---|
| Auto-merge gate | **Not scheduled** (see below) | `docs/auto-merge-gate.md` | Dry run by hand only, until the App-gated flow and bot identity are in place |
| Finding responder | Hourly | `docs/automations/finding-responder.md` | Fixes real Codex review findings, answers wrong ones with evidence, hands unclear ones to Justin |
| Docs drift | Nightly, 11:00 PM | `docs/automations/docs-drift.md` | Fixes folder `AGENTS.md` and `docs/` statements the code no longer matches, in `docs` lane PRs |
| Stale PRs | Nightly, midnight | `docs/automations/stale-prs.md` | Closes PRs whose work already landed, updates conflicted lane branches, flags red or quiet PRs |
| Morning triage | Daily, 3:00 AM | `docs/automations/morning-triage.md` | Turns overnight Sentry problems into GitHub issues, with no private data |
| Worktree cleanup | Weekly, Sunday 1:00 AM | `docs/automations/worktree-cleanup.md` | Removes finished, clean, pushed worktrees to free disk |

The overnight jobs run between 11 PM and 3 AM, so everything that needs Justin is ready when Claude's "waiting on a human" list arrives at 4:45 AM.

## Setting one up in Codex

Codex app → Automations → New automation. Project: a separate worktree for each job, `~/transcripted/.claude/worktrees/automation-<job-id>` (create once per job with `git -C ~/transcripted worktree add --detach .claude/worktrees/automation-<job-id> origin/main`), never Justin's main checkout. Schedule: as in the table. Prompt:

```text
In this job's dedicated Transcripted automation worktree, acquire an exclusive filesystem lock before any git command and hold it until this entire run finishes. If the lock is already held, stop without touching the checkout. Release only the lock this run acquired, including on failure. Never reuse another job's worktree. Then: if git status --porcelain isn't empty, stop and report. Otherwise git fetch --prune, then git checkout --detach origin/main.
Read <playbook path> and do exactly what it says. Report only if you acted or hit an error.
```

**The auto-merge gate isn't scheduled.** As of 2026-10-10 no reachable machine runs it. The checks covered Justin's Mac (Codex automations, launchd agents and daemons, crontab), the agent box, and the repo workflows. The Linux PC and second Mac were offline. Don't re-enable it except under the App-gated flow (`docs/agent-merge-policy.md`) and signed in as the agent bot account (`docs/automerge-justin-setup.md`), never as `r3dbars`. Until then, run it only as a dry run: `python3 scripts/ops/auto-merge-gate.py` (no `--apply`). Details are in `docs/auto-merge-gate.md`.

If it's re-enabled under that flow, its prompt can run the script directly:

```text
In this job's dedicated Transcripted automation worktree, acquire an exclusive filesystem lock before any git command and hold it until this entire run finishes. If the lock is already held, stop without touching the checkout. Release only the lock this run acquired, including on failure. Never reuse another job's worktree. Then: if git status --porcelain isn't empty, stop and report. Otherwise git fetch --prune, then git checkout --detach origin/main.
Run: python3 scripts/ops/auto-merge-gate.py --apply
Report only if something merged or the gate errored. Never merge anything yourself.
```

## Stopping a job

Pause it in the Codex app. To stop one PR instead, add the `hold` label.
