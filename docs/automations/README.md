# Codex automations

Scheduled jobs that keep Transcripted moving without Justin. Each runs as a Codex automation on the owner's Mac. The automation's prompt only points at a playbook in this folder, so every change to a job's behavior goes through a reviewed PR.

| Job | Every | Playbook | What it does |
|---|---|---|---|
| Auto-merge gate | 30 min | `docs/auto-merge-gate.md` | Marks lane drafts ready once only the review is missing; merges lane PRs that pass every check |
| Finding responder | 30 min | `docs/automations/finding-responder.md` | Fixes real Codex review findings, answers wrong ones with evidence, hands unclear ones to Justin |
| Docs drift | Nightly, 11:00 PM | `docs/automations/docs-drift.md` | Fixes folder `AGENTS.md` and `docs/` statements the code no longer matches, in `docs` lane PRs |
| Stale PRs | Nightly, midnight | `docs/automations/stale-prs.md` | Closes PRs whose work already landed, updates conflicted lane branches, flags red or quiet PRs |
| Morning triage | Daily, 3:00 AM | `docs/automations/morning-triage.md` | Turns overnight Sentry problems into GitHub issues, with no private data |
| Worktree cleanup | Weekly, Sunday 1:00 AM | `docs/automations/worktree-cleanup.md` | Removes finished, clean, pushed worktrees to free disk |

The overnight jobs run between 11 PM and 3 AM, so everything that needs Justin is ready when Claude's "waiting on a human" list arrives at 4:45 AM.

## Setting one up in Codex

Codex app → Automations → New automation. Project: `~/transcripted`. Schedule: as in the table. Prompt:

```text
In the Transcripted repo: git fetch, then check out origin/main (detached is fine).
Read <playbook path> and do exactly what it says. Report only if you acted or hit an error.
```

The gate is a script, so its prompt can run it directly:

```text
In the Transcripted repo: git fetch, then check out origin/main (detached is fine).
Run: python3 scripts/ops/auto-merge-gate.py --apply
Report only if something merged or the gate errored. Never merge anything yourself.
```

## Stopping a job

Pause it in the Codex app. To stop one PR instead, add the `hold` label.
