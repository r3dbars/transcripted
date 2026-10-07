# Codex job: stale PRs

Runs nightly at 3:00 as a Codex automation on the owner's Mac. It keeps the open PR list honest, so Justin and the auto-merge gate aren't looking at work that already landed or went quiet. It writes no code, except merging `main` into a lane branch that can't merge.

## For each open PR

Work through `gh pr list --state open --limit 200`.

1. **Already landed.** Run `python3 scripts/dev/check-superseded.py --pr <number>`. Exit code 3 means the work is already on `main`, under this PR or another. Comment with what the script found, then close the PR. This is the only case where this job closes a PR.
2. **Can't merge (conflicts).** For branches starting with `cleanup/`, `garden/` or `codex/issue-` only: in the PR's own git worktree, merge `origin/main` into the branch as a merge commit (never rebase, never force-push). If git merges cleanly, run `bash check.sh`, commit as `r3dbars <r3dbars@users.noreply.github.com>` and push. If there are real conflicts, don't resolve them: comment what conflicts and add `waiting-on-human`. For any other branch, only comment.
3. **Red CI for 2 days.** If `build-and-test` or `repo-hygiene` has failed on the head commit for more than 48 hours, comment with the failing check and its log link and add `waiting-on-human`.
4. **Quiet.** No commits, comments or reviews for 7 days: add `stale` (create it if missing) and comment one line asking whether it's still needed. If it was already `stale` and still quiet at 14 days, list it in the report for Justin. Don't close it.

Skip PRs labeled `hold`. Never touch a PR opened in the last 24 hours.

## Never

- close a PR for any reason except step 1
- resolve real conflicts, rebase, force-push, or push to a branch outside the three prefixes above
- merge, approve, or enable auto-merge
- remove labels Justin added

## Report

Grouped: closed as landed, branches updated, flagged for Justin (with links), newly stale. On a quiet night, one line: "PR list is clean."
