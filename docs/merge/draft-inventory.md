# Draft Repo Inventory

Recon pass for the Draft + Transcripted merge. Scope: read-only inventory of `<draft-root>`
as of commit on `main` (worktree branch `feat/transcripted-merge`, symlinked `deps-libs`/`deps-modules`
back to the main checkout).

All paths below are absolute.

---

## 1. Top-Level Layout

Directory: `<draft-root>`

```
Draft/
├── Sources/                 # 12,253 lines of Swift across 13 dirs (see §2)
├── Tests/                   # 8 pure-function test files, custom runner (no XCTest)
├── backend/                 # Cloudflare Worker proxy (TypeScript, D1 DB) for beta telemetry + updates
├── docs/                    # Design docs (merge/, screenshots/, todo/)
├── evals/                   # Evaluation scripts (not touched in this pass)
├── deps-libs/               # Prebuilt static lib artifacts (libDraftDeps.a)
├── deps-modules/            # Prebuilt .swiftmodule files for FluidAudio + MLX
├── .deps-build/             # Scratch SPM workspace used by build-deps.sh
├── build.sh                 # Main build script — swiftc of all Sources/**/*.swift
├── build-deps.sh            # Builds FluidAudio + mlx-swift-lm into libDraftDeps.a
├── build-fluidaudio.sh      # Legacy: FluidAudio-only build (superseded)
├── build-beta.sh            # Beta-flavored build (BETA_BUILD flag)
├── build-all-betas.sh       # Drives multiple beta builds
├── package.sh               # DMG packaging
├── run-tests.sh             # Compiles pure-function tests with swiftc
├── Info.plist               # Current Draft bundle identifier, 1.0.2, macOS 14.0+
├── CLAUDE.md                # Project-level guide (29K — partially stale re: Messages/)
├── README.md                # 23K user-facing readme
└── LICENSE
```

**Key fact:** There is **no root `Package.swift`**. Draft is built by invoking `swiftc` directly
on every file under `Sources/` with explicit framework links. Dependencies are pre-compiled into
`libDraftDeps.a` via `build-deps.sh` using a throw-away `Package.swift` inside `.deps-build/`.
This is load-bearing for the merge strategy (see §8, §10).

---

## 2. Sources/ Inventory

12 subdirectories plus 5 top-level files (12,253 LOC total). Root CLAUDE.md lists a `Messages/`
directory in its ASCII diagram — **this is stale**, no such directory exists today. Any
iMessage reader has been folded into onboarding (see §2.11 Style).

### 2.0 Top-level files in `Sources/`

| File | LOC | Role |
|---|---:|---|
| `DraftApp.swift` | 149 | `@main struct DraftApp: App` + `DraftAppDelegate`. Status bar item, NSPopover, wake recovery observer. |
| `DraftAppState.swift` | 194 | `@MainActor class DraftAppState: ObservableObject` — single owner for every engine. `initialize()` idempotent via `isInitialized`; `handleSystemWake()` re-registers hotkeys & restarts analysis watcher; `shutdown()` tears everything down. |
| `DraftConstants.swift` | 173 | Enum of all tunables: `appPipelineVersion`, timeouts, audio buffer sizes, `parakeetSampleRate = 16000`, `audioTapBufferSize = 1024`, `ocrMaxCharacters = 3000`, `geminiBaseURL`, `geminiModel = "gemini-3-flash"`, `geminiRequestTimeout = 30`, `geminiDraftMaxTokens = 1024`. Plus `withTimeout` helper. |
| `DraftPaths.swift` | 13 | `FileManager` extension: `draftAppSupportDir` → `~/Library/Application Support/Draft/`. |
| `HotkeyPreferences.swift` | 210 | `struct HotkeyBinding: Equatable`, `enum HotkeyPreferences`. Defaults: `⌥D` draft, `⌥Space` dictation. Carbon modifier conversion, display strings, UserDefaults persistence, `rightOptionDictationEnabled()` (default `true`). |

### 2.1 `Sources/Accessibility/` — AXUIElement queries

- `AccessibilityBridge.swift` (61 lines) — `@MainActor struct`, 3 static methods:
  - `focusedTextElement(for: NSRunningApplication) -> AXUIElement?`
  - `textValue(of: AXUIElement) -> String?`
  - `focusedTextFieldRect(for: NSRunningApplication) -> CGRect?`
  All gated by `AXIsProcessTrusted()`. Used by `FloatingOverlayController` to position the
  overlay near the user's active text field.

### 2.2 `Sources/Analysis/` — Feedback-driven prompt improvement

- `AnalysisEngine.swift` (~357 lines) — `@MainActor ObservableObject`. Uses `DispatchSource.makeFileSystemObjectSource`
  on `feedback.jsonl` fd with `.write` mask; 30 s debounce; minimum 5 new entries. On fire, builds a system prompt
  containing the last 50 feedback lines, current `prompts.json`, `style.md`, and last 20 `suggestion_log.jsonl`
  entries, then calls **`MLXEngine.complete()`** (not Gemini — analysis stays local). Parses JSON InsightCards
  from the response. `apply()` writes to `prompts.json`, posts `.promptsDidChange` notification. `skip()` logs only.
  `start()`/`stop()` from `DraftAppState`. Has a `deinit` that cancels the dispatch source and debounce task.
- `InsightCard.swift` (51 lines) — `struct InsightCard: Identifiable`, `enum CardStatus` (`.pending/.applied/.skipped`),
  `static func from(toolId:input:) -> InsightCard?` factory for parsing tool-call JSON.

Public surface: `@Published var insights: [InsightCard]`, `@Published var isAnalyzing: Bool`,
`isConnected`, `agentStatus`, `start()`, `stop()`, `apply(_:)`, `skip(_:)`, `addInsight(_:)`.

### 2.3 `Sources/API/` — Gemini + Keychain + Beta config

