# Analysis Engine

## What This Does

Native Swift replacement for the Python orchestrator agent. Watches `~/Library/Application Support/Draft/feedback.jsonl` for new accepted drafts, uses the local LLM (Qwen3.5-4B via MLX) to analyze editing patterns, and proposes prompt improvements as InsightCards displayed in AgentSection (menubar panel). Runs entirely in-process — no subprocess, no external API calls, no port conflicts.

## Key Files

- `AnalysisEngine.swift` (~350 lines) — `@MainActor ObservableObject` with DispatchSource file watching, debounced local analysis, InsightCard management, EventReporter observability, and proper deinit cleanup
- `InsightCard.swift` (~51 lines) — Model struct for insight cards + shared `toolDefinition` and `from()` factory (used by AnalysisEngine)

## How It Works

### File Watching (DispatchSource)

Uses a kernel-level `DispatchSource.makeFileSystemObjectSource` on `feedback.jsonl`'s file descriptor with `.write` event mask. When FeedbackStore appends a new line, the OS notifies AnalysisEngine immediately — zero polling overhead.

```
feedback.jsonl write event -> onFeedbackFileChanged()
  -> count new lines (current - lastLineCount)
  -> accumulate in pendingNewCount
  -> scheduleDebounce()
```

### Debounce + Minimum Threshold

- **Debounce:** 30 seconds after the last write event (prevents rapid re-analysis during a burst of accepted drafts)
- **Minimum:** 5 new entries required before triggering analysis
- **Implementation:** `debounceTask` is a cancellable `Task` with `Task.sleep` — each new write event cancels and restarts it

### Analysis Flow

```
scheduleDebounce() -> [30s] -> runAnalysis(newEntryCount:)
  -> buildAnalysisSystemPrompt()     <- injects feedback + prompts + style + suggestion log
  -> MLXEngine.complete()            <- local inference with tool definition in system prompt
  -> Parse JSON InsightCards from response
  -> InsightCards added to @Published insights array
  -> AgentSection displays cards with Apply/Skip buttons
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

### Local Inference with Tool Parsing

AnalysisEngine calls `MLXEngine.complete()` with the `propose_prompt_change` tool definition embedded in the system prompt. The model returns its analysis as JSON-formatted InsightCard proposals, which are parsed from the response text using `InsightCard.from()`.

This is a single-turn completion — no multi-turn tool use loop. The system prompt instructs the model to output structured JSON matching the tool schema, and the response is parsed directly.

Analysis failures are logged via both `print("WARNING ANALYSIS | analysis failed: ...")` and `EventReporter.shared.capture(level: .error, engine: "analysis", event: "analysis_failed", ...)` — makes debugging visible in both console and `events.jsonl` when local inference fails.

### Apply / Skip Actions

| Action | What Happens |
|--------|-------------|
| **Apply** | `writePromptChange()` updates the key in `prompts.json`, posts `.promptsDidChange` notification (PromptStore reloads), logs to `suggestion_log.jsonl` |
| **Skip** | Logs to `suggestion_log.jsonl` only (for meta-learning — the model sees skipped suggestions in future analysis runs) |

### InsightCard Shared Tool Definition

`InsightCard.toolDefinition` and `InsightCard.from(toolId:input:)` are defined once in `InsightCard.swift` and used by `AnalysisEngine`. This keeps the tool schema in a single location.

## Data Files

All in `~/Library/Application Support/Draft/`:

- **feedback.jsonl** — Append-only log of accepted drafts (written by FeedbackStore, watched by AnalysisEngine)
- **suggestion_log.jsonl** — Append-only log of apply/skip actions with timestamp, suggestion_id, prompt_key, action, saw, and why fields
- **prompts.json** — Current prompt values (read for analysis context, written on Apply)

## Public Interface

```swift
@Published var insights: [InsightCard]   // Cards displayed in AgentSection
@Published var isAnalyzing: Bool         // True during local inference

var isConnected: Bool       // Always true (native — no subprocess to monitor)
var agentStatus: String     // "Analyzing feedback..." or "Watching for feedback..."

func start()                // Begin watching feedback.jsonl (called by DraftAppState.initialize)
func stop()                 // Stop watching, cancel pending tasks

// deinit cancels fileSource and debounceTask — prevents leaked file descriptor + DispatchSource after dealloc
func addInsight(_ card: InsightCard)  // Add card from external source
func apply(_ card: InsightCard)       // Write change to prompts.json + notify
func skip(_ card: InsightCard)        // Log skip to suggestion_log.jsonl
```

## Notification: `.promptsDidChange`

Posted when `apply()` writes to `prompts.json`. `DraftAppState` observes this notification and calls `promptStore.reload()` so all engines pick up the new prompt values immediately.

## Verification

After modifying AnalysisEngine, verify with these checks:

- **File watching:** Accept 5+ drafts -> check debug log for analysis trigger after ~30s debounce
- **InsightCards appear:** After analysis completes, AgentSection should show cards with Apply/Skip buttons
- **Apply works:** Click Apply on a card -> check `prompts.json` for the updated key -> check `suggestion_log.jsonl` for the apply entry
- **Skip logged:** Click Skip -> check `suggestion_log.jsonl` for the skip entry with rationale
- **No startup trigger:** Relaunch app with existing feedback.jsonl -> should NOT trigger analysis on startup (only new entries count)
- **Debounce:** Accept drafts rapidly -> analysis should fire once ~30s after the last accept, not per-draft
- **Build:** `bash build.sh` — must compile cleanly
