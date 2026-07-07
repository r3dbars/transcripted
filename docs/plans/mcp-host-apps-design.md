# MCP Apps for Transcripted — Design & Feasibility

Scope: the ask was "look into how we could make this app have MCP apps as an option — that
would be very impactful." Transcripted already ships an MCP *server*. This doc sharpens
"MCP apps" into three concrete interpretations, grounds each in the actual code and security
posture, and recommends what to build and in what order. It is a design deliverable, not an
implementation — the phased plan is what a follow-up build thread would execute.

Everything here is checked against the source. File:line citations are to
`/Users/redbars/transcripted` at `origin/main` (HEAD `17601969`).

---

## Executive summary

Transcripted's existing MCP surface points **outward as a server**: `Tools/TranscriptedMCP`
exposes nine read-only tools (`ToolHandlers.swift:24-236`) over stdio, and the app one-click
registers that server into Claude Desktop, Claude Code, Codex, and Cursor
(`AgentMCPConnector.swift:7-32`). The user's own agent does the thinking; Transcripted feeds
it local meeting data. That loop works and is the product's spine.

"MCP apps as an option" is therefore almost certainly *not* "add a server." It's one of:

1. **Transcripted as an MCP host/client** — the app connects *out* to external MCP servers
   ("apps") so its own intelligence and the meeting workflow can pull context from or push
   actions to third-party tools (calendar, task manager, CRM, notes).
2. **MCP Apps (SEP-1865)** — extend the *existing* server so its tools return interactive
   `ui://` surfaces that render inline inside Claude/ChatGPT (a real, shipped MCP extension as
   of 2026-01-26).
3. **One-click distribution** — make "add Transcripted to your agent" even more app-like.
   Mostly already built (`AgentMCPConnector`), so this is polish, not a project.

**Recommendation: sequence 2 → 1, treat 3 as ongoing polish.**

- **Ship Interpretation 2 first (MCP Apps on the existing server).** Highest value-to-risk
  ratio by a wide margin. It amplifies the loop that already works, reuses `Tools/TranscriptedMCP`
  almost entirely, stays *inside the trust boundary the user already opted into* (the agent
  they connected), and needs **no in-app agent loop and no new content egress**. It's the
  fastest way to make Transcripted feel like an "app" inside the agents people already use.
- **Then pursue Interpretation 1 (MCP host) as the strategic bet — but only in its
  egress-gated form.** This is the identity-level change ("capture tool that feeds agents" →
  "local hub that orchestrates the meeting workflow"), and it is what "very impactful" most
  likely gestures at. But its naive framing — *pull arbitrary CRM/calendar context into
  on-device summaries* — is the **highest-risk, worst-fit** version: it requires building a
  tool-use agent loop the app deliberately does not have today, and it sends meeting content
  to remote servers, which is the single sharpest break from the "your content never leaves
  this Mac" promise. Build the defensible slice first: **push meeting outputs to one
  user-consented tool**, local/stdio servers before remote, every server an explicit,
  per-server egress boundary.

The technical runway is unusually good: the app is **not sandboxed**
(`config/entitlements/beta.plist:6-7`), the distribution build already carries
`network.client` (`beta.plist:8-9`), and the exact MCP Swift SDK the server already
vendors ships a full **`Client`** and `HTTPClientTransport` (swift-sdk 0.12.0,
`Sources/MCP/Client/Client.swift`). The hard parts are **product and trust**, not plumbing.

---

## Part 1 — Ground truth: what exists today

### 1.1 The existing MCP server (outbound-as-server)

- Standalone SPM package `Tools/TranscriptedMCP`, its own `Package.swift`, depends on the
  official MCP Swift SDK pinned `exact: "0.12.0"` and on the shared `TranscriptedCaptureKit`
  (`Tools/TranscriptedMCP/Package.swift:8-9`).
- `@main` resolves data dirs, builds a SQLite index, starts file watchers, then serves over
  **stdio** (`Main.swift:58-71`; `StdioTransport()` at `:69`). Transport is stdio, not HTTP
  (`README.md:199`).
- **Nine read-only tools**, all annotated `readOnlyHint: true`
  (`ToolHandlers.swift:24-236`): `list_meetings`, `read_meeting`, `list_dictations`,
  `read_dictation`, `search`, `search_context`, `recent_context`, `who_is`, `recap`. (Note:
  earlier ideas like `get_timeline`/`digest`/"receipt" tools are *not* in the code — the shipped
  set is these nine.)
