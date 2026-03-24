# Draft — Voice-to-Text → Polished Message

## What This Is

A macOS utility that captures rough spoken (or typed) thoughts and uses a local LLM (Qwen 3.5-4B via MLX) to polish them into well-crafted messages matching the user's personal writing style. Features a floating overlay UI (non-activating NSPanel), global hotkey screen capture for full conversation context extraction, token-by-token streaming, and platform-aware formatting. Built with pure AppKit (no SwiftUI in the main UI), Apple Speech Framework, and on-device MLX inference — fully local, no external APIs.

## Architecture

```
Sources/
├── DraftApp.swift           ← @main entry point only
├── DraftAppState.swift      ← Centralized engine ownership (lives in AppDelegate, survives window cycles)
├── DraftPaths.swift         ← FileManager extension: draftAppSupportDir (~/Library/Application Support/Draft/)
├── DraftConstants.swift     ← Centralized configuration constants (timeouts, thresholds, limits)
├── HotkeyPreferences.swift  ← Stores/loads custom hotkey bindings (UserDefaults), Carbon modifier conversion, display strings
├── CLAUDE.md                ← Initialization order and boot sequence documentation
├── Speech/                  ← ParakeetEngine (CoreML STT) + STTRouter
├── API/                     ← BetaConfig (#if BETA_BUILD gated) — no API client
├── Draft/                   ← DraftEngine + PlatformFormatter + DraftUtils — orchestrates drafting
├── Style/                   ← StyleEngine + StyleUtils — learns user's writing voice + onboarding
├── Local/                   ← MLXEngine — on-device LLM inference (Qwen 3.5-4B-4bit via mlx-swift-lm)
├── Prompts/                 ← PromptStore — externalized prompts (prompts.json)
├── Feedback/                ← FeedbackStore — accept/edit signal logging (feedback.jsonl) + UsageStats
├── Messages/                ← iMessage database reader (SQLite, onboarding import) + MessageFilter
├── Capture/                 ← Screen capture, context extraction (Apple Vision OCR), hotkey registration, three-way routing, PreviousAppTracker
├── Analysis/                ← AnalysisEngine + InsightCard — native Swift feedback analyzer
├── Accessibility/           ← AccessibilityBridge — AXUIElement queries for text field position + value
├── Observability/           ← EventReporter + AppLogger + JSONLWriter — centralized error/warning/info tracking (events.jsonl)
└── UI/                      ← UI layer (~25 files): pure AppKit floating overlay + menubar panel, SwiftUI onboarding (Phase 3)
Tests/                       ← Pure-function test suite (147 tests, no XCTest, 2s compile+run)
run-tests.sh                 ← Compiles and runs the test suite
```

**Each subfolder in Sources/ has its own CLAUDE.md with component-specific knowledge. Read the relevant CLAUDE.md before modifying any file in that folder.**

## Build & Run

```bash
cd /Users/****/Draft
bash build.sh        # Compile + sign + launch (~5s)
bash run-tests.sh    # Run 159 unit tests (pure functions only, ~2s)
```

**After modifying any Swift file, always run both commands.** `build.sh` compiles all Swift files from `Sources/`, signs the app bundle, and launches it. `run-tests.sh` compiles only the pure source files needed by tests (no SwiftUI/Combine/FluidAudio) — fast and CI-friendly.

## Key Features

