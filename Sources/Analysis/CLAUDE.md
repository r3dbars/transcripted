# Analysis Engine

## What This Does

Native Swift replacement for the Python orchestrator agent. Watches `~/Library/Application Support/Draft/feedback.jsonl` for new accepted drafts, uses Claude Sonnet to analyze editing patterns, and proposes prompt improvements as InsightCards displayed in AgentSection (menubar panel). Runs entirely in-process — no subprocess, no SSE relay, no port conflicts.

## Key File

- `AnalysisEngine.swift` (~377 lines) — `@MainActor ObservableObject` with DispatchSource file watching, debounced Sonnet analysis, InsightCard management, EventReporter observability, and proper deinit cleanup

## How It Works

### File Watching (DispatchSource)

Uses a kernel-level `DispatchSource.makeFileSystemObjectSource` on `feedback.jsonl`'s file descriptor with `.write` event mask. When FeedbackStore appends a new line, the OS notifies AnalysisEngine immediately — zero polling overhead.

```
feedback.jsonl write event → onFeedbackFileChanged()
  → count new lines (current - lastLineCount)
  → accumulate in pendingNewCount
  → scheduleDebounce()
```

### Debounce + Minimum Threshold

- **Debounce:** 30 seconds after the last write event (prevents rapid re-analysis during a burst of accepted drafts)
- **Minimum:** 5 new entries required before triggering analysis
- **Implementation:** `debounceTask` is a cancellable `Task` with `Task.sleep` — each new write event cancels and restarts it

### Analysis Flow

```
scheduleDebounce() → [30s] → runAnalysis(newEntryCount:)
  → buildAnalysisSystemPrompt()     ← injects feedback + prompts + style + suggestion log
  → callAPIWithToolUse()            ← Sonnet with propose_prompt_change tool
  → InsightCards added to @Published insights array
  → AgentSection displays cards with Apply/Skip buttons
```

### System Prompt Construction

`buildAnalysisSystemPrompt()` assembles context from four files:

| Source | Tag | Limit | Purpose |
|--------|-----|-------|---------|
| feedback.jsonl | `<feedback_jsonl>` | Last 50 lines | Raw/drafted/accepted text diffs |
| prompts.json | `<prompts_json>` | Full file | Current prompt values |
| style.md | `<style_profile>` | Full file | Current style profile |
| suggestion_log.jsonl | `<suggestion_log_jsonl>` | Last 20 lines | Previously applied/skipped suggestions |

The suggestion log prevents re-proposing recently skipped changes.

### Tool Use Loop

`callAPIWithToolUse()` implements a multi-turn conversation with Sonnet:

1. Send user message + system prompt + `propose_prompt_change` tool definition
2. Parse response for `tool_use` blocks → create `InsightCard` via `InsightCard.from()`
3. Feed `tool_result` messages back for next turn
4. Loop up to `maxTurns: 3` (or until `stop_reason == "end_turn"` or no tool calls)

Uses `AnthropicAPI.sonnetModel` for the model and `JSONSerialization` for the request body (tool use requires mixed-type arrays that `Codable` can't handle cleanly).

Analysis failures are logged via both `print("⚠️ ANALYSIS | analysis failed: ...")` and `EventReporter.shared.capture(level: .error, engine: "analysis", event: "analysis_failed", ...)` — makes debugging visible in both console and `events.jsonl` when the API call fails.

### Apply / Skip Actions

| Action | What Happens |
|--------|-------------|
| **Apply** | `writePromptChange()` updates the key in `prompts.json`, posts `.promptsDidChange` notification (PromptStore reloads), logs to `suggestion_log.jsonl` |
| **Skip** | Logs to `suggestion_log.jsonl` only (for meta-learning — Sonnet sees skipped suggestions) |

### InsightCard Shared Tool Definition

`InsightCard.toolDefinition` and `InsightCard.from(toolId:input:)` are defined once in `InsightCard.swift` and shared by both `AnalysisEngine` and `StreamingChatEngine`. This eliminates tool schema duplication — any change to the tool schema propagates to both engines automatically.

## Data Files

All in `~/Library/Application Support/Draft/`:

- **feedback.jsonl** — Append-only log of accepted drafts (written by FeedbackStore, watched by AnalysisEngine)
- **suggestion_log.jsonl** — Append-only log of apply/skip actions with timestamp, suggestion_id, prompt_key, action, saw, and why fields
- **prompts.json** — Current prompt values (read for analysis context, written on Apply)

## Public Interface

```swift
@Published var insights: [InsightCard]   // Cards displayed in AgentSection
@Published var isAnalyzing: Bool         // True during Sonnet API call

var isConnected: Bool       // Always true (native — no subprocess to monitor)
var agentStatus: String     // "Analyzing feedback..." or "Watching for feedback..."

func start()                // Begin watching feedback.jsonl (called by DraftAppState.initialize)
func stop()                 // Stop watching, cancel pending tasks

// deinit cancels fileSource and debounceTask — prevents leaked file descriptor + DispatchSource after dealloc
func addInsight(_ card: InsightCard)  // Add card from external source (StreamingChatEngine passthrough)
func apply(_ card: InsightCard)       // Write change to prompts.json + notify
func skip(_ card: InsightCard)        // Log skip to suggestion_log.jsonl
```

## Notification: `.promptsDidChange`

Posted when `apply()` writes to `prompts.json`. `DraftAppState` observes this notification and calls `promptStore.reload()` so all engines pick up the new prompt values immediately.

## Verification

After modifying AnalysisEngine, verify with these checks:

- **File watching:** Accept 5+ drafts → check debug log for analysis trigger after ~30s debounce
- **InsightCards appear:** After analysis completes, AgentSection should show cards with Apply/Skip buttons
- **Apply works:** Click Apply on a card → check `prompts.json` for the updated key → check `suggestion_log.jsonl` for the apply entry
- **Skip logged:** Click Skip → check `suggestion_log.jsonl` for the skip entry with rationale
- **No startup trigger:** Relaunch app with existing feedback.jsonl → should NOT trigger analysis on startup (only new entries count)
- **Debounce:** Accept drafts rapidly → analysis should fire once ~30s after the last accept, not per-draft
- **Build:** `bash build.sh` — must compile cleanly
