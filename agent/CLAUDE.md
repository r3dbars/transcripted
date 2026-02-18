# Orchestrator Agent

## What This Does

Autonomous Python agent that watches `feedback.jsonl` for new accepted drafts, uses Claude Agent SDK (Sonnet) to analyze feedback patterns, and proposes prompt improvements as insight cards streamed to Draft's Agent tab via SSE.

## Architecture

```
main.py          — Entry point: HTTP server + watcher + debounce loop
server.py        — aiohttp server: SSE /events, POST /apply, POST /skip, GET /health
watcher.py       — Polls feedback.jsonl for new lines (5s interval)
orchestrator.py  — Claude Agent SDK: runs analysis, streams cards
tools.py         — 7 @tool functions + MCP server + suggestion logger
prompts.py       — Agent system prompt (personality + rules)
```

## Communication

- **Port**: `127.0.0.1:19832` (localhost only)
- **SSE stream**: `GET /events` — sends `event: insight` cards, `event: analyzing`, `event: analysis_complete`
- **Apply**: `POST /apply` — writes change to `prompts.json`, logs to `suggestion_log.jsonl`
- **Skip**: `POST /skip` — logs to `suggestion_log.jsonl` for meta-learning
- **Health**: `GET /health` — returns status, PID, uptime, last analysis time

## Tools

| Tool | Purpose |
|------|---------|
| `read_feedback` | Read recent entries from feedback.jsonl |
| `read_prompts` | Read current prompts.json |
| `read_style_profile` | Read style.md |
| `read_suggestion_log` | Read past Apply/Skip decisions |
| `get_edit_patterns` | Compute aggregate edit distance stats |
| `get_platform_stats` | Per-platform quality breakdown |
| `propose_prompt_change` | Emit an insight card to SSE queue |

## Data Files

All in `~/Library/Application Support/Draft/`:
- `feedback.jsonl` — Read by agent. Written by Swift (FeedbackStore).
- `prompts.json` — Read and written by agent (on Apply). Read by Swift (PromptStore).
- `style.md` — Read by agent (context only). Written by Swift (StyleEngine).
- `suggestion_log.jsonl` — Written by agent. Tracks Apply/Skip decisions.

## Trigger Policy

- Watcher polls every 5 seconds
- Debounce: 30 seconds of quiet after last new entry
- Minimum 3 new entries to trigger analysis
- Budget cap: $0.50 per analysis run (Sonnet)

## Setup

```bash
cd /Users/justin.betker/Draft
pip install -r agent/requirements.txt
```

## Running Standalone

```bash
cd /Users/justin.betker/Draft
python3 -m agent.main
```

Test SSE: `curl -N http://127.0.0.1:19832/events`
Test health: `curl http://127.0.0.1:19832/health`

## Critical Rules

- NEVER remove `{STYLE_SUMMARY}`, `{USER_NAME}`, `{APP_NAME}` placeholders from prompts
- `propose_prompt_change` does NOT write to disk — it only pushes to the SSE queue
- Actual writes happen only via `/apply` endpoint (user clicked Apply)
- The agent reads `suggestion_log.jsonl` before proposing to avoid re-proposing skipped suggestions
