# GitHub Issue Agent Workflow

This repo can use GitHub Issues as a small Symphony-style queue for Codex.

## How To Queue Work

1. Create a GitHub issue with the `Codex agent task` template.
2. Make sure it has the `agent todo` label.
3. Keep the issue small enough that a draft PR is a good review unit.

The runner treats labels as state:

- `agent todo` - ready for Codex
- `agent in progress` - Codex claimed it
- `agent review` - draft PR is ready for human review
- `agent blocked` - Codex hit a real blocker
- `agent done` - optional final state after merge or manual closeout

## Run It Locally

Create the labels once:

```bash
ruby scripts/ops/agent-todo-runner.rb --ensure-labels
```

Run one pass:

```bash
ruby scripts/ops/agent-todo-runner.rb --once
```

Watch continuously:

```bash
ruby scripts/ops/agent-todo-runner.rb --watch
```

Run a specific issue:

```bash
ruby scripts/ops/agent-todo-runner.rb --issue 123
```

## What The Runner Does

- Reads `WORKFLOW.md`.
- Finds open issues labeled `agent todo` or `agent in progress`.
- Creates or reuses `/Users/redbars/code/symphony-workspaces/GH-<issue-number>`.
- Creates a single `## Codex Workpad` issue comment if one does not exist.
- Moves new work from `agent todo` to `agent in progress`.
- Launches Codex in that issue workspace.

Codex is expected to commit, push, open a draft PR, update the workpad, and move the issue to `agent review`.

## Safety Notes

This is a trusted local runner. Codex runs in an isolated clone, but the default command in `WORKFLOW.md` uses unattended execution so it can finish without prompts.

Review the draft PR before merging. Do not put secrets or private customer data in issues.
