# Screen Capture & Context Extraction

## What This Does

Captures a screenshot of the user's current app window, sends it to Haiku Vision to extract the full conversation thread, and stores the source app reference for paste-back. Two global hotkeys handle two distinct modes: Option+D for draft mode (screenshot + voice + AI rewrite) and Option+Space for dictation mode (voice only + light polish + auto-paste). Both hotkeys route through `DraftSessionController` with cross-mode switching support.

## Key Files

- `ContextCaptureEngine.swift` (197 lines) — Hotkey registration (Carbon), screenshot capture, dual-mode routing with cross-mode switching to DraftSessionController
- `CapturedContext.swift` (121 lines) — Structured data extracted from a screenshot (platform, talkingTo, formality, conversation) + parser + prompt builder
- `ScreenCapture.swift` (46 lines) — Low-level window capture via CGWindowListCreateImage

## How It Works (v2 — Floating Overlay)

### Draft Mode (Option+D)

1. **Hotkey fires** — Carbon `RegisterEventHotKey` intercepts Option+D (hotkey ID 1) at OS level
2. **Synchronous capture** — The C callback captures TWO things IMMEDIATELY (before any async dispatch):
   - `frontApp` — the `NSRunningApplication` reference (stored for paste-back later)
   - `imageData` — the screenshot PNG of that app's frontmost window
3. **Routing** — `Task { @MainActor }` checks `DraftSessionController` state and routes:

| Session State | Option+D Action |
|---------------|-----------------|
| Dictating (Option+Space session active) | `cancelDictation()` then `startSession(imageData:sourceApp:)` — cross-mode switch |
| Not in session | `startSession(imageData:sourceApp:)` — shows overlay, starts voice + vision in parallel |
| Listening/drafting/streaming | `stopSessionAndDraft()` — stops voice, awaits vision, streams draft |
| Review | `cancelSession()` — hides overlay, discards draft |

4. **Vision runs in parallel** — `DraftSessionController.startSession()` fires vision processing as a parallel `Task` stored as `visionTask`. Voice recording runs simultaneously.
5. **Vision awaited before drafting** — `stopSessionAndDraft()` calls `await visionTask?.value` before checking `lastCapturedContext`, ensuring vision results are available even when the user speaks quickly.

### Dictation Mode (Option+Space)

1. **Hotkey fires** — Carbon `RegisterEventHotKey` intercepts Option+Space (hotkey ID 2) at OS level
2. **No screenshot** — Dictation mode captures only `frontApp` for paste-back, no `imageData` needed
3. **Routing** — `Task { @MainActor }` checks state and routes:

| Session State | Option+Space Action |
|---------------|---------------------|
| Draft session active (isInSession) | `cancelSession()` then `startDictation(sourceApp:)` — cross-mode switch |
| Dictating | `stopDictationAndPaste()` — stops voice, polishes, pastes |
| Not in session | `startDictation(sourceApp:)` — shows overlay, starts voice recording |

## Hotkey IDs

- **ID 1** — Option+D (Draft mode): screenshot + voice + AI rewrite + review
- **ID 2** — Option+Space (Dictation mode): voice only, light polish, auto-paste

Both use signature `0x44524654` ('DRFT').

## Critical Design Decision: Sync Capture in C Callback

The screenshot AND the frontmost app reference MUST be captured synchronously inside `hotkeyHandler()` before any `Task { @MainActor }` dispatch. If deferred to async, macOS shifts window focus to Draft, and you capture Draft's own window instead of the target app. The stored `sourceApp` would also be wrong.

