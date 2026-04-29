# GitHub Issue Agent Workflow

This repo can use GitHub Issues as a small Symphony-style queue for Codex.

## How To Queue Work

1. Check that the background watcher is running.
2. Create a GitHub issue with the `Codex agent task` template.
3. If Justin wants the agent to take it, add the `agent todo` label.
4. Keep the issue small enough that a draft PR is a good review unit.

The runner treats labels as state:

- `agent todo` - ready for Codex
- `agent in progress` - Codex claimed it
- `human review` - draft PR is ready for Justin to review
- `agent blocked` - Codex hit a real blocker
- `agent done` - optional final state after merge or manual closeout

## Run It Locally

Create the labels once:

```bash
ruby scripts/ops/agent-todo-runner.rb --labels-only
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

## Run It In The Background

Install the macOS LaunchAgent:

```bash
bash scripts/ops/agent-todo-launchagent.sh install
```

After that, your Mac watches GitHub in the background. To hand work to Codex,
add `agent todo` to an issue.

Useful commands:

```bash
bash scripts/ops/agent-todo-launchagent.sh status
bash scripts/ops/agent-todo-launchagent.sh restart
bash scripts/ops/agent-todo-launchagent.sh logs
bash scripts/ops/agent-todo-launchagent.sh uninstall
```

Before creating or labeling an `agent todo` issue for Justin, check:

```bash
bash scripts/ops/agent-todo-launchagent.sh status
```

If it is not running, restart it:

```bash
bash scripts/ops/agent-todo-launchagent.sh restart
```

## What The Runner Does

- Reads `WORKFLOW.md`.
- Finds open issues labeled `agent todo` or `agent in progress`.
- Creates or reuses `/Users/redbars/code/symphony-workspaces/GH-<issue-number>`.
- Creates a single `## Codex Workpad` issue comment if one does not exist.
- Moves new work from `agent todo` to `agent in progress`.
- Launches Codex in that issue workspace.

Codex is expected to commit, push, open a draft PR, update the workpad, and move the issue to `human review`.

## Safety Notes

This is a trusted local runner. Codex runs in an isolated clone, but the default command in `WORKFLOW.md` uses unattended execution so it can finish without prompts.

Only allowed issue authors can trigger the runner. The allowlist lives in `WORKFLOW.md` under `tracker.allowed_authors`. The public issue template does not auto-apply `agent todo`; add that label only after checking the issue is really work Justin wants to run.

Review the draft PR before merging. Do not put secrets or private customer data in issues.
