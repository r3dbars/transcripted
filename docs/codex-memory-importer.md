# Codex Memory Importer

`scripts/ops/build-codex-memory-index.py` builds a Transcripted-first memory
index from local Codex archives without importing raw private chat logs.

## What it reads

- `~/.codex/archived_sessions/*.jsonl`
- `~/.codex/sessions/**/*.jsonl`

## What it writes

- `build/codex-memory-index/transcripted-codex-index.json`
- `build/codex-memory-index/transcripted-codex-stats.json`
- `build/codex-memory-index/transcripted-codex-followups.json`
- `build/codex-memory-index/transcripted-paperclip-task-seeds.json`
- `build/codex-memory-index/transcripted-codex-digest.md`

## Safety contract

- Metadata only: date, repo/cwd hints, intent summary, file-change hints,
  command categories, PR/issue/release links, outcome, and follow-up tasks.
- No raw prompt/chat transcript export.
- Redacts likely tokens/credentials/emails and normalizes user home paths.
- Defaults to Transcripted-related sessions only.

## Usage

```bash
python3 scripts/ops/build-codex-memory-index.py --verbose
```

Optional flags:

- `--limit 200` to scan only recent files while iterating.
- `--mlx-summarize` to try local intent summaries through the MLX endpoint.
- `--mlx-model <model-id>` to pick the local model lane.
- `--mlx-max-sessions <n>` to cap summary calls.

If MLX is unavailable, the script auto-falls back to heuristic summaries.

## Digest sections

`transcripted-codex-digest.md` includes:

- what shipped
- what broke
- repeated patterns
- unfinished threads
- next moves
- rollup counts by date, cwd, repo, and project