- Reads the same capture library the app writes, via the shared
  `CaptureLibraryResolver` (`Tools/TranscriptedMCP/Sources/TranscriptedMCP/DataDirectories.swift`),
  default `~/Library/Application Support/Transcripted/captures/{meetings,dictations}`.
- Path reads are traversal/symlink-guarded (`PathSecurity.swift`). No compile-time dependency
  on the app target (`Tools/TranscriptedMCP/README.md:164`).

### 1.2 How the app already integrates agents (one-click connect)

- `Sources/Support/AgentMCPConnector.swift` supports four agents — `claudeDesktop`,
  `claudeCode`, `codex`, `cursor` (`:7-32`) — and writes each one's config: Claude Code via
  `claude mcp add --scope user`, Codex via a conservative TOML edit of `~/.codex/config.toml`,
  Cursor/Claude Desktop via a safe `mcpServers` JSON merge.
- `Sources/Support/ClaudeDesktopIntegrationInstaller.swift` copies the bundled helper
  (`Transcripted.app/Contents/Helpers/transcripted-mcp`) to
  `~/Library/Application Support/Transcripted/mcp/transcripted-mcp` and merges the server
  entry, backing up invalid configs. It is self-healing on launch (`docs/agent-connect.md:55-60`).
- In-app UI already exists: `Sources/UI/Settings/AgentConnectionSettingsPage.swift`, reached
  via the `connectAgent` settings pane (`TranscriptedSettingsPage.swift`, `case connectAgent`).
- Reusable process primitive: `BoundedProcessRunner` — a timeout-bounded `Process` runner
  with drained pipes (`ClaudeDesktopIntegrationInstaller.swift:457`). This is the natural
  substrate for launching a stdio MCP *client* child, too.

### 1.3 Security & privacy posture (the part that governs everything)

- **Not sandboxed.** Both entitlement plists set `com.apple.security.app-sandbox = false`
  (`config/entitlements/local.plist:6-7`, `config/entitlements/beta.plist:6-7`). This is the
  single most important architectural fact for this project: the classic Mac-App-Store problem
  — a sandbox blocking a host app from spawning user-specified stdio MCP binaries (sandbox
  inheritance requires the child use *exactly* `app-sandbox` + `inherit`, which breaks most
  real servers) — **does not apply here.** Transcripted can spawn child processes and open
  sockets freely at the OS level.
- **Outbound network already entitled** in distribution builds:
  `com.apple.security.network.client = true` (`beta.plist:8-9`). Plus `cs.allow-jit` and
  `cs.disable-library-validation` for the MLX/JIT runtime and prebuilt frameworks.
- Distribution is **Developer ID + Hardened Runtime + notarized** (`--options runtime`,
  `xcrun notarytool`, in `scripts/entrypoints/build-beta.sh`).
- **Entitlement drift is policy-gated.** `scripts/ops/nightly-security-check.py` validates
  entitlements against `config/security/nightly-security-manifest.json`. Any change here is a
  deliberate, reviewed change — not a silent one.
- **"Nothing leaves this Mac" is a product promise, not a sandbox guarantee.** Content
  (audio, transcripts, summaries) is processed entirely on-device. But the app already makes
  outbound connections: PostHog telemetry (`AnalyticsReporter.swift`, heavily sanitized —
  `meeting_title`, `path`, `email`, `prompt_text` are on a forbidden-keys list), Sentry crash
  reports (`CrashReporter.swift`), Sparkle updates, and Hugging Face model-weight downloads
  (`ModelDownloadService.swift`, HF is the *only* allowed host). Calendar is local EventKit,
  no cloud sync. So the honest framing is **"we choose not to send your meeting content out,"**
  not "the OS prevents it." Interpretation 1 would create the first deliberate egress of
  meeting *content* — that is the crux to design around, and it is a trust decision, not a
  technical blocker.

### 1.4 The in-app intelligence layer (why Interpretation 1 is bigger than "add a client")

- Summarization is **on-device only**, two providers:
  `LocalMeetingSummaryProvider { gemmaMLX (default), appleFoundation }`
  (`Sources/Support/LocalMeetingSummaryPreferences.swift:3-5`). `gemmaMLX` runs Gemma via a
  bundled Python MLX runner; `appleFoundation` uses Apple's on-device FoundationModels. It is
  **opt-in/beta** (`localMeetingSummaryBetaEnabled` defaults `false`).
