# Vacation Status - 2026-06-26

## Repo Truth

- Default branch: `main`
- Current `origin/main`: `e9a0ad5488ae76a46b5dbc915d6b33c56da9817b`
- Inspected working copy: `/Users/redbars/.codex/worktrees/dfed/transcripted-latest`
- Inspected branch: `codex/posthog-product-nervous-system` at `d620ba58d624f5249ec29645c03387525358c434`
- Working copy state at inspection: dirty; do not treat it as release-ready.

## Open PRs

- #1333 draft - Add release guardrails (`codex/vacation-release-guardrails` -> `main`)
- #1332 draft - Add vacation handoff note (`codex/vacation-handoff-doc` -> `main`)
- #1330 draft - Reversible speaker merges
- #1329 draft - Home list SQLite metadata index
- #1326 draft - Local semantic and hybrid transcript search
- #1325 draft - Crash-safe daily dictation appends
- #1175 ready-looking but risky - Optional ERes2Net on-device voiceprint

## Safe Items

- `main` is current at the SHA above and GitHub is reachable.
- Vacation/release guardrail docs already have draft PRs open.
- The safest near-term lane is documentation, release guardrails, and small proof improvements.

## Risky Items

- The inspected worktree has uncommitted observability/MCP/code changes plus `.wrangler/`.
- Release truth still needs live appcast/download/manual Mac proof before calling anything green.
- Speaker identity, semantic search, and home-list index PRs are product-sensitive and should not be merged without focused proof.

## First Action Back

Start with #1333 and #1332, then re-run release truth checks against live GitHub, appcast, download page, and manual app launch before touching broader product PRs.
