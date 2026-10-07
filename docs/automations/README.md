# Codex automations

Scheduled jobs that keep Transcripted moving without Justin. Each runs as a Codex automation on the owner's Mac. The automation's prompt only points at a playbook in this folder, so every change to a job's behavior goes through a reviewed PR.

| Job | Every | Playbook | What it does |
|---|---|---|---|
| Auto-merge gate | 30 min | `docs/auto-merge-gate.md` | Marks lane drafts ready once only the review is missing; merges lane PRs that pass every check |
| Finding responder | 30 min | `docs/automations/finding-responder.md` | Fixes real Codex review findings, answers wrong ones with evidence, hands unclear ones to Justin |

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