- Crucially, this is a **one-shot prompt→text** call. There is **no tool-using agent loop, no
  outbound-tool-call layer** in the app (confirmed: no cloud LLM anywhere in `Sources/`; the
  MCP SDK is linked only inside `Tools/TranscriptedMCP`, not the app target). So "let
  Transcripted's own intelligence call MCP tools" (Interpretation 1's headline framing)
  requires **building the agentic layer that doesn't exist**, then wiring egress on top. That
  is a materially larger and riskier project than "add an MCP client," and it partly competes
  with the app's own "bring your own agent" positioning.

### 1.5 The SDK already gives us the client for free

The MCP Swift SDK 0.12.0 that the server vendors is not server-only. In the vendored checkout:

- `Sources/MCP/Client/Client.swift` — a full `public actor Client` with
  `connect(transport:)`, request/notification handling, batching, and `Sampling` +
  `Elicitation` client capabilities.
- Transports: `StdioTransport`, **`HTTPClientTransport`**, `NetworkTransport`,
  `InMemoryTransport`, plus an `OAuthAuthorizer` for remote-server auth.

So both directions of Interpretation 1 — spawn a **local stdio** MCP server as a child, or
connect to a **remote HTTP/SSE** MCP server — are supported by the same dependency the repo
already builds against. No new transport work.

---

## Part 2 — The three interpretations, scored

| Interpretation | What it means for Transcripted | Value ceiling | Fit with today's architecture | Privacy/trust cost | Build size |
|---|---|---|---|---|---|
| **1. MCP host/client** | App connects out to external MCP "apps"; enrich summaries from / push actions to calendar, tasks, CRM, notes | **High** (identity-level) | **Weak** — needs a new agent loop; competes with "bring your own agent" | **High** — first deliberate egress of meeting content | **L–XL** |
| **2. MCP Apps (SEP-1865)** | Existing server's tools return interactive `ui://` surfaces rendered inline in Claude/ChatGPT | **High** (differentiated UX) | **Strong** — extends the existing server, no app-loop | **Low** — same trust boundary the user already opted into | **M** |
| **3. One-click install** | "Add Transcripted to your agent" as a polished app-add flow | **Low** (mostly done) | **Native** — `AgentMCPConnector` exists | **None** | **S** |

Reads that matter:

- **#2 rides the existing loop.** The server already runs inside the user's agent. MCP Apps
  turns text tool results into an app — an interactive meeting timeline, a searchable
  transcript browser, a "who-said-what" receipt viewer — rendered inline. Content stays local;
  the host only ever shows what the connected agent could already read. This is the
  highest-leverage move because it makes the *existing* value visible and tactile without
  touching the privacy posture.
- **#1 is the ambitious one, and its headline framing is a trap.** "Pull CRM/calendar context
  into the on-device summary" maximizes both the build (new agent loop) and the risk (pull
  remote data + push meeting content out). Its *defensible* form is narrower and still
  valuable: **push structured outputs** (action items, decisions, a recap) to one tool the
  user explicitly connects, preferring local/stdio servers, with every server presented as an
  egress boundary. That slice is a two-way door.
- **#3 is a feature, not a project.** Fold remaining polish (icons, health states, an "MCP
  apps" mental model in copy) into #1/#2 rather than scheduling it separately.

---

## Part 3 — Architecture

### 3.1 Interpretation 2 (MCP Apps) — recommended first

**What changes:** only `Tools/TranscriptedMCP`. Per SEP-1865 (shipped 2026-01-26; supported
by Claude, ChatGPT, VS Code, Goose), a server:

1. Declares UI-capable tools and registers `ui://` HTML resources.
2. Returns, alongside the existing text result, a reference to a `ui://` template.
3. The host renders that HTML in a **sandboxed iframe** and brokers `postMessage`↔JSON-RPC so
   the embedded UI can call back into the same server's tools.

**Where it lives / process model:** unchanged. Still one stdio helper process launched by the
user's agent. The UI is static HTML/JS served *from the helper* as an MCP resource; it runs in
the host's iframe sandbox, not in Transcripted's process. No new entitlements, no new egress —
the helper still only reads the local capture library.

**SDK gap to confirm:** the 0.12.0 pin predates broad MCP Apps support. First build task is a
spike: verify whether 0.12.0 can register `ui://` resources and the apps metadata, or whether
we bump the SDK pin (`Tools/TranscriptedMCP/Package.swift:8`) and/or add the `ext-apps` SDK.
This is the main technical unknown for #2 and is cheap to resolve.

