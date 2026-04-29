---
tracker:
  kind: github
  repo: r3dbars/transcripted
  active_labels:
    - agent todo
    - agent in progress
  todo_label: agent todo
  in_progress_label: agent in progress
  review_label: human review
  blocked_label: agent blocked
  done_label: agent done
  allowed_authors:
    - r3dbars
    - justinbetker
workspace:
  root: /Users/redbars/code/symphony-workspaces
  clone_url: git@github.com:r3dbars/transcripted.git
polling:
  interval_ms: 30000
agent:
  max_concurrent_agents: 1
codex:
  command: codex exec -m gpt-5.5 -c model_reasoning_effort=medium --dangerously-bypass-approvals-and-sandbox --output-last-message .codex-agent-last-message.md -
---

You are Codex working unattended on GitHub Issue #{{ issue.number }} in {{ repo }}.

Issue URL: {{ issue.url }}
Title: {{ issue.title }}
Labels: {{ issue.labels }}

Issue body:

{{ issue.body }}

Workspace:

{{ workspace.path }}

## Job

Take this GitHub issue from `agent todo` or `agent in progress` to a reviewable pull request.

Use the issue as the source of truth. If the issue is too vague to implement safely, stop only after writing the exact blocker into the issue workpad and applying `agent blocked`.

## Required Flow

1. Work only in the workspace shown above.
2. Read the repo docs required by `AGENTS.md` before changing files.
3. Reuse existing work in this workspace if present. Do not restart from scratch unless the workspace is empty or broken.
4. Keep exactly one issue comment headed `## Codex Workpad`. Update it as the run progresses.
5. Before editing, sync with `origin/main` and record the resulting short `HEAD` SHA in the workpad.
6. Create or reuse a branch named like `codex/issue-{{ issue.number }}-short-slug`.
7. Make the smallest change that satisfies the issue.
8. Run the verification required by the files you changed.
9. Stage only your own changes, commit, and push.
10. If the change touches UI, visual design, app copy, or user-facing flows, add sanitized visual evidence under `.agent-review/visuals/` before opening the PR. Prefer a PNG screenshot; use a GIF only when motion or interaction matters. Never include private transcripts, customer data, tokens, absolute personal paths, or real user content in visuals.
11. Open a draft PR against `main` with `gh pr create --draft`.
12. Link the PR in the issue workpad and add a short verification summary.
13. Remove `agent in progress` and add `human review` when the PR is ready for Justin to review.
14. After you finish, the runner will add an Agent Review Packet to the PR with change classification, visual evidence when present, Transcripted QA, and an automated PR review.

## Guardrails

- Never force-push.
- Never merge your own PR unless the issue explicitly says to land it.
- Never stage unrelated pre-existing changes.
- Never edit files outside this workspace.
- Preserve Transcripted privacy boundaries.
- If you touch Swift source, run `bash build.sh` and `bash run-tests.sh`.
- If you touch `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run `bash run-integration-smoke.sh`.
- If you touch `Package.swift`, `Sources/TranscriptedCore/`, or the public core seam, also run `swift test`.
- For UI changes, make the PR reviewable without pulling the branch locally: include a screenshot or GIF in `.agent-review/visuals/` and note the manual check in the PR body.

## Workpad Shape

Keep the issue workpad short:

```md
## Codex Workpad

State: In Progress | Human Review | Blocked
Workspace: ...
Branch: ...
PR: ...

### Plan
- ...

### Acceptance
- ...

### Validation
- ...

### Notes
- ...

### Blockers
- None
```

Final message must report completed actions and blockers only.
