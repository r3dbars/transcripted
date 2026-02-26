# Draft — Voice-to-Text → Polished Message

## What This Is

A macOS utility that captures rough spoken (or typed) thoughts and uses Claude Haiku to polish them into well-crafted messages matching the user's personal writing style. Features a floating overlay UI (non-activating NSPanel), global hotkey screen capture for full conversation context extraction, token-by-token streaming, and platform-aware formatting. Built with SwiftUI, Apple Speech Framework, and the Anthropic Messages API.

## Architecture

```
Sources/
├── DraftApp.swift           ← @main entry point only
├── DraftAppState.swift      ← Centralized engine ownership (lives in AppDelegate, survives window cycles)
├── Speech/                  ← WhisperEngine (batch transcription) + ParakeetEngine (CoreML alt) + STTRouter
├── API/                     ← Anthropic API client (text + vision + streaming) + AuthCredential + Keychain
├── Draft/                   ← DraftEngine + PlatformFormatter — orchestrates drafting (v1 interface)
├── Style/                   ← StyleEngine — learns user's writing voice + onboarding
├── Prompts/                 ← PromptStore — externalized prompts (prompts.json)
├── Feedback/                ← FeedbackStore — accept/edit signal logging (feedback.jsonl)
├── Messages/                ← iMessage database reader (SQLite, onboarding import)
├── Capture/                 ← Screen capture, context extraction, hotkey registration, three-way routing
├── Analysis/                ← AnalysisEngine — native Swift feedback analyzer (replaces Python agent)
├── Observability/           ← EventReporter — centralized error/warning/info tracking (events.jsonl)
└── UI/                      ← Floating overlay (6 files), MenuBarPanel, onboarding, Agent tab
agent/                       ← ⚠️ DEPRECATED — Python orchestrator replaced by Sources/Analysis/
```

**Each subfolder in Sources/ has its own CLAUDE.md with component-specific knowledge. Read the relevant CLAUDE.md before modifying any file in that folder.**

## Build & Run

```bash
cd /Users/****/Draft
bash build.sh
```

This compiles all Swift files from `Sources/`, signs the app bundle, and launches it.

## Key Features

- **Floating overlay UI** — Non-activating NSPanel appears over the user's current app; target app stays frontmost so paste works without re-activation
- **Voice-to-text** — Speak rough thoughts, Draft polishes them via Haiku with token-by-token streaming
- **Full conversation context** — Option+Space screenshots the current app, Haiku Vision extracts the entire visible conversation thread (all messages, participants, platform, formality)
- **Platform-aware formatting** — Detects Slack/iMessage/email/Discord/Teams and adjusts drafting style (e.g., no subject lines for Slack, casual for iMessage)
- **Style learning** — Every accepted draft saves a training pair (AI output vs. what you actually sent); Sonnet incrementally refines your style profile with graduated frequency
- **Style onboarding** — New users can import iMessages automatically (recommended) or paste samples manually; Sonnet builds an immediate style profile (no cold start)
- **Combined onboarding** — iMessage import path includes optional "Add Slack, email, or other writing samples" section to supplement with additional sources for a richer profile
- **iMessage import** — Optional onboarding path that reads `~/Library/Messages/chat.db` for zero-effort style profile generation (requires Full Disk Access)
- **Paste to source app** — Injects the polished message into the exact app that was screenshotted, with clipboard save/restore
- **Frictionless keyboard flow** — ⌥D to start draft → speak → ⌥D to draft → Enter to inject → Escape to cancel at any time. ⌥Space for dictation → speak → ⌥Space to paste. No clicking required
- **Native analysis engine** — Swift-native AnalysisEngine watches feedback via DispatchSource, uses Sonnet to analyze patterns, and proposes prompt improvements as InsightCards in the Agent tab
- **Reliability hardened** — All force-unwraps guarded, stale Tasks cancelled before replacement, deinits on all engines (Carbon hotkeys, audio engine, file watchers), NSLock-batched audio samples, global Escape monitor, streaming state guards
- **Observability** — `EventReporter` captures 35 structured events across all 12 engines to `events.jsonl`. See "Diagnosing Issues" below.

## Diagnosing Issues (When Something Weird Happens)

When the user reports something went wrong, broke, or felt off — **always check `events.jsonl` first.** This is the structured event log that captures every error, warning, and notable event across the entire app.

### Step 1: Check recent errors