**Candidate first apps** (each maps to an existing tool, so the data path is done):

- *Meeting timeline* over `recap` / `list_meetings` — scrub a day/week, click a meeting to
  expand.
- *Transcript browser* over `read_meeting` + `search` — search box + speaker filter + jump-to.
- *Person card* over `who_is` — the profile as a card instead of a JSON blob.

### 3.2 Interpretation 1 (MCP host) — the strategic bet, egress-gated

**Where the client lives.** A new module — `Sources/MCPHost/` in the app (or a small SPM
target under `Tools/` reused by the app). It links the MCP Swift SDK **`Client`** — the first
real external SPM dependency for the app target, since root `Package.swift` currently has
`dependencies: []` and links everything else as prebuilt archives. Decide deliberately:
add swift-sdk as a normal SPM dep for this module, or vendor it into the deps archive to match
the existing pattern. Recommendation: normal SPM dep, scoped to the new module, to avoid
bloating the prebuilt archive.

**Process model — two connection kinds:**

- **Local stdio server (preferred, machine-local):** spawn the user-specified command as a
  child via the existing `BoundedProcessRunner` pattern
  (`ClaudeDesktopIntegrationInstaller.swift:457`) and drive it with `StdioTransport`. Because
  the app is unsandboxed, this Just Works — no XPC service, no inheritance gymnastics. Prefer
  running the client in a **helper XPC/child process** anyway, so a crashing or hostile server
  can't take down the app or read its address space. This also cleanly bounds what a
  third-party server can touch.
- **Remote HTTP/SSE server:** `HTTPClientTransport` + `OAuthAuthorizer`. Uses the existing
  `network.client` entitlement — no entitlement change for the *connection*. But this is the
  egress boundary: any tool call that includes meeting content is content leaving the Mac.

**Trust model — treat every external server as an untrusted egress boundary:**

- Per-server, per-capability consent. A remote server is off by default and, when enabled,
  labeled "this can receive meeting content you send it."
- **Pull vs push asymmetry.** *Pull* (server → app context, e.g. calendar events into a
  summary) keeps content local and is lower-risk. *Push* (app → server, e.g. action items to a
  task manager) is deliberate egress. Ship *push to one tool* first; gate *pull-into-summary*
  behind the existing summarizer beta flag.
- **No silent tool use.** Since the app has no agent loop today, don't build an open-ended one.
  Start with **explicit, user-triggered actions** ("Send action items to …") rather than an
  autonomous model that decides when to call external tools. An agentic loop, if ever added,
  goes behind `localMeetingSummaryBetaEnabled` and only calls tools from servers the user
  consented to.
- **Redaction reuse.** The egress sanitization discipline already exists for telemetry
  (`AnalyticsPayloadSanitizer`, the manifest forbidden-keys list). Mirror that: a preview of
  exactly what will be sent, before it's sent.
- Update `config/security/nightly-security-manifest.json` and expect the security review;
  don't route around `nightly-security-check.py`.

**The honest tension, stated plainly:** Interpretation 1 makes Transcripted send meeting
content off the Mac for the first time. The mitigation is not "it's fine because we're already
unsandboxed" — it's *architectural consent*: default-off, per-server, push-before-pull,
show-what-leaves, local-servers-first. If that framing is unacceptable for the brand, #1 should
be scoped to **local/stdio servers only** (enrichment that never leaves the machine), which is
still a real and differentiated feature.

### 3.3 What's reusable

| Need | Reuse |
|---|---|
| MCP client + transports + OAuth | swift-sdk 0.12.0, already vendored (`Sources/MCP/Client/Client.swift`, `HTTPClientTransport`) |
| Spawn/drive a stdio server child | `BoundedProcessRunner` (`ClaudeDesktopIntegrationInstaller.swift:457`) |
| Settings pane + navigation | `TranscriptedSettingsPage` enum + `AgentConnectionSettingsPage` pattern |
| Per-server enable/config persistence | `*Preferences` + `@AppStorage` convention; owner-only (`0o600`) config file for secrets, precedent in the agent-config writers |
| Safe config-file merge/backup | `ClaudeDesktopIntegrationInstaller` JSON/TOML merge logic |
| Egress redaction discipline | `AnalyticsPayloadSanitizer` + manifest forbidden-keys pattern |
| Shared capture data + parsing | `TranscriptedCaptureKit` |

### 3.4 UX — how a user adds/manages "MCP apps"