- `GeminiEngine.swift` (~267 lines) — **Swift `actor`**. Primary drafting path.
  - `generate(prompt:systemPrompt:imageData:maxTokens:temperature:) -> AsyncThrowingStream<String, Error>`
    via `URLSession.bytes(for:).lines`, reads SSE from `streamGenerateContent?alt=sse`, parses
    `data: {json}` lines, yields `candidates[0].content.parts[0].text` chunks.
  - `complete(...)` non-streaming variant.
  - `cancelGeneration()`.
  - Multimodal: PNG screenshot is base64-encoded into an `inline_data` part.
  - Static keychain wrappers: `hasAPIKey`, `isAvailable`, `saveAPIKey`, `loadAPIKey`, `deleteAPIKey`.
  - `GeminiError` enum (`noAPIKey`, `networkError`, `apiError(Int, String)`, `parseError`, `cancelled`).
  - Model: `gemini-3-flash`, base URL `https://generativelanguage.googleapis.com/v1beta`.
- `KeychainHelper.swift` (43 lines) — `enum` with `save`/`load`/`delete` via Security framework.
  Service id matches the current Draft bundle identifier. Keychain key `"gemini-api-key"`.
- `BetaConfig.swift` (~25 lines) — `#if BETA_BUILD` gated: per-user token, proxy URL, app version,
  update URL. Not Gemini-related.

### 2.4 `Sources/Capture/` — Hotkeys + screenshot + context

- `ContextCaptureEngine.swift` (~298 lines) — `@MainActor class`. Registers Carbon global hotkeys
  (`RegisterEventHotKey`) with signature `0x44524654` ('DRFT'). Hotkey IDs: **1 = ⌥D draft**, **2 = ⌥Space dictation**.
  C callback `hotkeyHandler` captures `frontApp` + `imageData` **synchronously** before any
  `Task { @MainActor }` dispatch (otherwise focus shifts to Draft and screenshot is wrong). Routes
  into a module-level `weak var _sharedSessionController: DraftSessionController?` that's set via didSet.
  Also contains:
  - `RightOptionTapDetector` class — `install()`/`remove()` using NSEvent `flagsChanged` + `keyDown` local/global monitors,
    max tap duration 0.35 s. Implements the "tap right-Option" dictation shortcut.
  - `@Published` properties: `draftShortcutDisplay`, `dictationShortcutDisplay`, `hotkeyError`.
  - `registerHotkey()`, `unregisterHotkey()`, `reRegisterHotkeys()`.
  - `deinit` unregisters hotkeys and removes the Carbon event handler.
- `ScreenCapture.swift` (46 lines) — `struct`, single static method `captureFrontmostWindow(of: NSRunningApplication) -> Data?`.
  Filters `CGWindowListCopyWindowInfo` by PID + `layer == 0`, captures with `.optionIncludingWindow`,
  `.boundsIgnoreFraming`, `.bestResolution`. Converts `CGImage` → PNG via `NSBitmapImageRep`.
- `CapturedContext.swift` (104 lines) — plain struct with optional `platform`, `talkingTo`, `formality`, `conversation`.
  Methods: `hasConversation`, `displayText`, `draftingPrompt(userInstructions:)`, `static parse(from:)` (legacy OCR
  label parser). **Note:** CLAUDE.md mentions a `PreviousAppTracker.swift` but it is not present in the current tree.

### 2.5 `Sources/Draft/` — Drafting state + platform formatting

- `DraftEngine.swift` (26 lines) — minimal `@MainActor class`. Holds `@Published var originalDraft: String`,
  `var lastRawText: String`, and optional references to `StyleEngine`/`PromptStore`. Single method: `clear()`.
  **Not an orchestrator** — drafting lives in `DraftSessionController` (see §2.12 UI).
- `PlatformFormatter.swift` (104 lines) — `enum PlatformFormatter: String, CaseIterable`: `.slack`,
  `.imessage`, `.email`, `.discord`, `.teams`, `.generic`. Detects from bundle ID (`com.tinyspeck.slackmacgap`,
  `com.apple.MobileSMS`, `com.apple.mail`, `com.hnc.Discord`, `com.microsoft.teams(2)`). Two layers:
  `formattingInstructions: String` (prompt-level) and `postProcess(_: String) -> String` (pre-compiled
  static regexes: `boldRegex`, `italicAsteriskRegex`, `italicUnderscoreRegex`, `headerRegex`).
- `DraftUtils.swift` (28 lines) — `enum` with `static func looksLikeRefusal(_: String) -> Bool`.
  Matches against 13 phrases across three categories (missing-context requests, readiness/deflection,
  screenshot descriptions). Used to prevent poisoning the style profile with model refusals.
- `DiffSummary.swift` (~211 lines, not read in full this pass) — used by `OverlayDiffStripView`.

### 2.6 `Sources/Feedback/` — Accepted-draft logging + usage stats

- `FeedbackStore.swift` (~164 lines) — `@MainActor ObservableObject`. Writes one JSON object per line to
  `~/Library/Application Support/Draft/feedback.jsonl`. Schema includes `timestamp`, `raw_text`,
  `drafted_text`, `accepted_text`, `action` ("copy" | "paste"), `example_count`, optional `formality`,
  plus platform + conversation context. Writes fire-and-forget via a shared `JSONLWriter` actor.
  `@Published var stats: UsageStats` is recomputed by `refreshStats()` via `Task.detached` calling
  a `nonisolated static parseStats(url:)` helper. `UsageStats` tracks: wordsDictated, messagesDrafted,
  minutesSaved (estimated at 40 WPM), wordsDrafted, wordsAccepted.
- Also declares `enum AcceptAction { case copy, paste }`.

### 2.7 `Sources/Local/` — On-device MLX + Vision OCR

- `MLXEngine.swift` (~159 lines) — **Swift `actor`** wrapping `mlx-swift-lm`. Model id:
  `mlx-community/Qwen3.5-4B-4bit`. Cache dir: `~/Library/Caches/models/`. Thinking mode disabled
  via `userInput.additionalContext = ["enable_thinking": false]`. `isGenerating` guard. Methods:
  `load(progressHandler:) async throws`, `unload()`, `complete(...) async throws -> String`,
  `generate(...) -> AsyncThrowingStream<String, Error>`. `nonisolated static var isModelCached: Bool`.
