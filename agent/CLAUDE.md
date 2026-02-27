# DEPRECATED — DO NOT USE OR MODIFY

> **This entire directory is dead code.** The Python orchestrator agent has been fully
> replaced by the native Swift `AnalysisEngine` in `Sources/Analysis/AnalysisEngine.swift`.
> The app no longer launches, references, or communicates with this Python subprocess.
> These files are preserved solely as historical reference. **Do not modify them.**
>
> For the active replacement, see `Sources/Analysis/CLAUDE.md`.

## Why It Was Replaced

The Python agent was the single largest source of reliability problems in Draft:

- **Subprocess crashes** — the #1 failure mode reported by users; the Python process would die silently and the Agent tab would go dark with no recovery path
- **Cold start latency** — 2-5 seconds to spin up the Python venv + aiohttp server before any analysis could begin
- **Port conflicts** — port 19832 could collide with other local services, causing silent startup failures
- **External dependencies** — required a `.venv/` with `claude-agent-sdk` and `aiohttp` (see `requirements.txt`), adding build complexity and version fragility
- **Two-process architecture** — SSE streaming between Python and Swift introduced serialization overhead, connection drops, and reconnection logic that the in-process Swift replacement eliminates entirely

## What Replaced What

| Python (this directory) | Swift replacement (`Sources/Analysis/`) |
|-------------------------|----------------------------------------|
| `watcher.py` — polls `feedback.jsonl` every 5s | `DispatchSource` file watcher in `AnalysisEngine` (kernel-level, zero polling) |
| `orchestrator.py` — Claude Agent SDK analysis | `AnalysisEngine.runAnalysis()` — direct Anthropic API calls via `callAPIWithToolUse()` |
| `server.py` — aiohttp SSE streaming to Swift | `@Published var insights` — native SwiftUI data binding (no HTTP layer) |
| `chat.py` — interactive chat via Agent SDK | `StreamingChatEngine` — in-process streaming via Anthropic API |
| `agent_lock.py` — asyncio locks for concurrency | Swift `@MainActor` isolation in `AnalysisEngine` |
| `tools.py` — MCP server + `propose_prompt_change` | `InsightCard` structs with shared `toolDefinition` published directly to UI |
| `prompts.py` — system prompts for analysis + chat | `AnalysisEngine.buildAnalysisSystemPrompt()` + `PromptStore` |
| `main.py` — entry point, debounce loop | `AnalysisEngine.start()` + `DispatchSource` callback + cancellable `debounceTask` |
| (previously) `OrchestratorBridge.swift` | `AnalysisEngine.swift` (no bridge needed — runs in-process) |

---

# Original Documentation (preserved for historical reference)

Everything below describes how this agent **used to work** before it was replaced. None of this code is active.

## What This Did

Autonomous Python agent that watched `feedback.jsonl` for new accepted drafts, used the Claude Agent SDK (Sonnet) to analyze feedback patterns, and proposed prompt improvements as insight cards streamed to Draft's Agent tab via SSE.

## File Inventory

```
__init__.py      — Package marker (2 comment lines: module name + description)
main.py          — Entry point: aiohttp server + FeedbackWatcher + debounce loop + graceful shutdown
server.py        — aiohttp server: SSE /events, POST /apply, POST /skip, POST /chat, POST /chat/clear, POST /trigger, GET /health
watcher.py       — FeedbackWatcher class: polls feedback.jsonl by file size then line count (5s interval)
orchestrator.py  — run_analysis(): Claude Agent SDK session with propose_prompt_change tool
chat.py          — run_chat(): interactive chat via Agent SDK with conversation history (max 20 turns)
tools.py         — 1 @tool (propose_prompt_change) + MCP server (draft-tools) + suggestion logger
prompts.py       — Two system prompts: ORCHESTRATOR_SYSTEM_PROMPT + CHAT_SYSTEM_PROMPT
agent_lock.py    — Separate asyncio locks for analysis vs. chat (originally one shared lock)
requirements.txt — claude-agent-sdk>=0.1.0, aiohttp>=3.9.0
.venv/           — Python virtual environment (not committed)
__pycache__/     — Bytecode cache (not committed)
```

## Communication Protocol

- **Port**: `127.0.0.1:19832` (localhost only)
- **SSE stream**: `GET /events` — sends `event: connected` on initial connection, then `event: insight` for all non-chat events (insight cards, analyzing/analysis_complete status via `_event` field in JSON payload), and chat events routed by `_chat_event` discriminator field: `chat_token`, `chat_tool`, `chat_done`, `chat_error`
- **Apply**: `POST /apply` — writes change to `prompts.json`, logs to `suggestion_log.jsonl`
- **Skip**: `POST /skip` — logs to `suggestion_log.jsonl` for meta-learning
- **Chat**: `POST /chat` — sends user message, response streams back via SSE
- **Chat clear**: `POST /chat/clear` — resets conversation history
- **Trigger**: `POST /trigger` — manually triggers analysis (testing endpoint)
- **Health**: `GET /health` — returns status, PID, uptime, last analysis time, feedback line count

## Agent Behavior

The orchestrator used the Claude Agent SDK with Sonnet. Key constraints:
- `max_turns=10` for analysis, `max_turns=5` for chat
- `max_budget_usd=0.25` per chat session (analysis had no budget cap)
- `Write`, `Edit`, `MultiEdit` tools disabled — all prompt changes went through `propose_prompt_change`
- `permission_mode="bypassPermissions"` — auto-approved file reads
- Debounce policy: wait 30 seconds of quiet after last feedback entry, require at least 5 new entries
- Separate locks for analysis and chat to prevent chat blocking during long analysis runs
- Claude Code env vars (`CLAUDECODE`, `CLAUDE_CODE_SESSION`) stripped before SDK sessions to avoid conflicts
- Logged to `~/draft-agent.log` (file + stderr)