- Home: extend the existing **Connect Agent** pane, or add a sibling **"MCP Apps"** pane
  (`TranscriptedSettingsPage` gains a `case`, sidebar row, and a `switch` arm). The existing
  pane is *outbound-as-server* ("connect your agent to Transcripted"); the new surface is the
  mirror ("connect Transcripted to your apps"). Keeping both on one pane with two clearly
  labeled sections tells the whole story in one place.
- A server list: name, transport (local command / remote URL), health dot (reuse the
  connected-state pattern), enable toggle, and for remote servers an explicit egress label +
  OAuth "Sign in" button.
- "Add" flow: paste a command (local) or URL (remote); the app connects, lists the server's
  tools, and shows exactly which meeting workflow actions become available.
- For #2, no management UI is needed on Transcripted's side — the apps render inside the user's
  agent. The only surface is documentation/onboarding copy in the Connect Agent pane.

---

## Part 4 — Effort, risk, phasing

Sizing is rough order-of-magnitude for a focused build thread.

**Phase 0 — Spikes (S).** (a) Confirm SEP-1865 support path in swift-sdk 0.12.0 vs a bump/
`ext-apps` add. (b) Prototype the app linking `Client` and completing one stdio round-trip to
a throwaway local server. Both are cheap and de-risk the two projects.

**Phase 1 — MCP Apps on the existing server (M).** Ship one `ui://` app (meeting timeline)
end-to-end in Claude Desktop, then add transcript browser + person card. Server-only change;
no app-target risk; no privacy change. **This is the recommended first shippable.**

**Phase 2 — MCP host, defensible slice (M–L).** App links `Client` in a new `MCPHost` module.
Support **local stdio servers** and one **explicit push action** ("send this meeting's action
items to <connected tool>"). Server-management UI + per-server consent + redaction preview.
Default-off. Update the security manifest.

**Phase 3 — Remote servers + pull enrichment (L, gated).** `HTTPClientTransport` + OAuth for
remote MCP apps; optional pull-into-summary behind the summarizer beta flag; the "what leaves
your Mac" consent UX hardened. This is where the brand/privacy decision is fully cashed in —
do it only after Phase 2 validates demand.

**Top risks:**

- *Brand/privacy* (Phase 2–3): first meeting-content egress. Mitigation: default-off,
  per-server, push-before-pull, show-what-leaves, local-first. **Decision needed from Justin.**
- *Scope creep into a general agent* (Phase 3): resist building an autonomous tool-loop;
  keep actions explicit until proven.
- *SDK/version drift* (Phase 1): resolved by Phase 0 spike.
- *Third-party server trust* (Phase 2): run the client in a child/XPC process; never hand a
  remote server more than the current action needs.
- *Maintenance*: each connected server is a support surface; start with a curated short list,
  not "any MCP server."

---

## Part 5 — Open decisions for Justin

1. **Which identity?** Is Transcripted a capture tool that *feeds* the user's agent (today), or
   a local *hub* that also orchestrates the user's other tools (Interpretation 1)? #1 only
   makes sense if the answer is "hub."
2. **Is any meeting-content egress on the table at all?** If no, scope #1 to local/stdio
   servers only. If yes, ratify the consent model in Part 3.2.
3. **Lead with #2 (fast, safe, differentiated) — confirm?** The recommendation assumes yes.
4. **Curated vs open server list** for #1 — ship a short blessed set first, or let users add
   any server from day one?

## Recommendation (one paragraph)

Build **MCP Apps (Interpretation 2)** first: extend the existing `Tools/TranscriptedMCP`
server so its tools return interactive `ui://` surfaces that render inside the agents users
already connect. It's a medium build that reuses nearly everything, changes no entitlements,
creates no new egress, and makes Transcripted's existing value tactile inside Claude/ChatGPT —
the best value-to-risk move on the board. Then pursue **Transcripted-as-MCP-host
(Interpretation 1)** as the larger strategic bet, but in its egress-gated form: start by
*pushing* meeting outputs to one user-consented tool and by connecting to *local* MCP servers
that keep content on the Mac, with every remote server treated as an explicit, default-off
egress boundary. The plumbing is easy here — the app is unsandboxed, already carries
`network.client`, and the vendored MCP SDK already ships a full client and HTTP transport — so
the real work of #1 is the trust architecture and a decision about whether Transcripted's
identity expands from "feeds your agent" to "orchestrates your tools." Treat one-click install
(Interpretation 3) as polish folded into both.