- `LocalInferenceManager.swift` (74 lines) — `@MainActor ObservableObject`. Owns `let draftEngine = MLXEngine()`.
  `@Published var modelState: ModelState` (`.notLoaded`/`.downloading(Double)`/`.loading`/`.ready`/`.failed(String)`).
  `initialize()` triggers download/load, `cleanup()` unloads. Logs `model_loaded`/`model_load_failed` to events.jsonl.
- `LocalVisionExtractor.swift` (~85 lines) — `enum` with `static func extractContext(imageData: Data) async throws -> CapturedContext`.
  Uses Apple `VNRecognizeTextRequest` (`.accurate`, language correction). Sorts observations top→bottom, left→right.
  Truncates to `DraftConstants.ocrMaxCharacters` (3000), keeping header + recent tail when over the limit.
- `LocalLLMError.swift` (~24 lines) — `LocalizedError` enum: `.modelNotFound`, `.modelLoadFailed`,
  `.generationFailed`, `.contextOverflow`, `.cancelled`, `.downloadFailed`.

**Critical for the merge:** MLX is **not** the drafting path. It's used only for:
(1) **StyleEngine.regenerateStyleSummary** — style profile refinement
(2) **AnalysisEngine** — prompt-change proposals
(3) **StyleEngine.importBulkSamples** — onboarding bulk analysis
Drafting (`DraftSessionController`) calls Gemini 3 Flash directly.

### 2.8 `Sources/Observability/` — Events, logs, telemetry, crashes, updates

- `EventReporter.swift` (~162 lines) — `@MainActor` singleton + private `actor EventFileWriter`.
  Fires `ObservabilityEvent` records into `~/Library/Application Support/Draft/events.jsonl` via `Task.detached`.
  `capture(level:engine:event:message:context:)` merges caller context with a live `engineStateSummary` closure
  registered by `DraftAppState`. Levels: `.error`/`.warning`/`.info`. ~46 distinct event ids across 10 engines
  (see Observability/CLAUDE.md for the full catalog).
- `AppLogger.swift` (~118 lines) — `@MainActor ObservableObject`. Writes to `~/draft-debug.log`. Private
  `actor AppLogFileWriter` handles file I/O. Session separators on launch. Rotation at `logRotationThreshold`
  (keeps last `logRotationKeepLines`). `@Published var entries: [String]` (last 200). `log(_:)` and
  `logThrottled(_:key:minimumInterval:)` for high-frequency callbacks.
- `JSONLWriter.swift` (~45 lines) — shared `actor` for append-only JSONL files. Reuses a single `FileHandle`
  per writer. Detects external file rotation/deletion and re-opens. Used by `FeedbackStore`, `AnalysisEngine`.
- `EventTracker.swift` (~100 lines) — TelemetryDeck HTTP API wrapper. Anonymous `clientUser` UUID stored in
  UserDefaults. Ephemeral `URLSession` with 5 s timeout. Signals: `app.launched`, `dictation.completed`,
  `draft.shown`, `draft.accepted`, `draft.rejected`, `onboarding.completed`. **App ID constant is currently empty**
  (`telemetryAppID = ""`) — telemetry is a no-op until configured.
- `CrashReporter.swift` (~140 lines) — Raw Sentry Store API POST with `NSSetUncaughtExceptionHandler`.
  DSN constant in source (needs to be filled in).
- `BetaTelemetry.swift` (~260 lines) — `#if BETA_BUILD` gated. Batched event shipping to proxy Worker,
  incremental log/events.jsonl upload (60 s timer), quit-time flush, crash-safe offset tracking, log redaction.
- `UpdateManager.swift` (~225 lines) — DMG download, mount, staged app replacement with backup/rollback,
  version comparison via Info.plist, user-facing update prompts, team ID verification against the current app signature.

### 2.9 `Sources/Prompts/` — Externalized prompt store

- `PromptStore.swift` (~358 lines) — three components:
  1. `struct PromptConfig: Codable` — maps 1:1 to `prompts.json` with snake_case `CodingKeys`.
     Fields: `model`, `draftModel`, `draftingSystem`, `contextExtraction`, `ghostwritingSystem`,
     `styleAnalysisEarly`/`Growing`/`Mature`.
  2. `enum DefaultPrompts` — source-of-truth constants and a `Tier` (`.early/.growing/.mature`) +
     `styleAnalysis(tier:) -> String`. Current text is intent-first (`<primary_goal>`, `<style_profile>`,
     `<how_to_use_style>`, `<instructions>`).
  3. `@MainActor class PromptStore: ObservableObject` with `@Published var config: PromptConfig`.
     Loads `~/Library/Application Support/Draft/prompts.json` on init (falls back to `.defaults` +
     writes them if missing/corrupt). `reload()`, `ghostwritingPrompt(styleSummary:) -> String`
     (replaces `{STYLE_SUMMARY}`), `styleAnalysisPrompt(forExampleCount:) -> String`,
     `contextExtractionPrompt(userName:appName:) -> String` (currently vestigial — vision is Apple Vision OCR,
     not an LLM prompt).
- Per `Sources/Prompts/CLAUDE.md`, the `model`, `draft_model`, and `context_extraction` keys are
  **vestigial** but preserved for backward compatibility.

### 2.10 `Sources/Speech/` — STT pipeline

