# Codex job: worktree cleanup

Runs weekly, Sunday at 1:00 AM, as a Codex automation on the owner's Mac. Agents create a git worktree per task and rarely remove it, so finished ones pile up and fill the disk. This job removes only worktrees whose work is safely on GitHub.

## Where

The worktrees of the repo at `~/transcripted` (`git worktree list`), including those under `.claude/worktrees/`. Leave the main checkout alone.

Leave alone everything outside that list too, including the `~/transcripted-*` and `~/Transcripted*` copy folders in the home folder. Those are Justin's to decide.

## A worktree may go only if all of these hold

1. `git -C <path> status --porcelain` is empty: no uncommitted or untracked changes.
2. Its branch is fully on GitHub: `git branch -r --contains <branch-head>` lists a remote branch, or the branch's commits are already on `origin/main`.
3. Its work is finished: the branch is merged into `origin/main`, or its PR was merged or closed more than 7 days ago (`gh pr list --state all --head <branch>`).
4. It's more than 2 days old, so it's not a task that just started.
5. No app is running from it. The owner often runs Transcripted straight from a worktree's `build/`. Check executable paths, not command lines (`pgrep -f` matches its own shell): `ps -axo pid=,comm= | grep -F "<path>/build/"` finds nothing (exit 1).

If any check fails or can't be run, keep the worktree.

## Removing

- `git worktree remove <path>`. Never `--force`.
- Delete the local branch with `git branch -d <branch>`, which refuses unmerged work. Never `-D`.
- Never delete remote branches.
- At the end, `git worktree prune`.

## Report

How many worktrees were removed and roughly how much disk came back (`du -sh` before removing), then one line per worktree kept for a reason worth knowing: uncommitted changes, unpushed commits, or an open PR older than 30 days.
