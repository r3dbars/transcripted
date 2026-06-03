# Agent Closeout

Use this when handing work back to a coordinator, GitHub issue, PR, or another
agent.

## Coordinator Line

End delegated work with one line:

```text
COORD_DONE: GREEN/BRIEF/RED | PR URL if any | changes made | GitHub cleanup recommendations | decisions needed | tests/checks run | smallest next action
```

Status meanings:

- `GREEN` - patch or audit is complete and reviewable
- `BRIEF` - read-only result, no-change result, or narrow partial result with a
  clear next move
- `RED` - blocked, unsafe, failing verification, or needs a human decision

## Before Closeout

- Run `git status --short` and make sure only your task files are changed.
- Run `bash scripts/dev/agent-preflight.sh`.
- Run the union of checks from `.agents/test-matrix.yml`.
- If you changed UI, include sanitized `.agent-review/visuals/` evidence.
- If you touched release/update flow, say whether Sparkle, Homebrew, Sentry
  release metadata, dSYM upload, and public download surfaces were updated.
- If you touched observability, say which sanitizer/policy tests or privacy
  checks covered the payload shape.
- If you did not make a patch, say why.

## GitHub Cleanup Boundaries

Agents may recommend cleanup, but should not delete branches, close issues,
close PRs, edit labels, edit milestones, or change repo settings unless Justin
explicitly asked for that action.

Good cleanup recommendations name the exact object and reason:

- stale merged branch candidate
- duplicate or superseded draft PR
- open issue that needs a current next-slice comment
- missing label or milestone that would improve routing
- check failure that needs rerun or human hardware validation

## Good Final Shape

Keep it short. Include:

- what changed or what was found
- PR URL, if there is one
- checks run and whether they passed
- blockers or decisions needed
- one smallest next action