- `ParakeetEngine.swift` (~747 lines) — `@MainActor class ParakeetEngine: ObservableObject`.
  `@Published`: `isRecording`, `isTranscribing`, `audioLevel`, `liveTranscript`, `modelDownloadState`,
  `recordingInterrupted`. Uses **AVAudioEngine** (not SFSpeechRecognizer — the Apple Speech stack was
  abandoned because pro audio devices broke it). NSLock-protected shared sample buffer `pendingSamples`
  plus `streamingSampleBuffer` for live EOU. Owns two FluidAudio components:
  - `AsrManager` — Parakeet TDT V3 batch ASR (final transcription on stop)
  - `StreamingEouAsrManager` — Parakeet EOU 120M streaming (live transcript + debounce 1280 ms, chunk 320 ms)
  - Bundles models from the app bundle at `parakeet-models/parakeet-tdt-0.6b-v3-coreml/` (and EOU 120M),
    with HuggingFace download fallback at runtime.
  - `initialize()`, `prewarm()` (starts engine, installs `configChangeObserver` + wake observer),
    `startRecording(isRecoveryAttempt:)` (installs tap with 3 consumers: EOU streaming, sample buffer,
    level metering; zombie-engine watchdog with 2 s timeout), `stopRecording()`, `transcribe() async -> String?`
    (resamples to 16 kHz via `AudioResampler`, calls `AsrManager.transcribe(_:source:)`), `cleanup()`, `deinit`.
- `STTRouter.swift` (47 lines) — `@MainActor class STTRouter: ObservableObject`. Owns
  `let parakeetEngine = ParakeetEngine()`. Forwards 5 `@Published` properties via Combine `assign(to:)`.
  Gates `startRecording() -> Bool` on `isModelLoaded`. Sole public STT surface the rest of the app uses.
- `AudioResampler.swift` (28 lines) — `enum AudioResampler`, pure Swift linear interpolation
  (`resample(_:from:to:) -> [Float]`, default target 16 kHz).

### 2.11 `Sources/Style/` — Writing style learning

- `StyleEngine.swift` (~571–650 lines depending on count method) — `@MainActor class StyleEngine: ObservableObject`.
  Manages `~/Library/Application Support/Draft/style.md`. Training pairs saved by `recordExample(aiDraft:userFinal:
  platform:userInstructions:formality:)`. Graduated refinement scheduling: every 3 (examples 1-20),
  every 5 or 10 (examples 21+, based on avg edit distance). `regenerateStyleSummary(draftEngine: MLXEngine) async`
  sends last 20 examples to MLX and rewrites the profile incrementally (not a rebuild). `importBulkSamples(rawText:
  draftEngine: MLXEngine) async throws -> String` is the onboarding entry point — reads UserDefaults
  `"user-display-name"`, calls a `bulkAnalysisPrompt(userName:)` via MLX to produce a 500-800 word profile
  in a single pass. `buildSystemPrompt() -> String` assembles intent-first XML: `<primary_goal>`/`<style_profile>`/
  `<reference_messages>`/`<how_to_use_style>`/`<instructions>`. Public:
  `@Published var exampleCount`, `@Published var styleFileContents`, `@Published var hasCompletedOnboarding`,
  `var promptStore: PromptStore?`, `completeOnboarding()`.
- `StyleUtils.swift` (~70 lines) — stateless `enum`, pure functions: `shouldRefineNow()`,
  `averageRecentEditDistance()`, `extractRecentEditDistances()`, `wordEditDistance()`,
  `extractRecentExamplesText()`.
- The iMessage reader referenced in `Sources/Style/CLAUDE.md` (reads `~/Library/Messages/chat.db` via SQLite
  with `LIMIT 2000`, Full Disk Access) is **not a standalone file** in the current tree — it is inlined
  into the onboarding flow (StyleOnboardingView). The `-lsqlite3` link still appears in build.sh for that path.

### 2.12 `Sources/UI/` — Pure AppKit overlay + menubar + SwiftUI onboarding

33 files total. Two subsystems:

**Floating overlay (pure AppKit, non-activating NSPanel):**
- `FloatingOverlayPanel.swift` (37 lines) — `NSPanel` subclass; `allowKeyStatus: Bool` backs dynamic `canBecomeKey`.
- `FloatingOverlayController.swift` (~695 lines) — state machine
  (`.idle → .listening → .drafting → .streaming → .review → .idle`), panel positioning (via
  `AccessibilityBridge.focusedTextFieldRect(for:)`), Combine subscriptions that push data into views
  via explicit `update()` methods, global Escape monitor. Spring/shake animations.
- `OverlayRootView.swift` (~250 lines), `OverlayHeaderView.swift`, `OverlayListeningView.swift`,
  `OverlayDraftingView.swift`, `OverlayStreamingView.swift`, `OverlayReviewView.swift`,
  `OverlayDiffStripView.swift`, `OverlayToolbarView.swift`, `OverlayToastView.swift`.
- `DraftTextView.swift` (~100 lines) — `NSTextView` subclass that handles Enter (confirm), Shift+Enter
  (newline), Escape (cancel) via the responder chain.
- `WaveformLayer.swift` (~180 lines) — CALayer waveform + `WaveformRingBuffer` + 30 fps `Timer`.
- `PanelDragView.swift` (37 lines) — AppKit drag helper.
- `OverlayTokens.swift` — translucent-dark `NSColor` tokens.
- `DraftSessionController.swift` (~696 lines) — **THE drafting orchestrator.** See §5.

**Menubar popover (pure AppKit):**
- `MenuBarPanelController.swift` (~150 lines) — `NSViewController`, recreated per popover open.
  Holds Combine subscriptions; pushes to `MenuBarContentView` sections.
- `MenuBarContentView.swift`, `MenuBarHeaderView.swift`, `MenuBarStatsView.swift`,
  `MenuBarShortcutsView.swift`, `MenuBarStyleView.swift`, `MenuBarAgentView.swift`,
  `MenuBarModelDownloadView.swift`, `MenuBarSettingsView.swift`, `HotkeyRecorderAppKitView.swift`.
- `MenuTokens.swift` — system-adaptive NSColor + SwiftUI Color tokens.

**Onboarding (still SwiftUI):**
- `OnboardingView.swift` (~876 lines), `OnboardingWindowController.swift` (~88 lines),
  `StyleOnboardingView.swift` (~554 lines), `PermissionsOnboardingView.swift` (~252 lines).

---

## 3. Entry Points