```bash
# Last 50 events, errors only
tail -50 ~/Library/Application\ Support/Draft/events.jsonl | grep '"level":"error"'

# Last 50 events, errors AND warnings
tail -50 ~/Library/Application\ Support/Draft/events.jsonl | grep -E '"level":"(error|warning)"'
```

### Step 2: Check a specific engine

If the user describes the problem area (e.g., "voice didn't work", "draft was weird", "nothing happened when I pressed the hotkey"), filter by engine:

| User says | Engine to check |
|-----------|----------------|
| "Voice/mic didn't work" | `whisper`, `speech` |
| "Draft was bad/empty/refused" | `overlay`, `draft` |
| "Nothing happened on hotkey" | `capture`, `overlay` |
| "API error / auth issue" | `anthropic`, `draft` |
| "Style seems off" | `style` |
| "Paste didn't work" | `overlay` |
| "Screen capture failed" | `capture` |

```bash
grep '"engine":"whisper"' ~/Library/Application\ Support/Draft/events.jsonl | tail -20
```

### Step 3: Check the debug log for timeline

`events.jsonl` gives structured data; the debug log gives the full narrative:

```bash
tail -200 ~/draft-debug.log | grep -E "SESSION|WHISPER|VISION|STYLE|DICTATION"
```

### Step 4: Cross-reference and diagnose

Read both logs together. Common patterns:

| events.jsonl event | Likely cause | Fix direction |
|--------------------|-------------|---------------|
| `prewarm_failed` | Audio device issue or model missing | Check mic permissions, re-download model |
| `api_http_error` + status 401 | Auth expired | Regenerate API key or subscription token |
| `api_http_error` + status 529 | Anthropic overloaded | Transient — retry |
| `vision_timeout` | Slow network or complex screenshot | Increase timeout or check network |
| `draft_empty` | API returned nothing | Check prompt, check auth |
| `stream_draft_failed` | Network interruption during streaming | Check connectivity |
| `refusal_detected` | Claude refused to ghostwrite | Check prompt for missing context signals |
| `subscription_expired` | OAuth token expired | Run `claude setup-token` and update |
| `style_refinement_failed` | Sonnet call failed during refinement | Check auth and API status |
| `mic_not_authorized` | User revoked mic permission at runtime | Re-grant in System Settings |

### Step 5: Suggest a fix or investigate further

After identifying the error, either:
- **Fix it directly** if the cause is clear (code change, prompt tweak, permission issue)
- **Read the relevant CLAUDE.md** in the engine's `Sources/` subfolder for component-specific knowledge
- **Read the source file** at the capture point to understand the full error handling path

### Event File Location

```
~/Library/Application Support/Draft/events.jsonl    ← Structured errors/warnings/info (JSONL)
~/draft-debug.log                                    ← Narrative action log (text)
~/Library/Application Support/Draft/feedback.jsonl   ← Accepted draft training pairs
~/Library/Application Support/Draft/style.md         ← Current style profile
~/Library/Application Support/Draft/prompts.json     ← Current prompt values
```

## End-to-End Data Flow

### Hotkey → Draft → Inject Pipeline (v2 — Floating Overlay)

```
1. User presses ⌥D in Slack/iMessage/etc. (draft mode)
   │
   ├─→ [SYNC in C callback] Capture frontApp + screenshot (before focus shifts)
   │
   └─→ [MainActor] DraftSessionController.startSession(imageData:sourceApp:)
       │
       ├─→ Show floating overlay (listening state, waveform animation)
       │
       ├─→ [PARALLEL A] Start voice recording (STTRouter.startRecording())
       │                 └─→ User speaks instructions while vision processes
       │                 └─→ Live transcription shown in overlay
       │
       └─→ [PARALLEL B] Vision processing (stored as visionTask)
                         └─→ AnthropicAPI.withTimeout(seconds: 8) {
                               extractStructuredContext(imageData)
                             }
                         └─→ Returns CapturedContext → stored as lastCapturedContext

2. User presses ⌥D again → stopSessionAndDraft()
   │
   ├─→ Stop voice recording → get voiceText
   ├─→ await visionTask?.value  ← waits for vision to complete (or 8s timeout)
   ├─→ Build prompt: CapturedContext.draftingPrompt(userInstructions:)
   ├─→ StyleEngine.buildSystemPrompt() + PlatformFormatter.formattingInstructions
   └─→ AnthropicAPI.streamDraft() → tokens stream into overlay in real-time
       └─→ Overlay transitions: listening → drafting → streaming → review
       └─→ Auto-focus: TextEditor receives keyboard focus via @FocusState

3. User reviews draft in overlay (editable TextEditor)
   │
   ├─→ Enter → confirmAndInject()
   │   ├─→ Hide overlay
   │   ├─→ pasteWithClipboardRestore() → save clipboard, set draft, ⌘V, restore after 500ms
   │   ├─→ styleEngine.recordExample(aiDraft:, userFinal:, platform:)
   │   ├─→ feedbackStore.record() → append to feedback.jsonl
   │   └─→ shouldRefineNow() → maybe trigger Sonnet refinement
   │
   ├─→ Escape → cancelSession() → shake animation + hide overlay, discard draft
   │
   └─→ ⌥D → cancelSession() → shake animation + hide overlay, discard draft
```

