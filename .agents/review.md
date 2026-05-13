# PR Reviewer

Use this for `/review` and the hourly PR reviewer automation.

## Mission

Review every open Transcripted pull request for:

- bugs
- missing tests
- security or privacy issues
- repo style violations

If there are no open PRs, do nothing. Do not create files, comments, commits, or
status noise.

## Start

1. Read `AGENT_START.md`, `AGENTS.md`, `docs/repo-layout.md`,
   `docs/agent-onboarding.md`, `.agents/test-matrix.yml`, and the nearest
   `CLAUDE.md` for any area you inspect or edit.
2. Check `git status --short` before changing anything.
3. List open PRs:

   ```bash
   gh pr list --state open --json number,title,headRefName,baseRefName,isDraft,author,updatedAt,url,headRepositoryOwner --limit 50
   ```

4. For each open PR, read the diff, metadata, comments, and checks:

   ```bash
   gh pr view <number> --json number,title,body,headRefName,baseRefName,isDraft,author,comments,reviewDecision,statusCheckRollup,url
   gh pr diff <number> --patch
   ```

## Review Rules

- Prefer concrete bugs over guesses.
- Treat missing tests as important when the PR changes behavior, fixes a bug, or
  touches shared infrastructure.
- Treat privacy and security as product requirements. Never add off-device raw
  transcript text, audio references, meeting titles, speaker names, emails,
  tokens, absolute paths, raw device names, or sensitive URLs.
- Style violations must be real repo-pattern mismatches, not taste.
- Do not merge PRs.
- Do not publish releases.
- Do not force-push.
- Do not rewrite unrelated code.
- Do not spam repeated reviews. Track reviewed PR head SHAs in
  `/Users/redbars/.codex/automations/transcripted-hourly-pr-reviewer/memory.md`.
  If the same PR head SHA was already reviewed and there are no new findings,
  skip it.

## Comment Contract

For every newly reviewed or changed PR head, post one concise PR comment within
the run:

```md
<!-- transcripted-hourly-pr-reviewer -->
PR reviewer pass for <head-sha>

Verdict: <clean | fixed | needs changes | blocked>

Findings:
- <finding or "No blocking findings.">

Actions:
- <commit/check/comment action or "No changes made.">
```

If a prior marker comment exists for the same PR, prefer updating it when
practical. If updating is awkward, add a new marker comment only when the head
SHA changed or there is a new finding.

## Fix Rules

When you find a small, high-confidence fix that is safe to apply to the PR:

1. Check out the PR branch with `gh pr checkout <number>`.
2. Patch only the files needed for that finding.
3. Add or update tests when the fix changes behavior.
4. Run `scripts/dev/agent-preflight.sh` and the checks required by
   `.agents/test-matrix.yml` and `AGENTS.md`.
5. Stage only files changed for this reviewer fix.
6. Commit with a short message, for example:

   ```bash
   git commit -m "Fix PR review issue"
   ```

7. Push to the PR branch.
8. Comment on the PR with the finding, commit hash, and checks run.

If the PR branch cannot be pushed to, or the fix needs product judgment, leave a
comment instead of editing.

## Output

Keep the final run summary short:

- PRs checked
- PRs skipped because already reviewed
- comments posted
- fixes committed and pushed
- blocked items, if any