### 3.1 Process entry: `DraftApp.swift`

```
@main struct DraftApp: App {
    @NSApplicationDelegateAdaptor(DraftAppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }   // No app windows — menubar only
}
```

`DraftAppDelegate` owns:
- `appState: DraftAppState`
- `overlayController: FloatingOverlayController`
- `sessionController: DraftSessionController`

### 3.2 Boot sequence (per `Sources/CLAUDE.md`)

`applicationDidFinishLaunching()`:
1. **Engine construction** — `DraftAppState.init()` synchronously instantiates every engine
   (DraftEngine, StyleEngine, PromptStore, FeedbackStore, AppLogger, ContextCaptureEngine,
   AnalysisEngine, LocalInferenceManager, GeminiEngine, STTRouter, UpdateManager (BETA)).
2. **Wiring** (order-sensitive):
   - `sessionController.appState = appState`
   - `sessionController.overlayController = overlayController`
   - `appState.contextCapture.sessionController = sessionController`
3. `NSApp.setActivationPolicy(.regular)` → status bar item → empty `NSPopover` (content view created
   on-demand in `togglePopover()` to avoid `NSHostingView` leaks).
4. Install wake recovery observer (`NSWorkspace.didWakeNotification` → `appState.handleSystemWake()`).
5. Async `Task { @MainActor in appState.initialize(); appState.contextCapture.registerHotkey() }`
   — engines cross-wired (DraftEngine styleEngine, promptStore; analysis start; Parakeet prewarm),
   then hotkeys registered (last, so every engine is live before hotkey callbacks can fire).

### 3.3 CLI entry points

**None.** Draft is a pure menubar app; there is no CLI target, no `ArgumentParser`, no shebang Swift,
no top-level `main.swift`. See §9.

---

## 4. Hotkey System

Two complementary implementations live side by side:

### 4.1 Carbon `RegisterEventHotKey` (the primary path)

`Sources/Capture/ContextCaptureEngine.swift` registers two OS-level hotkeys:

| ID | Shortcut | Modifiers | Key code | Action |
|---|---|---|---|---|
| 1 | ⌥D | `optionKey` | `kVK_ANSI_D` | Draft mode — screenshot + voice + Gemini drafting |
| 2 | ⌥Space | `optionKey` | `kVK_Space` | Dictation mode — voice only, light polish, auto-paste |

Both use signature `0x44524654` (`'DRFT'`). Registration is idempotent (checks `eventHandlerRef == nil`
before registering) and has a matching `unregisterHotkey()` + `deinit` path.

A C callback `hotkeyHandler` captures `NSWorkspace.shared.frontmostApplication` and the screenshot
**synchronously** in the callback (before any async dispatch — critical, otherwise focus shifts to Draft
before `ScreenCapture.captureFrontmostWindow` runs). It then does `Task { @MainActor }` and routes into
`DraftSessionController` based on session state (start/stop/cancel/cross-mode-switch).

The C callback can't capture Swift closures, so routing uses a module-level `weak var _sharedSessionController`
pointer set via `didSet` on `ContextCaptureEngine.sessionController`.

### 4.2 NSEvent monitors (secondary)

- **Right-Option tap detector** (`RightOptionTapDetector` inside `ContextCaptureEngine.swift`) — a separate
  dictation shortcut: `flagsChanged` + `keyDown` monitors with a 0.35 s max-tap window. Controlled by
  `HotkeyPreferences.rightOptionDictationEnabled()` (default `true`).
- **Global Escape monitor** — installed by `FloatingOverlayController` during listening/drafting/streaming
  (when the panel has `allowKeyStatus = false`). Uses `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`
  and routes `keyCode == 53` to `DraftSessionController.cancelSession()` via a closure.
- During review mode, Escape is handled in-process by `DraftTextView.keyDown(with:)` (the panel becomes key).

### 4.3 Hotkey preferences UI

`HotkeyPreferences.swift` (210 lines) + `HotkeyRecorderAppKitView.swift` in `Sources/UI/` implement a full
user-configurable hotkey recorder backed by UserDefaults. `HotkeyBinding: Equatable`, Carbon modifier
conversion, display strings, `isValid()` validation.

---

## 5. Paste Mechanism

Lives in `Sources/UI/DraftSessionController.swift`. Exact method: `pasteWithClipboardRestore(_:)` (around
lines 629–695 in the current 696-line file).

Flow:
1. **Save** the current clipboard contents (both string and object) and remember the pre-paste
   `NSPasteboard.general.changeCount`.
2. **Write** the draft text to the general pasteboard.
3. **Simulate ⌘V** via `CGEvent` keyDown/keyUp on `CGEventSourceStateID.combinedSessionState`
   with the Command modifier. If `CGEventCreateKeyboardEvent` returns nil, fires a
   `cgevent_create_failed` event via EventReporter.
4. **Poll** `NSPasteboard.changeCount` every 50 ms up to 2 s waiting for the target app to finish
   consuming the paste (some apps write the clipboard back on paste, which would cause an early restore).
5. **Restore** the original clipboard contents after either (a) the changeCount increments, or
   (b) the 2 s timeout elapses.

The non-activating `FloatingOverlayPanel` keeps the target app frontmost throughout, so ⌘V is received
by the correct app without a manual re-activation step.

Paste-back targets `sessionSourceApp` (the `NSRunningApplication` captured at hotkey time), not the
currently frontmost app.

Accessibility is only probed (via `AXIsProcessTrustedWithOptions` with the prompt flag) at paste time —
it's not a hard precondition.

---

## 6. Audio Capture Stack

Owned entirely by `Sources/Speech/ParakeetEngine.swift`.

### 6.1 Engine + tap

- **`AVAudioEngine`** (not `SFSpeechRecognizer`'s bundled engine — explicitly replaced because pro
  audio interfaces like BEACN Mic (96 kHz / 4 ch) broke the Apple Speech stack with error 1110).