- **Fully local inference** — All LLM work runs on-device via MLX (Qwen 3.5-4B-4bit, ~30-50 tok/s). No API keys, no accounts, no network required
- **Floating overlay UI** — Non-activating NSPanel appears over the user's current app; target app stays frontmost so paste works without re-activation
- **Voice-to-text** — Speak rough thoughts, Draft polishes them via the local model with token-by-token streaming
- **Full conversation context** — Option+D screenshots the current app, Apple Vision OCR extracts the entire visible conversation thread (all messages, participants, platform, formality)
- **Platform-aware formatting** — Detects Slack/iMessage/email/Discord/Teams and adjusts drafting style (e.g., no subject lines for Slack, casual for iMessage)
- **Style learning** — Every accepted draft saves a training pair (AI output vs. what you actually sent); MLXEngine incrementally refines your style profile with graduated frequency
- **Style onboarding** — New users can import iMessages automatically (recommended) or paste samples manually; local MLX analysis builds an immediate style profile (no cold start)
- **Combined onboarding** — iMessage import path includes optional "Add Slack, email, or other writing samples" section to supplement with additional sources for a richer profile
- **iMessage import** — Optional onboarding path that reads `~/Library/Messages/chat.db` for zero-effort style profile generation (requires Full Disk Access)
- **Paste to source app** — Injects the polished message into the exact app that was screenshotted, with clipboard save/restore
- **Frictionless keyboard flow** — ⌥D to start draft → speak → ⌥D to draft → Enter to inject → Escape to cancel at any time. ⌥Space for dictation → speak → ⌥Space to paste. No clicking required
- **Menu bar dashboard** — Single-pane menubar popover (440x520) with status, usage stats (words dictated, messages drafted, time saved), shortcut pills, compact/expandable writing style, and agent section (insight cards + chat). System-adaptive colors via `MenuTokens`
- **Native analysis engine** — Swift-native AnalysisEngine watches feedback via DispatchSource, uses the local model to analyze patterns, and proposes prompt improvements as InsightCards in the agent section
- **Reliability hardened** — All force-unwraps guarded, stale Tasks cancelled before replacement, deinits on all engines (Carbon hotkeys, audio engine, file watchers), NSLock-batched audio samples, global Escape monitor, streaming state guards
- **Observability** — `EventReporter` captures 43 structured events across 11 engines to `events.jsonl`. See "Diagnosing Issues" below.

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
| "Voice/mic didn't work" | `parakeet` |
| "Draft was bad/empty/refused" | `overlay`, `draft` |
| "Nothing happened on hotkey" | `capture`, `overlay` |
| "Model failed to load" | `mlx`, `draft` |
| "Style seems off" | `style` |
| "Paste didn't work" | `overlay` |
| "Screen capture failed" | `capture` |

```bash
grep '"engine":"parakeet"' ~/Library/Application\ Support/Draft/events.jsonl | tail -20
```

### Step 3: Check the debug log for timeline

`events.jsonl` gives structured data; the debug log gives the full narrative:

```bash
tail -200 ~/draft-debug.log | grep -E "SESSION|PARAKEET|VISION|STYLE|DICTATION|MLX"
```

### Step 4: Cross-reference and diagnose

Read both logs together. Common patterns:

| events.jsonl event | Likely cause | Fix direction |
|--------------------|-------------|---------------|
| `prewarm_failed` | Audio device issue or model missing | Check mic permissions, re-download model |
| `mlx_load_failed` | Model not downloaded or corrupted | Re-download Qwen model (~2.5GB) |
| `mlx_generate_failed` | Model inference error | Check available memory, restart app |
| `vision_timeout` | Complex screenshot or slow OCR | Increase timeout or simplify capture |
| `draft_empty` | Model returned nothing | Check prompt, check model state |
| `stream_draft_failed` | Model inference interrupted | Check memory pressure, restart app |
| `refusal_detected` | Model refused to ghostwrite | Check prompt for missing context signals |
| `style_refinement_failed` | Local model call failed during refinement | Check model state and memory |
| `mic_not_authorized` | User revoked mic permission at runtime | Re-grant in System Settings |

### Step 5: Suggest a fix or investigate further

After identifying the error, either:
- **Fix it directly** if the cause is clear (code change, prompt tweak, permission issue)
- **Read the relevant CLAUDE.md** in the engine's `Sources/` subfolder for component-specific knowledge
- **Read the source file** at the capture point to understand the full error handling path

### Event File Location

```
~/Library/Application Support/Draft/events.jsonl          ← Structured errors/warnings/info (JSONL)
~/draft-debug.log                                          ← Narrative action log (text)
~/Library/Application Support/Draft/feedback.jsonl         ← Accepted draft training pairs
~/Library/Application Support/Draft/style.md               ← Current style profile
~/Library/Application Support/Draft/prompts.json           ← Current prompt values
~/Library/Application Support/Draft/suggestion_log.jsonl   ← Applied/skipped insight card actions
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
                         └─→ DraftConstants.withTimeout(seconds: 8) {
                               extractStructuredContext(imageData)  // Apple Vision OCR
                             }
                         └─→ Returns CapturedContext → stored as lastCapturedContext

2. User presses ⌥D again → stopSessionAndDraft()
   │
   ├─→ Stop voice recording → get voiceText
   ├─→ await visionTask?.value  ← waits for vision to complete (or 8s timeout)
   ├─→ Build prompt: CapturedContext.draftingPrompt(userInstructions:)
   ├─→ StyleEngine.buildSystemPrompt() + PlatformFormatter.formattingInstructions
   └─→ MLXEngine.generate() → tokens stream into overlay in real-time
       └─→ Overlay transitions: listening → drafting → streaming → review
       └─→ Auto-focus: DraftTextView receives keyboard focus via makeFirstResponder()

3. User reviews draft in overlay (editable TextEditor)
   │
   ├─→ Enter → confirmAndInject()
   │   ├─→ Hide overlay (shrink animation)
   │   ├─→ pasteWithClipboardRestore() → save clipboard, set draft, ⌘V, restore after 500ms
   │   ├─→ looksLikeRefusal() check — skip training if refusal detected
   │   ├─→ styleEngine.recordExample(aiDraft:userFinal:platform:userInstructions:formality:)
   │   ├─→ feedbackStore.record() → append to feedback.jsonl
   │   └─→ shouldRefineNow() → maybe trigger local MLX refinement via regenerateStyleSummary()
   │
   ├─→ Escape → cancelSession() → shake animation + hide overlay, discard draft
   │
   └─→ ⌥D → cancelSession() → shake animation + hide overlay, discard draft
```