### No-Context Fallback

If vision times out (> 8s) or fails, the fallback prompt asks Claude to "clean up and polish the dictation" rather than "write a reply" — the latter confuses Claude when there's no conversation context.

### Refusal Detection

`looksLikeRefusal()` checks if a draft contains phrases like "I need the actual message" or "could you provide". If detected, the training pair is NOT recorded to prevent poisoning the style profile.

## Common Modifications Playbook

### To add a new messaging platform (e.g., LinkedIn):

1. **`Sources/Draft/PlatformFormatter.swift`** — Add `case linkedin` to the enum, add bundle ID in `detect()`, add `formattingInstructions` for the platform, add `postProcess()` rules if markdown needs fixing
2. **`Sources/Draft/CLAUDE.md`** — Add to the bundle ID mapping table
3. **Test** — Open the target app, capture with ⌥Space, verify platform detection in debug log

### To add new metadata to training pairs:

1. **`Sources/Style/StyleEngine.swift`** — Add the field to the `exampleBlock` string in `recordExample()`, update `extractRecentEditDistances()` if it's a parseable metric
2. **`Sources/UI/DraftSessionController.swift`** — Pass the new data into `recordExample()` from `confirmAndInject()`
3. **`Sources/Style/StyleEngine.swift`** — Update `buildRefinementPrompt()` to tell Sonnet about the new field
4. **`Sources/Style/CLAUDE.md`** — Update the file format example

### To change the refinement logic:

1. **`Sources/Style/StyleEngine.swift`** — Modify `shouldRefineNow()` for frequency, `extractRecentExamplesText(last:)` for window size, `buildRefinementPrompt()` for what Sonnet sees
2. **`Sources/UI/DraftSessionController.swift`** — The call site in `confirmAndInject()` calls `shouldRefineNow()` — usually no changes needed here

### To modify the vision extraction prompt:

1. **`~/Library/Application Support/Draft/prompts.json`** — Edit the `context_extraction` key directly (or let the analysis engine do it). Preserve `{USER_NAME}` and `{APP_NAME}` placeholders.
2. **`Sources/Prompts/PromptStore.swift`** — If changing placeholders or adding new ones, update `contextExtractionPrompt(userName:appName:)` and `DefaultPrompts.contextExtraction`.
3. **`Sources/Capture/CapturedContext.swift`** — If adding new labeled fields, update `parse()` and the struct properties
4. **`Sources/Capture/CLAUDE.md`** — Update CapturedContext struct docs

### To modify the overlay UI:

1. **`Sources/UI/OverlayContentView.swift`** — SwiftUI views for all 5 overlay states
2. **`Sources/UI/FloatingOverlayController.swift`** — State machine, animations, panel lifecycle
3. **`Sources/UI/DraftSessionController.swift`** — Session orchestration (draft + dictation flows)
4. **`Sources/UI/CLAUDE.md`** — Document any new states, views, or behaviors
5. **Test** — Full flow: ⌥D → speak → ⌥D → stream → Enter → paste. Verify auto-focus, Enter/Escape, and cancel behavior.

## Git & GitHub

Before committing or pushing, always switch to the **r3dbars** GitHub account:
```bash
gh auth switch --user r3dbars
```
Repo-level git config is already set (`user.name: r3dbars`, `user.email: r3dbars@users.noreply.github.com`). The auth switch ensures push credentials match.

A `/push` slash command is available (`.claude/commands/push.md`) that handles the full flow: auth switch → stage → commit → push.

## Key Decisions