```swift
private func hotkeyHandler(...) -> OSStatus {
    // hotkeyID.id == 1: Option+D (Draft) — captures screenshot
    let frontApp = NSWorkspace.shared.frontmostApplication
    let imageData = frontApp.flatMap { ScreenCapture.captureFrontmostWindow(of: $0) }
    Task { @MainActor in
        guard let session = _sharedSessionController else { return }
        if session.isDictating {
            session.cancelDictation()
            session.startSession(imageData: imageData, sourceApp: frontApp)
        } else if session.isInSession {
            if session.overlayController?.state == .review {
                session.cancelSession()
            } else {
                session.stopSessionAndDraft()
            }
        } else {
            session.startSession(imageData: imageData, sourceApp: frontApp)
        }
    }

    // hotkeyID.id == 2: Option+Space (Dictation) — no screenshot
    let frontApp = NSWorkspace.shared.frontmostApplication
    Task { @MainActor in
        guard let session = _sharedSessionController else { return }
        if session.isDictating {
            session.stopDictationAndPaste()
        } else if session.isInSession {
            session.cancelSession()
            session.startDictation(sourceApp: frontApp)
        } else {
            session.startDictation(sourceApp: frontApp)
        }
    }
    return noErr
}
```

### Global Reference

The C callback can't capture Swift closures, so a `weak` module-level reference bridges the gap:
- `_sharedSessionController` — set via `ContextCaptureEngine.sessionController` didSet

## Vision Race Condition Fix

Vision API calls typically take 2-6 seconds. If the user speaks quickly (< 2s), `stopSessionAndDraft()` would fire before vision completes. The fix:

1. `startSession()` stores the vision Task handle as `visionTask`
2. `stopSessionAndDraft()` calls `await visionTask?.value` before reading `lastCapturedContext`
3. Vision has an 8-second timeout via `AnthropicAPI.withTimeout(seconds: 8)`
4. If vision times out, a no-context fallback prompt asks Claude to "clean up and polish the dictation" (not "write a reply" — that confuses Claude without conversation context)

## CapturedContext Struct

Plain Swift struct (no Codable) with labeled fields parsed from Haiku's plain-text response:

```swift
struct CapturedContext {
    var platform: String?       // "slack", "email", "imessage", "discord", "teams", "other"
    var talkingTo: String?      // "Sarah Graham" — the main person the user is conversing with
    var formality: String?      // "casual", "professional", "formal"
    var conversation: String?   // Full conversation thread text (all messages, all participants)

    var hasConversation: Bool   // True if conversation is non-empty
    var displayText: String     // Transparent labeled sections for the UI TextEditor
    func draftingPrompt(userInstructions: String) -> String  // Assembles full prompt for DraftEngine
    static func parse(from text: String) -> CapturedContext  // Parses Haiku's plain-text response
}
```

**`displayText`** shows the user exactly what was captured — transparent labeled sections (PLATFORM, TALKING TO, FORMALITY, CONVERSATION) so there's no mystery about what Draft "sees."

**`draftingPrompt()`** assembles the full drafting prompt with conversation context + user's voice instructions as separate labeled sections, followed by a 7-rule INSTRUCTIONS block: (1) instruction type awareness with intent-first reinforcement — "accomplish this goal above all else, don't let style patterns override or distort what the user is trying to say"; (2) conversation is background context for the reply; (3) match conversational energy/length; (4) no parroting back what the other person said; (5) no AI fluff (unnecessary greetings, sign-offs, exclamation points); (6) output only the reply text, no labels or explanations; (7) anti-opener rule — don't prepend agreement phrases unless the conversation genuinely calls for agreement.

**`parse()`** is a line-by-line parser using case-insensitive `hasPrefix` checks (each line is uppercased before comparison). An `inConversation` flag captures everything after the "CONVERSATION:" header until end of text. Other labeled headers (`PLATFORM:`, `TALKING TO:`, `FORMALITY:`) reset `inConversation` to `false`.

## Reliability Hardening

### Double Registration Guard

`registerHotkey()` checks `eventHandlerRef == nil` before registering. Without this, double-calling stacks Carbon hotkeys — each press fires the callback multiple times.

### deinit Cleanup

```swift
deinit {
    if let ref = hotkeyRef { UnregisterEventHotKey(ref) }
    if let ref = dictationHotkeyRef { UnregisterEventHotKey(ref) }
    if let ref = eventHandlerRef { RemoveEventHandler(ref) }
}
```

