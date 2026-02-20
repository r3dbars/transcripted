# ⚠️ DEPRECATED — DO NOT USE

The Python orchestrator agent has been replaced by native Swift `AnalysisEngine`
(see `Sources/Analysis/AnalysisEngine.swift`).

The files in this directory are preserved for reference only. The Python subprocess
is no longer launched by the app. Do not modify these files.

## Why replaced?

- Subprocess crashes were the #1 reliability failure mode
- Python cold start added 2-5s startup latency
- Port 19832 could conflict with other processes
- Required a venv with external dependencies
- Native Swift implementation does everything in-process with zero overhead

## What replaced what?

| Python | Swift |
|--------|-------|
| agent/watcher.py | DispatchSource in AnalysisEngine |
| agent/orchestrator.py | AnalysisEngine.runAnalysis() |
| agent/server.py SSE | @Published var insights |
| agent/chat.py | StreamingChatEngine |
| OrchestratorBridge.swift | AnalysisEngine.swift |

---

# Original Documentation (preserved for reference)

## What This Did

Autonomous Python agent that watched `feedback.jsonl` for new accepted drafts, used Claude Agent SDK (Sonnet) to analyze feedback patterns, and proposed prompt improvements as insight cards streamed to Draft's Agent tab via SSE.

## Architecture

```
main.py          — Entry point: HTTP server + watcher + debounce loop
server.py        — aiohttp server: SSE /events, POST /apply, POST /skip, GET /health
watcher.py       — Polls feedback.jsonl for new lines (5s interval)
orchestrator.py  — Claude Agent SDK: runs analysis, streams cards
tools.py         — 1 @tool (propose_prompt_change) + MCP server + suggestion logger
prompts.py       — Agent system prompt (personality + rules)
```

## Communication

- **Port**: `127.0.0.1:19832` (localhost only)
- **SSE stream**: `GET /events` — sends `event: insight` cards, `event: analyzing`, `event: analysis_complete`
- **Apply**: `POST /apply` — writes change to `prompts.json`, logs to `suggestion_log.jsonl`
- **Skip**: `POST /skip` — logs to `suggestion_log.jsonl` for meta-learning
- **Health**: `GET /health` — returns status, PID, uptime, last analysis time