- **Single binary, no Xcode project** — compiled with `swiftc` directly via `build.sh`
- **Zero third-party dependencies** — only Apple frameworks and URLSession for HTTP
- **Credentials in macOS Keychain** — not UserDefaults, not hardcoded, not env vars
- **Two auth modes supported** — API key (`x-api-key`) OR Claude subscription token (`Authorization: Bearer`) via `AuthCredential` enum. See `Sources/API/CLAUDE.md`.
- **Sandbox disabled** (`com.apple.security.app-sandbox: false`) — required for microphone + screen capture
- **Carbon RegisterEventHotKey** for global hotkey — OS-level interception, works in any app
- **Synchronous screenshot in hotkey callback** — captures frontmost app + screenshot before window focus shifts to Draft
- **Non-activating NSPanel** — the floating overlay doesn't steal focus from the target app, so paste-back works without re-activation
- **Token-by-token streaming** — `AnthropicAPI.streamDraft()` returns `AsyncThrowingStream<String, Error>`, first token appears ~200ms after request
- **Plain-text vision extraction** — Haiku Vision returns labeled sections (PLATFORM/TALKING TO/FORMALITY/CONVERSATION), parsed by `CapturedContext.parse()`. No JSON — simpler and handles variable-length conversations
- **Source app stored on capture** — The exact `NSRunningApplication` is saved at hotkey time, so paste-back targets the right app even if focus changes
- **Externalized prompts** — All system prompts live in `~/Library/Application Support/Draft/prompts.json`, loaded by `PromptStore`. The analysis engine can rewrite prompts without recompiling. Engines read from `promptStore` with hardcoded fallbacks in `DefaultPrompts`.
- **Feedback logging** — Every accepted draft appends a JSON line to `~/Library/Application Support/Draft/feedback.jsonl` with raw text, AI draft, user's accepted version, action (copy/paste), and example count. The analysis engine reads this to understand which drafts work and which need improvement.
- **Native analysis engine** — Replaced the Python subprocess with Swift-native `AnalysisEngine` using DispatchSource file watching, eliminating subprocess crashes, cold start latency, and port conflicts. See `Sources/Analysis/CLAUDE.md`.
- **Guarded optionals over IUOs** — `DraftSessionController.appState` and `overlayController` are `Optional`, not `!`. Every public method starts with `guard let` to handle pre-wiring hotkey races. Never use implicitly unwrapped optionals for properties set after init.
- **Task cancellation before replacement** — Always `task?.cancel()` before `task = Task { ... }`. Orphaned tasks keep running and writing to shared state.
- **Global Escape monitor** — `NSEvent.addGlobalMonitorForEvents` intercepts Escape during non-key panel states (listening/drafting). Installed when overlay shows, removed on hide. The panel can't receive keyboard events when `allowKeyStatus = false`, so SwiftUI `.onKeyPress` won't fire — the global monitor bridges that gap.
- **NSLock for audio thread ↔ MainActor** — Audio render thread has strict ~10ms deadlines; actor isolation has unpredictable scheduling latency. NSLock provides deterministic ~1μs overhead for the shared sample buffer.
- **Serial dispatch queue for whisper inference** — `whisper_context` is NOT safe for concurrent `whisper_full()` calls (Metal backend shares command buffers). A serial `DispatchQueue` prevents the ggml_abort crash.
- **All engines have deinits** — `ContextCaptureEngine` (Carbon hotkeys), `AnalysisEngine` (DispatchSource + debounce task), `WhisperEngine` (audio engine stop + model free). Missing deinits leak OS-level resources.

## Project-Wide Learnings

> Each Sources/ subfolder has its own CLAUDE.md with component-specific details. Items marked "→ See ..." are summarized here but documented in depth in the subfolder. Cross-cutting items that span multiple components are kept in full.

### Audio & Speech

- **Apple Speech buffer resets are undocumented** — → See `Sources/Speech/CLAUDE.md` § "Critical Gotchas"
- **Pro audio interfaces break SFSpeechRecognizer** — USB interfaces like BEACN Mic (96kHz/4ch) cause error 1110. Fix: force mono tap format. → See `Sources/Speech/CLAUDE.md` § "Critical Gotchas"
- **Whisper model load/unload must guard recording state** — Unloading during Metal inference causes use-after-free. → See `Sources/Speech/CLAUDE.md` § "State Transition Guards"
- **Microphone permission can be revoked at runtime** — Check `AVCaptureDevice.authorizationStatus` before `installTap()`. → See `Sources/Speech/CLAUDE.md` § "Critical Gotchas"

### SwiftUI & AppKit