Carbon hotkeys are global OS-level resources. Without explicit cleanup in `deinit`, they persist after Swift object deallocation and fire into freed memory.

### unregisterHotkey() Cleanup

`unregisterHotkey()` explicitly nils out all three refs (`hotkeyRef`, `dictationHotkeyRef`, `eventHandlerRef`) after unregistering, and clears the global reference (`_sharedSessionController = nil`).

### Optional Chaining for overlayController

Since `DraftSessionController.overlayController` is now `Optional` (not IUO), the hotkey callback uses `session.overlayController?.state` with optional chaining.

## Hotkey Details

- **Draft shortcut:** Option+D (`optionKey`, `kVK_ANSI_D`) — hotkey ID 1
- **Dictation shortcut:** Option+Space (`optionKey`, `kVK_Space`) — hotkey ID 2
- **Registration:** Carbon `RegisterEventHotKey` with signature `0x44524654` ('DRFT')
- **Why Carbon:** `NSEvent.addGlobalMonitorForEvents` is a passive observer — apps can consume events before the monitor sees them. Carbon hotkeys intercept at OS level (same mechanism as Alfred/Raycast).

## Screen Recording Permission

`CGWindowListCreateImage` requires Screen Recording permission. If not granted, capture returns nil and shows an error. The user must manually grant permission in System Settings > Privacy & Security > Screen Recording. Rebuilding the app may revoke permission (new code signature).

## ScreenCapture Implementation

`ScreenCapture.captureFrontmostWindow(of:)` finds the target window by:
1. Querying `CGWindowListCopyWindowInfo` for all on-screen windows (excluding desktop elements)
2. Filtering by the app's `processIdentifier` and `layer == 0` (normal windows only)
3. Taking the first match (frontmost) and capturing it with `CGWindowListCreateImage` using `.optionIncludingWindow`, `.boundsIgnoreFraming`, and `.bestResolution`
4. Converting the `CGImage` to PNG via `NSBitmapImageRep`

## Public Interface

```swift
// ContextCaptureEngine (@MainActor, ObservableObject)
var sessionController: DraftSessionController?  // Set by DraftAppDelegate — wires hotkey routing (didSet updates _sharedSessionController)

func registerHotkey()
func unregisterHotkey()

// ScreenCapture
static func captureFrontmostWindow(of app: NSRunningApplication) -> Data?

// CapturedContext
var platform: String?
var talkingTo: String?
var formality: String?
var conversation: String?
var hasConversation: Bool           // Computed: conversation is non-nil and non-empty after trimming
var displayText: String             // Computed: labeled sections joined by newlines
func draftingPrompt(userInstructions: String) -> String
static func parse(from text: String) -> CapturedContext
```

## Verification

After modifying capture or context extraction, verify with these checks:

- **Draft routing:** Option+D starts draft session (with screenshot) -> Option+D stops and drafts -> Option+D during review cancels
- **Dictation routing:** Option+Space starts dictation (no screenshot) -> Option+Space stops and pastes
- **Cross-mode switching:** Option+D during active dictation cancels dictation and starts draft session; Option+Space during active draft cancels session and starts dictation
- **Vision race condition:** Speak quickly (< 2s) after Option+D -> debug log should show `"vision complete"` BEFORE `"streaming draft"`, with `context: yes`
- **Vision timeout:** If vision takes > 8s, fallback prompt fires -> draft should still appear (without context)
- **Hotkey capture:** Open Slack/iMessage -> press Option+D -> check debug log for vision processing
- **Source app stored:** After capture, paste-back should target the correct app
- **Permission denied:** If Screen Recording permission is missing, should show error message (not crash)
- **Parse accuracy:** Check that `CapturedContext.parse()` correctly splits the labeled sections — `platform` should be lowercase, `talkingTo` should be the name from the header (not from message content)
- **Debug log:** `tail -f ~/draft-debug.log | grep "SESSION\|VISION"` shows all capture/session events