- Input node tap installed with `audioTapBufferSize: UInt32 = 1024` (from `DraftConstants`).
- Tap uses the input's **native format** (whatever the device reports), **forced to mono** to sidestep
  pro audio channel-count bugs.
- Three sample consumers inside the tap callback:
  1. EOU streaming (`StreamingEouAsrManager.process(...)`) for live on-screen transcript with 320 ms chunks
     and 1280 ms debounce.
  2. Batch buffer (`pendingSamples`) for final transcription on stop.
  3. Level metering (feeds `@Published var audioLevel` → waveform).

### 6.2 Concurrency

- Audio render thread has ~10 ms deadlines; actor isolation has unpredictable scheduling latency.
- **NSLock** (not an actor) guards both `pendingSamples` and `streamingSampleBuffer`. Locks give
  deterministic ~1 µs overhead; the tap is a non-actor context writing into these buffers, and the
  MainActor reads from them asynchronously.
- `audioBufferCapacitySeconds = 120` cap on the batch buffer (from `DraftConstants`).

### 6.3 Lifecycle + resilience

- `prewarm()` — starts the engine on app launch, installs a configChangeObserver and wake observer.
- `startRecording(isRecoveryAttempt:)` — zombie-engine watchdog with 2 s timeout
  (`audioWatchdogTimeout = 2_000_000_000` ns); `audioRecoveryDelay = 300_000_000` ns;
  `audioRewarmDelay = 1_000_000_000` ns.
- `configChangeObserver` handles device change mid-recording (fires `recording_interrupted` warning
  and sets `@Published recordingInterrupted = true`, which `DraftSessionController` observes and turns
  into a "Audio device changed" overlay error).
- `stopRecording()`, `transcribe() async -> String?`, `cleanup()`, and `deinit` release the CoreML
  managers and the engine.
- Microphone permission (`AVCaptureDevice.authorizationStatus`) is checked before `installTap()` — if
  revoked at runtime, fires `mic_not_authorized` and returns.

### 6.4 Resampling

`Sources/Speech/AudioResampler.swift` (28 lines) — pure Swift linear interpolation, no Accelerate usage.
Called by `ParakeetEngine.transcribe()` to convert the native-rate mono buffer down to
`DraftConstants.parakeetSampleRate = 16000` before passing to `AsrManager.transcribe(_:source:)`.

---

## 7. Speech / STT Code

All STT lives under `Sources/Speech/`. Draft does **not** use `SFSpeechRecognizer` anywhere — the
Apple Speech framework is only linked for possible future use (see §"Frameworks Linked" in root
CLAUDE.md, but the current runtime STT path is 100% FluidAudio).

### 7.1 FluidAudio integration

- **Package**: `https://github.com/FluidInference/FluidAudio.git` `from: "0.7.9"` — declared in
  `.deps-build/Package.swift` and pre-compiled into `libDraftDeps.a` via `build-deps.sh`.
- **Models used**:
  - `parakeet-tdt-0.6b-v3-coreml` (Parakeet TDT V3 batch ASR) — final transcription on stop.
  - `parakeet-eou-120m-coreml` / `parakeet-eou-streaming/320ms` (Parakeet EOU 120M) — live streaming transcript.
- **Model delivery**: `build.sh` copies the models from the developer's
  `~/Library/Application Support/FluidAudio/Models/` into `Contents/Resources/parakeet-models/` at
  build time. At runtime, `ParakeetEngine.initialize()` loads from the bundle path first and falls back to
  `DownloadUtils`-driven HuggingFace download on cold machines that don't already have the models.

### 7.2 Swift surface

- `ParakeetEngine.initialize()` wires up `AsrManager` + `StreamingEouAsrManager` (FluidAudio types)
  with the discovered model paths.
- `STTRouter` is the only type the rest of the app imports. `DraftSessionController.stopSessionAndDraft()`
  calls `appState.sttRouter.stopRecording()` then `appState.sttRouter.transcribe()` (waits for
  `isModelLoaded` if still loading, with a `modelLoadMaxIterations` × `modelLoadPollInterval` busy-wait).
- Live transcript flows from `StreamingEouAsrManager` → `@Published liveTranscript` → `OverlayListeningView`
  via `FloatingOverlayController`'s Combine subscriptions.

### 7.3 Events logged

`prewarm_failed`, `mic_not_authorized`, `model_not_loaded`, `model_not_ready`, `models_loaded`,
`model_init_failed`, `transcription_empty`, `transcription_complete`, `transcription_failed`,
`audio_format_failed`, `audio_engine_start_failed`, `asr_manager_unavailable`,
`device_change_rewarm_failed`, `recording_interrupted` — all under engine `parakeet`.

---

## 8. Dependency Management

Draft uses a **two-step custom pipeline** instead of root-level SPM.

### 8.1 The scratch SPM build (`build-deps.sh` + `.deps-build/Package.swift`)

`.deps-build/Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "DraftDeps",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "25b00d4"),
    ],
    targets: [
        .target(
            name: "Shim",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources"
        )
    ]
    // ...
)
```