### No-Context Fallback

If vision times out (> 8s) or fails, the fallback prompt asks the model to "clean up and polish the dictation" rather than "write a reply" — the latter confuses the model when there's no conversation context.

### Refusal Detection

`looksLikeRefusal()` checks if a draft contains phrases like "I need the actual message" or "could you provide". If detected, the training pair is NOT recorded to prevent poisoning the style profile.

## Common Modifications Playbook

### To add a new messaging platform (e.g., LinkedIn):

1. **`Sources/Draft/PlatformFormatter.swift`** — Add `case linkedin` to the enum, add bundle ID in `detect()`, add `formattingInstructions` for the platform, add `postProcess()` rules if markdown needs fixing
2. **`Sources/Draft/CLAUDE.md`** — Add to the bundle ID mapping table
3. **Test** — Open the target app, capture with ⌥D, verify platform detection in debug log

### To add new metadata to training pairs:

1. **`Sources/Style/StyleEngine.swift`** — Add the field to the `exampleBlock` string in `recordExample()`, update `extractRecentEditDistances()` if it's a parseable metric
2. **`Sources/UI/DraftSessionController.swift`** — Pass the new data into `recordExample()` from `confirmAndInject()`
3. **`Sources/Style/StyleEngine.swift`** — Update `buildRefinementPrompt()` to tell the model about the new field
4. **`Sources/Style/CLAUDE.md`** — Update the file format example

### To change the refinement logic:

1. **`Sources/Style/StyleEngine.swift`** — Modify `shouldRefineNow()` for frequency, `extractRecentExamplesText(last:)` for window size, `buildRefinementPrompt()` for what the model sees
2. **`Sources/UI/DraftSessionController.swift`** — The call site in `confirmAndInject()` calls `shouldRefineNow()` — usually no changes needed here

### To modify the vision extraction prompt:

1. **`~/Library/Application Support/Draft/prompts.json`** — Edit the `context_extraction` key directly (or let the analysis engine do it). Preserve `{USER_NAME}` and `{APP_NAME}` placeholders.
2. **`Sources/Prompts/PromptStore.swift`** — If changing placeholders or adding new ones, update `contextExtractionPrompt(userName:appName:)` and `DefaultPrompts.contextExtraction`.
3. **`Sources/Capture/CapturedContext.swift`** — If adding new labeled fields, update `parse()` and the struct properties
4. **`Sources/Capture/CLAUDE.md`** — Update CapturedContext struct docs

### To modify the overlay UI:

1. **`Sources/UI/OverlayRootView.swift`** — Pure AppKit root view for all 7 overlay states (replaces SwiftUI OverlayContentView)
2. **`Sources/UI/FloatingOverlayController.swift`** — State machine, animations, panel lifecycle
3. **`Sources/UI/DraftSessionController.swift`** — Session orchestration (draft + dictation flows)
4. **`Sources/UI/CLAUDE.md`** — Document any new states, views, or behaviors
5. **Test** — Full flow: ⌥D → speak → ⌥D → stream → Enter → paste. Verify auto-focus, Enter/Escape, and cancel behavior.

### To modify the menubar panel:

1. **`Sources/UI/MenuBarPanel.swift`** — Single-pane ScrollView with sections: header, stats, shortcuts, style, agent. All layout in one file.
2. **`Sources/UI/AgentTab.swift`** — `AgentSection` struct: insight cards (Apply/Skip) + streaming chat. Embedded in MenuBarPanel via composition.
3. **`Sources/UI/OverlayTokens.swift`** — `MenuTokens` enum: system-adaptive colors and layout constants. All menubar panel styling flows through these tokens.
4. **`Sources/Feedback/FeedbackStore.swift`** — `refreshStats()` computes `UsageStats` from `feedback.jsonl`; `@Published var stats` drives the stats section reactively.
5. **`Sources/UI/CLAUDE.md`** — Document any new sections or layout changes
6. **Test** — Open menubar popover, verify stats update on appear, style card expands/collapses, insight cards show Apply/Skip, chat input works, settings gear opens popover.

## Git & GitHub

Before committing or pushing, always switch to the **r3dbars** GitHub account:
```bash
gh auth switch --user r3dbars
```
Repo-level git config is already set (`user.name: r3dbars`, `user.email: r3dbars@users.noreply.github.com`). The auth switch ensures push credentials match.

A `/push` slash command is available (`.claude/commands/push.md`) that handles the full flow: auth switch → stage → commit → push.

## Key Decisions

- **Single binary, no Xcode project** — compiled with `swiftc` directly via `build.sh`
- **Fully local inference** — all LLM work runs on-device via MLX (Qwen 3.5-4B-4bit, ~30-50 tok/s on Apple Silicon). No API keys, no accounts, no network required for core functionality
- **Zero third-party dependencies** — only Apple frameworks + FluidAudio/MLX built from source
- **Sandbox disabled** (`com.apple.security.app-sandbox: false`) — required for microphone + screen capture
- **Carbon RegisterEventHotKey** for global hotkey — OS-level interception, works in any app
- **Synchronous screenshot in hotkey callback** — captures frontmost app + screenshot before window focus shifts to Draft
- **Non-activating NSPanel** — the floating overlay doesn't steal focus from the target app, so paste-back works without re-activation
- **Token-by-token streaming** — `MLXEngine.generate()` returns `AsyncThrowingStream<String, Error>`, first token appears ~200ms after request
- **Apple Vision OCR for context extraction** — `VNRecognizeTextRequest` extracts text from screenshots, parsed by `CapturedContext.parse()` into labeled sections (PLATFORM/TALKING TO/FORMALITY/CONVERSATION). Fully on-device, no cloud OCR
- **Source app stored on capture** — The exact `NSRunningApplication` is saved at hotkey time, so paste-back targets the right app even if focus changes
- **Externalized prompts** — All system prompts live in `~/Library/Application Support/Draft/prompts.json`, loaded by `PromptStore`. The analysis engine can rewrite prompts without recompiling. Engines read from `promptStore` with hardcoded fallbacks in `DefaultPrompts`.
- **Feedback logging + usage stats** — Every accepted draft appends a JSON line to `~/Library/Application Support/Draft/feedback.jsonl` with raw text, AI draft, user's accepted version, action (copy/paste), example count, and formality. `FeedbackStore.refreshStats()` parses the log to compute aggregate usage stats (words dictated, messages drafted, time saved) displayed in the menubar panel.
- **Native analysis engine** — Replaced the Python subprocess with Swift-native `AnalysisEngine` using DispatchSource file watching, eliminating subprocess crashes, cold start latency, and port conflicts. See `Sources/Analysis/CLAUDE.md`.
- **MenuTokens design system** — `MenuTokens` enum in `OverlayTokens.swift` provides system-adaptive colors (using `NSColor` semantic colors like `controlBackgroundColor`, `tertiaryLabelColor`) and layout constants for the menubar panel. No hardcoded brand colors — all colors adapt to light/dark mode automatically. Separate from `OverlayTokens` which uses translucent dark colors for the floating overlay.
- **Single-pane menubar panel** — Replaced the TabView (Style + Agent tabs) with a single ScrollView containing sections: header (status dot), usage stats, shortcut pills, writing style (compact/expandable), and agent (insight cards + chat). `StyleProfileView` is deprecated — style display is inlined in `MenuBarPanel.swift`.
- **Guarded optionals over IUOs** — `DraftSessionController.appState` and `overlayController` are `Optional`, not `!`. Every public method starts with `guard let` to handle pre-wiring hotkey races. Never use implicitly unwrapped optionals for properties set after init.
- **Task cancellation before replacement** — Always `task?.cancel()` before `task = Task { ... }`. Orphaned tasks keep running and writing to shared state.
- **Global Escape monitor** — `NSEvent.addGlobalMonitorForEvents` intercepts Escape during non-key panel states (listening/drafting). Installed when overlay shows, removed on hide. The panel can't receive keyboard events when `allowKeyStatus = false`, so the global monitor bridges that gap. In review mode, `DraftTextView.keyDown()` handles Escape directly via the responder chain.
- **NSLock for audio thread ↔ MainActor** — Audio render thread has strict ~10ms deadlines; actor isolation has unpredictable scheduling latency. NSLock provides deterministic ~1μs overhead for the shared sample buffer.
- **All engines have deinits** — `ContextCaptureEngine` (Carbon hotkeys), `AnalysisEngine` (DispatchSource + debounce task), `ParakeetEngine` (audio engine stop + AsrManager cleanup). Missing deinits leak OS-level resources.
- **Pure AppKit UI (no SwiftUI in overlay or menubar)** — The floating overlay and menubar panel use pure AppKit views (NSView subclasses). This eliminates SwiftUI's AttributeGraph, which accumulated dangling pointers from NSHostingView lifecycle debris and caused EXC_BAD_ACCESS crashes after ~10 hours of use. Controllers hold Combine subscriptions to engine `@Published` properties and push data to views via explicit `update()` methods. Views are dumb renderers with no subscriptions.
- **Intent-first drafting** — System prompt prioritizes accomplishing the user's communicative intent over style mimicry. `<primary_goal>` appears before `<style_profile>`, and style is framed as a "finishing layer" via `<how_to_use_style>`. The user message prompt reinforces this with "accomplish this goal above all else" and an anti-opener rule. See `Sources/Style/CLAUDE.md` § "Application — Ghostwriting System Prompt (Intent-First)".
- **Clipboard restore via changeCount polling** — `pasteWithClipboardRestore()` polls `NSPasteboard.changeCount` every 50ms with a 2-second timeout (some apps write back to clipboard on paste, which triggers early restore). Replaces the old fixed 500ms delay.
- **Debug log rotation** — `AppLogFileWriter` preserves logs across sessions (no wipe on launch). Files over 500KB are rotated to the last 1000 lines. Session separators mark boundaries.
- **Centralized constants** — `DraftConstants` enum in `Sources/DraftConstants.swift` holds timeouts, thresholds, retry delays, buffer sizes, and data limits. Use these instead of inline magic numbers when modifying configuration-like values.
- **Pure-function test suite** — 147 tests in `Tests/` covering CapturedContext, PlatformFormatter, DraftUtils, MessageFilter, StyleUtils, InsightCard, and error types. Compiled with `swiftc` (no Xcode/XCTest dependency), runs in ~2 seconds. **Always run `bash build.sh && bash run-tests.sh` after modifying any Swift file.**
- **Extracted pure utilities for testability** — `StyleUtils`, `DraftUtils`, `MessageFilter` are stateless enums with static methods, extracted from `@MainActor ObservableObject` classes so they can be tested without SwiftUI.

