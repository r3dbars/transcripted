# Vacation Handoff

Last checked: 2026-06-26.

## Current Status

- Default branch: `main` at `e9a0ad54`.
- Latest public release: `v1.1.48` / Transcripted 1.1.48, published 2026-06-13.
- Product shape on `main`: local macOS dictation, meeting capture, imported-audio transcription, saved Markdown, and read-only agent/MCP access.
- Recent `main` work improved cross-meeting agent rollups and Sparkle update smoke coverage.

## What Is Working

- `main` is the source of truth for the active Transcripted product.
- The public README, appcast, release docs, QA bench docs, and agent-start docs are present and current enough to restart work.
- Latest checked PR `#1330` had passing build/test and repo-hygiene checks; hardware smokes were skipped, so they are not proof.

## Held Or Risky

- Do not treat automation green as release-ready for audio, hardware, permissions, or install/update flows. Manual or device proof is still separate.
- Dirty or draft PRs need fresh review before merge:
  - `#1330` reversible speaker merges, draft, clean.
  - `#1329` home list SQLite index, draft, dirty.
  - `#1326` local semantic/hybrid transcript search, draft, dirty.
  - `#1325` crash-safe daily transcript appends, draft, dirty.
  - `#1175` optional ERes2Net voiceprint identity, open, dirty.
- Local worktree at handoff had unrelated uncommitted observability/MCP/settings changes. Do not stage or overwrite them accidentally.

## Open Decisions

- Pick the next merge lane before resuming: speaker identity, MCP/search, home performance, or observability.
- Decide whether `#1175` is still product-aligned before spending more review time on it.
- Before any new release, recheck GitHub release, appcast, cask, website download, Sentry, and PostHog separately.

## Restart Work

```bash
cd /Users/redbars/.codex/worktrees/dfed/transcripted-latest
git fetch --prune origin
gh pr list --repo r3dbars/transcripted --state open
bash scripts/dev/agent-preflight.sh
```

For docs-only changes, run the preflight and mapped docs gate. For code changes, use `.agents/test-matrix.yml`. For release-impacting work, read `docs/release-packaging.md` and `docs/sparkle-updates.md` first.

## Do Not Touch

- Do not rewrite or clean `archive/` unless explicitly asked.
- Do not change release surfaces, appcast, Homebrew cask, Sentry release metadata, or public download behavior without a release lane.
- Do not send transcripts, audio paths, meeting titles, speaker names, emails, tokens, or raw local paths to off-device services.
- Do not merge PRs based only on mocked, proxy, or skipped hardware proof.