`build-deps.sh` (~150 lines):
1. Skips if `deps-libs/libDraftDeps.a` and `deps-modules/` already exist (unless `--force`).
2. Wipes and recreates `.deps-build/` with a unified `Package.swift`.
3. Runs `swift build -c release` inside `.deps-build/`.
4. Walks `.deps-build/.build/release/*.o` (and every transitive target's `.o`) and archives them into
   `deps-libs/libDraftDeps.a` with `ar`.
5. Copies every `.swiftmodule` from `.build/release/` into `deps-modules/`.
6. Compiles MLX's Metal shaders with `xcrun metal ... -fmetal-version=3.0` → `deps-libs/mlx.metallib`.

**Why unified**: FluidAudio and mlx-swift-lm share transitive dependencies (swift-transformers,
swift-tokenizers, swift-collections, swift-crypto, swift-system, etc.). Resolving them together once
prevents duplicate-symbol link errors that a per-dependency build would hit.

`build-fluidaudio.sh` is a legacy FluidAudio-only build, superseded by `build-deps.sh`.

### 8.2 The app build (`build.sh`)

1. `swiftc` over `$(find Sources -name '*.swift')` — every Swift file in one shot, no SPM.
2. Links `-L deps-libs -lDraftDeps` and `-I deps-modules`.
3. Links Apple frameworks: `AVFoundation`, `AppKit`, `SwiftUI`, `Combine`, `Speech`, `Security`,
   `Carbon`, `Metal`, `MetalKit`, `Accelerate`, `Vision`, `MetalPerformanceShaders`,
   `MetalPerformanceShadersGraph`, plus `-lc++` and `-lsqlite3`.
4. Bundles Parakeet CoreML models from the developer's `~/Library/Application Support/FluidAudio/Models/`.
5. Copies `deps-libs/mlx.metallib` into `Contents/MacOS/` (MLX expects its metallib colocated with the binary).
6. Writes an unsandboxed entitlements file (mic + speech + screen recording).
7. Signs with Developer ID, launches the app.

### 8.3 Non-SPM, non-CocoaPods

There is **no** `Package.swift` at the repo root, **no** `Package.resolved`, **no** Podfile, **no**
Xcode project, **no** Tuist/XcodeGen. Dependencies are reached exclusively through the
`.deps-build/Package.swift` → `libDraftDeps.a` pipeline. This is load-bearing for the merge (see §10).

### 8.4 External dependencies summary

| Package | Version / revision | Used by |
|---|---|---|
| FluidAudio | `from: 0.7.9` | `ParakeetEngine` (TDT V3 batch + EOU 120M streaming) |
| mlx-swift-lm | `revision: 25b00d4` | `MLXEngine` (MLXLLM, MLXLMCommon products) |
| Apple frameworks | OS | All over |
| `libsqlite3` | system | iMessage onboarding import path |

**Backend (separate process, not linked into the Swift binary):**
- `backend/` — Cloudflare Worker in TypeScript. `wrangler.toml` name `draft-proxy`,
  D1 binding `DB` (`draft-beta-db`), vars `LATEST_VERSION = "1.0.1"`,
  `DOWNLOAD_URL_BASE = "https://github.com/r3dbars/Draft/releases/download/v1.0.1"`. Single
  entry file `src/index.ts`. Used only by BetaTelemetry + UpdateManager.

---

## 9. CLI Target Check

**No CLI target exists in Draft.**

Confirmed by inspection:
- No top-level `main.swift` anywhere (entry is `@main struct DraftApp: App` in `DraftApp.swift`).
- No `executableTarget` declarations — there's no root `Package.swift` at all (see §8).
- No `ArgumentParser` import, no `CommandLine.arguments` processing in any source file seen.
- No shebang `#!/usr/bin/env swift` scripts under `Sources/`.
- `Info.plist` declares an `LSUIElement`-compatible app (menubar-only), not a `CommandLineTool`.
- `build.sh` produces a single `Draft.app` bundle, not a headless binary.
- Every public entry on every engine assumes `@MainActor` and an NSApplication event loop (Combine
  subscriptions, NSPanel lifecycle, Carbon hotkeys, clipboard polling, CGEvent posting).

**Implication for the merge:** if Transcripted wants to invoke Draft logic headlessly (e.g., as a
`transcripted` CLI using `TranscriptedCore`), any shared audio/STT code will need to be refactored
out of `@MainActor ObservableObject` into pure types that work without an event loop, or Transcripted
will need to ship its own thin STT wrapper. The FluidAudio integration itself is fine headlessly —
it's only the Swift glue (`ParakeetEngine`, `STTRouter`) that's main-actor-bound today.

---

## 10. Verdict Per Subsystem

For each subsystem, "Keep as-is" means the code is well-structured and we can leave it in place with
minimal or no changes; "Needs changes" spells out what the merge will likely touch.

| Subsystem | Verdict | Notes |
|---|---|---|
| **DraftApp / DraftAppState / DraftPaths / DraftConstants** | Keep | Clean, idempotent, wake-aware. Merge only needs to (a) add a TranscriptedCore engine reference alongside the others and (b) extend `DraftPaths` if Transcripted wants a separate subdir. |
| **HotkeyPreferences** | Keep | Self-contained, already user-configurable. Nothing to merge. |
| **Sources/Speech (ParakeetEngine, STTRouter, AudioResampler)** | **Likely replace or reroute** | This is the biggest overlap point. Draft already owns a 747-line FluidAudio-based STT pipeline. If TranscriptedCore provides its own STT, we must either (i) delete `ParakeetEngine` and route `STTRouter` into TranscriptedCore's STT, or (ii) keep Draft's pipeline and not use TranscriptedCore's STT at all. See also §"Overlaps to flag" below. Either way, `STTRouter` is the clean seam — everything else in Draft only talks to `STTRouter`. |
| **Sources/Capture (ContextCaptureEngine, ScreenCapture, CapturedContext)** | Keep | Carbon hotkeys + synchronous screenshot capture are Draft-specific and have no Transcripted analog (Transcripted is presumably a transcription tool, not a screenshot-driven drafter). Keep intact. |
| **Sources/Draft (DraftEngine, PlatformFormatter, DraftUtils, DiffSummary)** | Keep | Tiny, Draft-specific. No overlap expected. |
| **Sources/Local (MLXEngine, LocalInferenceManager, LocalVisionExtractor)** | Keep (possibly optional) | MLX is only used for style refinement / analysis / onboarding bulk analysis. If TranscriptedCore does not need MLX, we could in principle leave this in Draft only and not expose it to Transcripted. But since MLX is already a dep in `libDraftDeps.a`, leaving it is free. |
| **Sources/API (GeminiEngine, KeychainHelper, BetaConfig)** | Keep | Gemini is Draft's primary drafting path — Transcripted (a transcription tool) presumably has no opinion. Leave untouched. |
| **Sources/Style (StyleEngine, StyleUtils)** | Keep | Uses `MLXEngine` for refinement. Not touched by the merge. |
| **Sources/Prompts (PromptStore)** | Keep | Pure Swift + JSON. If TranscriptedCore adds new prompts, extend `PromptConfig` fields; otherwise leave alone. |
| **Sources/Feedback (FeedbackStore)** | Keep | JSONL + UsageStats; no overlap. |
| **Sources/Analysis (AnalysisEngine, InsightCard)** | Keep | DispatchSource file watcher on `feedback.jsonl`. No overlap. |
| **Sources/Accessibility (AccessibilityBridge)** | Keep | 61 lines, self-contained. |
| **Sources/Observability (EventReporter, AppLogger, JSONLWriter, EventTracker, BetaTelemetry, UpdateManager, CrashReporter)** | Keep, extend | If TranscriptedCore wants to emit events, it should get an `engine: "transcripted"` namespace in `EventReporter`. `JSONLWriter` is already reusable via its public init. |
| **Sources/UI (floating overlay + menubar + onboarding)** | Keep | Pure AppKit overlay + menubar are Draft-specific. If Transcripted ships a menubar UI of its own, that's a new surface (not a merge conflict). SwiftUI onboarding stays. |
| **Tests/** | Keep, extend | 147 pure-function tests, custom runner, no XCTest. Extend for any new merged code. |
| **backend/** | Keep | Separate Cloudflare Worker; not on the Swift dependency graph. |
| **build.sh / build-deps.sh** | **Needs changes** | This is the biggest structural question. See §10 "Build system" below. |

### 10.A Build system — the merge's open question

Draft has no root `Package.swift`. If the merge introduces `TranscriptedCore` as an SPM package, we have
two options:

**Option A — Add `TranscriptedCore` to the existing `.deps-build/Package.swift` as another dependency**,
let `build-deps.sh` bake it into `libDraftDeps.a`, and have `build.sh` import it via
`-I deps-modules` + `-lDraftDeps`. This keeps the build pipeline shape intact, reuses the existing
transitive-dep resolution, and is the smallest diff.

**Option B — Introduce a root `Package.swift`** for Draft that declares `TranscriptedCore` as a dep and
makes Draft itself into an executable target. This is cleaner long-term but means rewriting `build.sh`
end-to-end and figuring out resource bundling (Parakeet models, `mlx.metallib`, entitlements) in the SPM
model — which is historically painful for a custom-entitled unsandboxed macOS app.

Recommendation for the joint merge plan (§Task #3): **start with Option A** to keep the blast radius
small, and revisit Option B as a separate follow-up.

### 10.B Overlaps to flag to `transcripted-mapper`

1. **FluidAudio 0.7.9 is already in use in Draft** — same library Transcripted almost certainly uses.
   `.deps-build/Package.swift` declares `from: "0.7.9"`. If Transcripted pins to a different version,
   we have a single-source-of-truth conflict to resolve in the unified `libDraftDeps.a`.
2. **`Sources/Capture/` already exists** — it's Draft's hotkey/screenshot/context module, not a generic
   capture module. If TranscriptedCore ships a directory named `Capture/`, we'll need to rename one of them.
3. **`Sources/Speech/` already exists** — with a full Parakeet TDT V3 + EOU 120M integration via `ParakeetEngine`
   and `STTRouter`. Strongest candidate for a real merge: ideally both tools route through one STT engine
   (`STTRouter` is already designed as the seam). Transcripted-mapper should audit whether TranscriptedCore
   can be plugged in behind `STTRouter` or whether it replaces `ParakeetEngine` wholesale.
4. **Drafting is Gemini, not MLX** — Draft's active drafting path is `GeminiEngine.generate()` in
   `Sources/API/`, calling `gemini-3-flash` via SSE with multimodal image parts. MLX is used only for
   offline style refinement / analysis / onboarding bulk analysis. If Transcripted assumes all generation
   is local, that assumption does not hold for Draft.
5. **No root `Package.swift`** — as documented in §8 and §10.A. The simplest integration is to extend
   `.deps-build/Package.swift`, not create a new root manifest.
6. **No CLI target in Draft** — every engine is `@MainActor`. If Transcripted exposes a CLI that wants
   to share `ParakeetEngine` code, we need a refactor step to pull STT out of the main-actor hierarchy.
7. **The current Draft bundle identifier** is reused for the Keychain service and UserDefaults suite —
   any TranscriptedCore code reading from Keychain must pick a distinct service.
8. **DraftPaths writes everything to `~/Library/Application Support/Draft/`** — prompts.json, style.md,
   feedback.jsonl, events.jsonl, suggestion_log.jsonl. If Transcripted wants its own dir, add a new
   extension method; don't namespace-collide inside the same directory.

---

## Appendix A — File Counts

- Total Swift LOC in `Sources/`: **12,253** (excluding `Tests/`).
- 13 subdirectories in `Sources/` (Accessibility, Analysis, API, Capture, Draft, Feedback, Local,
  Observability, Prompts, Speech, Style, UI) + 5 top-level files.
- 8 test files in `Tests/`: `CapturedContextTests.swift`, `DiffSummaryTests.swift`, `InsightCardTests.swift`,
  `PlatformFormatterTests.swift`, `RefusalDetectionTests.swift`, `StyleUtilsTests.swift`, `TestHelpers.swift`,
  `TestRunner.swift`.

## Appendix B — Data files written at runtime

All under `~/Library/Application Support/Draft/`:
- `prompts.json` — externalized prompt config
- `style.md` — learned writing style profile + training pairs
- `feedback.jsonl` — accepted draft log (watched by AnalysisEngine via DispatchSource)
- `events.jsonl` — structured error/warning/info log (EventReporter)
- `suggestion_log.jsonl` — applied/skipped InsightCard actions
- `~/draft-debug.log` — narrative AppLogger log (rotates at `logRotationThreshold`)

Plus `~/Library/Caches/models/mlx-community/Qwen3.5-4B-4bit/` (MLX model cache, ~2.5 GB on first run)
and `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml/` (bundled at build time,
downloaded at runtime on cold machines).