## Project-Wide Learnings

> Each Sources/ subfolder has its own CLAUDE.md with component-specific details. Items marked "→ See ..." are summarized here but documented in depth in the subfolder. Cross-cutting items that span multiple components are kept in full.

### Audio & Speech

- **Apple Speech buffer resets are undocumented** — → See `Sources/Speech/CLAUDE.md` § "Critical Gotchas"
- **Pro audio interfaces break SFSpeechRecognizer** — USB interfaces like BEACN Mic (96kHz/4ch) cause error 1110. Fix: force mono tap format. → See `Sources/Speech/CLAUDE.md` § "Critical Gotchas"
- **Microphone permission can be revoked at runtime** — Check `AVCaptureDevice.authorizationStatus` before `installTap()`. → See `Sources/Speech/CLAUDE.md` § "Critical Gotchas"

### AppKit UI (Post-Rewrite)

- **Pure AppKit overlay and menubar** — No `NSHostingView`, no `AttributeGraph`, no `@Published` observation from views. Controllers hold Combine subscriptions and push data to views via `update()` methods
- **`DraftTextView.keyDown()` for keyboard handling** — NSTextView subclass handles Enter (confirm), Shift+Enter (newline), Escape (cancel) via the responder chain. No `@FocusState`, no `.onKeyPress`
- **`makeFirstResponder()` is synchronous** — No 50ms delay needed for focus transfer. AppKit's responder chain is deterministic
- **Lazy child views, never destroyed** — Content views (listening, drafting, streaming, review) are created on first use and reused across state transitions. No view lifecycle churn
- **Non-activating panels need dynamic key status** — `FloatingOverlayPanel.canBecomeKey` returns a mutable `allowKeyStatus` flag. During listening/drafting it's `false`, during review it's `true`. Without this, either keyboard input or paste-back breaks
- **CoreFoundation `as?` casts always succeed** — Conditional downcasts to CF bridged types (`AXUIElement`, `AXValue`) always succeed at the compiler level. Use `as!` for CF types — it's compiler-guaranteed safe
- **Global event monitors are observe-only** — `NSEvent.addGlobalMonitorForEvents` can see but not consume events. For events that need to be consumed, use Carbon `RegisterEventHotKey` instead
- **Clipboard safety on inject** — `pasteWithClipboardRestore()` saves the user's clipboard, sets the draft text, simulates ⌘V, then restores after 500ms. The non-activating panel means the target app stays frontmost
- **`.onAppear` re-fires when `.id()` changes** — Never mutate the value driving `.id()` inside `.onAppear`, or you get an infinite view recreation loop that starves the main thread

