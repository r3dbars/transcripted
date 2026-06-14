# Strategy synthesis — what to do next (2026-06-14)

Capstone over three deep dives:

- [agent-loop-activation-2026-06-14.md](agent-loop-activation-2026-06-14.md) — the moat (product)
- [growth-positioning-2026-06-14.md](growth-positioning-2026-06-14.md) — the position (market)
- [codebase-architecture-health-2026-06-14.md](codebase-architecture-health-2026-06-14.md) — the foundation (engineering)

## The one-line answer

**The moat, the pitch, and the one big refactor you owe are the same project: turn Transcripted into agent-memory across your whole history, and make that connection the hero of the product.**

All three reports point at the same arrow, from three directions.

## The convergence

| | Says | Implication |
|---|---|---|
| Product (#1) | Plumbing is strong, but "ask my history" across meetings barely exists — lexical FTS5 only, `recap` returns raw lines, and the summarizer already extracts Decisions/Action Items/Open Questions that are **never indexed**. The moat *inverts* as the library grows. | Build cross-meeting intelligence. Most of the raw material already exists. |
| Market (#2) | The only defensible position is "memory for your AI agent." Don't fight Granola on AI-notes ($125M / $1.5B). #1 move: make the MCP/agent connection the **hero feature**, not a settings footnote. | The pitch IS the agent loop. The local-summary beta as a *product* is a trap. |
| Foundation (#3) | Health B. Clean bones, but four god objects are the velocity tax. The worst is `TranscriptedSettingsView.swift` (4503 LOC, 187 commits) — and the agent-connect UI lives inside it. | The moat work is mostly in clean code. The one exception is exactly the positioning move. |

### The two collisions that decide sequencing

1. **The summary paradox, reconciled.** #2 says the Gemma AI-notes beta is a trap *as a destination product*. #1 says the summary *extraction* (Decisions / Action Items / Open Questions) is gold *if you index it*. Both are right: **keep the extraction, drop the notes-product ambition, point its output into the index.** Same code, opposite framing — feed the agent, don't compete with it.

2. **The hero move is trapped in the worst god object.** #2's highest-value UX move (hero-ize the agent connection) lands in `TranscriptedSettingsView.swift`, which is #3's #1 refactor target. So that refactor isn't "tech debt we'll get to" — it's **on the critical path of the headline bet.**

## The plan (sequenced)

### Phase 0 — cheap wins, this week
- `recap` summary-aware: prefer the in-file summary block over raw transcript lines. **[S]** — instant quality jump on the most "ask-my-history"-shaped tool.
- Core-formatter ⇄ CaptureKit-parser **agreement test**. **[S]** — free insurance before any index/format work; today the two sides are only kept in sync by a "remember to update both" doc note.
- Re-hero positioning copy around "memory for your AI agent"; demote free/local/OSS to the proof line. **[S]** — runs in parallel, it's a decision not a build.

### Phase 1 — build the moat (mostly in clean code)
- **Index the structured summary fields** into SQLite. **[M, no new ML]** — the single biggest unlock; it's wiring, not machine learning.
- Add cross-meeting MCP tools: `list_action_items`, `list_decisions`, `digest`. **[M]**
- **Always-on cheap extraction at save time** so cross-meeting tools aren't gated on the 12GB+ opt-in summarizer. Touches the meeting save path (god object #2) and the Core summarizer — this is where product work meets debt and where model choice matters.
- **Local semantic search** over utterances + summaries (bundle a small embedding model + vector table). **[L]** — closes the paraphrase gap where cloud RAG wins, while staying local.

### Phase 2 — hero-ize the connection (requires the refactor)
- **Decompose `TranscriptedSettingsView` + unify the Home/Settings split-brain.** **[L, very high payoff]** — kills the #1 and #4 change-magnets and unblocks the next move.
- Make MCP/agent connect the most polished, most documented path in the product. **[M]**

### Phase 3 — go to market (only after the demo is real)
- Show HN with the agent-memory framing (NOT "local transcription app"), seeded into r/LocalLLaMA, r/ClaudeAI, r/ObsidianMD, MCP/Claude-Code communities, with a ready "how this differs from macparakeet/Granola" answer. **[S, spiky]**

## Don't do
- **Don't launch before the cross-meeting demo works** — you'd be launching a moat that inverts with scale.
- **Don't build a Granola-style AI-notes product.** The agent writes the summary from the files, for free. Building it dilutes the one winning sentence and half-competes with your own pitch.
- **Don't paywall transcription or privacy.** If money is ever needed, the only fitting model is a paid Team tier (E2EE sync + shared speaker dictionary + org policy) — open-core on the *collaboration* surface, never the *privacy* surface.

## Open flags before committing
- **Live metrics not pulled.** No current GitHub star / download numbers were gathered (activation-lane doc warns to keep live-release truth separate from source). Check real numbers before any launch-timing call.
- **Window is contested.** Granola and Plaud both shipped MCP servers in 2026. The agent-memory seam is open but not indefinitely.
- **Model strategy is now on the critical path.** Two Phase-1 builds are model decisions — the always-on extraction model (Apple Foundation Models on macOS 26? small local LLM?) and the bundled embedding model for semantic search. Worth its own deep dive.
- **Swift 6 / strict concurrency is deferred debt.** 19 `@unchecked Sendable` are hand-audited, not compiler-checked. Gate the migration behind the god-object refactors or it's brutal.