- **`.onKeyPress` needs the `keys:phases:` variant** — the single-key form `onKeyPress(.return)` doesn't expose modifiers, so you can't distinguish Enter from Shift+Enter. Use `onKeyPress(keys: [.return], phases: .down)` which passes the full `KeyPress` object
- **SwiftUI type-checker has limits** — complex `body` with inline closures can exceed Swift's type-check timeout. Fix: extract views into separate `@ViewBuilder` computed properties
- **`@FocusState` only works in View structs** — cannot be added to `ObservableObject` classes. Must bind with `.focused($isReviewFocused)` on the TextEditor and set `true` in `.onAppear` with a 50ms delay (lets the panel finish becoming key first)
- **Non-activating panels need dynamic key status** — `FloatingOverlayPanel.canBecomeKey` returns a mutable `allowKeyStatus` flag. During listening/drafting it's `false`, during review it's `true`. Without this, either keyboard input or paste-back breaks
- **CoreFoundation `as?` casts always succeed** — Conditional downcasts to CF bridged types (`AXUIElement`, `AXValue`) always succeed at the compiler level. Use `as!` for CF types — it's compiler-guaranteed safe
- **Global event monitors are observe-only** — `NSEvent.addGlobalMonitorForEvents` can see but not consume events. For events that need to be consumed, use Carbon `RegisterEventHotKey` instead
- **Clipboard safety on inject** — `pasteWithClipboardRestore()` saves the user's clipboard, sets the draft text, simulates ⌘V, then restores after 500ms. The non-activating panel means the target app stays frontmost

### API & Auth

- **No official Anthropic Swift SDK** — raw URLSession with Codable + JSONSerialization for vision. → See `Sources/API/CLAUDE.md`
- **Claude subscription auth requires the `oauth-2025-04-20` beta header** — without it, the API rejects OAuth tokens (`sk-ant-oat...`) with a 401. Set automatically by `AuthCredential.apply(to:)`. Users generate tokens via `claude setup-token`. Tokens expire and must be regenerated
- **Auth is abstracted behind `AuthCredential`** — never pass raw `apiKey: String` around. Use `AuthCredential.load()` and `auth.apply(to: &request)`. → See `Sources/API/CLAUDE.md`
- **AnthropicAPI is a thin HTTP client** — model and prompts are passed by callers, not hardcoded. Only `sonnetModel` remains as a constant. → See `Sources/API/CLAUDE.md`

### Vision & Context Capture

- **Global hotkey timing is critical** — screenshot AND frontmost app reference must be captured synchronously in the C callback before any `Task { @MainActor }` dispatch, or window focus shifts and you capture Draft instead of the target app. → See `Sources/Capture/CLAUDE.md`
- **Haiku confuses message content with metadata** — the vision prompt must explicitly say "look at the conversation HEADER/TITLE BAR for the contact name, NOT names mentioned inside messages"
- **Vision race condition requires explicit await** — `stopSessionAndDraft()` must `await visionTask?.value` before reading `lastCapturedContext`. Vision timeout is 8 seconds (4s was too aggressive — typical calls take 2-6s)
- **Hotkey labels in ContextCaptureEngine** — ⌥D = hotkey ID 1 (draft mode), ⌥Space = hotkey ID 2 (dictation mode). Both use signature `0x44524654` ('DRFT'). → See `Sources/Capture/CLAUDE.md`

### Concurrency & Initialization

- **DraftAppState.initialize() is idempotent** — Protected by an `isInitialized` flag. Without the guard, observers stack, analysis engine double-starts, and hotkeys double-register

### Data & iMessage

- **iMessage `text` stores U+FFFC for attachment-only messages** — Filter by `trimmed.count < 2`, not word count. → See `Sources/Messages/CLAUDE.md`
- **Prompts are externalized to JSON** — `PromptStore` reads `prompts.json` on launch. `DefaultPrompts` enum holds hardcoded fallbacks. → See `Sources/Prompts/CLAUDE.md`

### Build System

- **`swiftc` multi-file compilation** — `$(find Sources -name '*.swift')` in build.sh. All files in the module see each other's `internal` types without imports

## Frameworks Linked

- `SwiftUI` — UI
- `AVFoundation` — Audio engine / microphone
- `Speech` — Apple Speech recognition (used by WhisperEngine/ParakeetEngine for live display)
- `Security` — Keychain access
- `AppKit` — macOS-specific (NSPasteboard, NSWorkspace, NSRunningApplication, NSPanel)
- `Carbon` — Global hotkey registration (RegisterEventHotKey)
- `CoreGraphics` — Window capture (CGWindowListCreateImage)
- `Combine` — Required by SwiftUI internally
- `SQLite3` (via `-lsqlite3`) — iMessage database reading for style onboarding