### Local Inference (MLX)

- **MLXEngine is a Swift actor** — wraps mlx-swift-lm for thread-safe model access. See `Sources/Local/CLAUDE.md`
- **Model: `mlx-community/Qwen3.5-4B-4bit`** — downloaded from HuggingFace on first use (~2.5GB), cached at `~/Library/Caches/models/mlx-community/Qwen3.5-4B-4bit/`
- **Thinking mode disabled** — `userInput.additionalContext = ["enable_thinking": false]` to avoid reasoning tokens in output
- **Performance: 30-50 tok/s on Apple Silicon** — sufficient for real-time streaming in the overlay
- **Metal shaders must be colocated** — `mlx.metallib` must be placed next to the binary (`Contents/MacOS/`). MLX searches colocated first

### Vision & Context Capture

- **Global hotkey timing is critical** — screenshot AND frontmost app reference must be captured synchronously in the C callback before any `Task { @MainActor }` dispatch, or window focus shifts and you capture Draft instead of the target app. → See `Sources/Capture/CLAUDE.md`
- **Apple Vision OCR for context extraction** — `VNRecognizeTextRequest` extracts text from screenshots on-device. Results are parsed by `CapturedContext.parse()` into structured sections
- **Vision race condition requires explicit await** — `stopSessionAndDraft()` must `await visionTask?.value` before reading `lastCapturedContext`. Vision timeout is 8 seconds
- **Hotkey labels in ContextCaptureEngine** — ⌥D = hotkey ID 1 (draft mode), ⌥Space = hotkey ID 2 (dictation mode). Both use signature `0x44524654` ('DRFT'). → See `Sources/Capture/CLAUDE.md`

### Concurrency & Initialization

- **DraftAppState.initialize() is idempotent** — Protected by an `isInitialized` flag. Without the guard, observers stack, analysis engine double-starts, and hotkeys double-register

### Data & iMessage

- **iMessage `text` stores U+FFFC for attachment-only messages** — Filter by `trimmed.count < 2`, not word count. → See `Sources/Messages/CLAUDE.md`
- **Prompts are externalized to JSON** — `PromptStore` reads `prompts.json` on launch. `DefaultPrompts` enum holds hardcoded fallbacks. → See `Sources/Prompts/CLAUDE.md`

### Build System

- **`swiftc` multi-file compilation** — `$(find Sources -name '*.swift')` in build.sh. All files in the module see each other's `internal` types without imports

## Frameworks Linked

- `SwiftUI` — Minimal: app entry point (`@main struct DraftApp: App`) + onboarding views only
- `AVFoundation` — Audio engine / microphone
- `Speech` — Apple Speech recognition (used by ParakeetEngine for live display)
- `Vision` — Apple Vision framework (VNRecognizeTextRequest for OCR context extraction)
- `AppKit` — macOS-specific (NSPasteboard, NSWorkspace, NSRunningApplication, NSPanel)
- `ApplicationServices` — Accessibility API (AXUIElement queries in AccessibilityBridge)
- `Carbon` — Global hotkey registration (RegisterEventHotKey)
- `CoreGraphics` — Window capture (CGWindowListCreateImage)
- `CoreML` — FluidAudio Parakeet model inference
- `CoreAudio` — Audio device queries (input device name via AudioObjectGetPropertyData)
- `Combine` — Engine @Published properties + controller subscriptions for AppKit view updates
- `SQLite3` (via `-lsqlite3`) — iMessage database reading for style onboarding
- `Metal` / `MetalKit` / `Accelerate` — MLX inference backend + FluidAudio (CoreML Parakeet inference)
- `libc++` (via `-lc++`) — Required by FluidAudio's C++ components
