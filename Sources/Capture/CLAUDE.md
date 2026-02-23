# Screen Capture & Context Extraction

## What This Does

Captures a screenshot of the user's current app window, sends it to Haiku Vision to extract the full conversation thread, and stores the source app reference for paste-back. Triggered by a global hotkey (Option+Space) that works from any app. In v2, the hotkey callback routes through `DraftSessionController` for three-way session control (start/stop/cancel).

## Key Files

- `ContextCaptureEngine.swift` — Hotkey registration (Carbon), screenshot capture, three-way routing to DraftSessionController, legacy `processCapture()` for compatibility
- `CapturedContext.swift` — Structured data extracted from a screenshot (platform, talkingTo, formality, conversation) + parser + prompt builder
- `ScreenCapture.swift` — Low-level window capture via CGWindowListCreateImage

## How It Works (v2 — Floating Overlay)

1. **Hotkey fires** — Carbon `RegisterEventHotKey` intercepts Option+Space at OS level
2. **Synchronous capture** — The C callback captures TWO things IMMEDIATELY (before any async dispatch):
   - `frontApp` — the `NSRunningApplication` reference (stored for paste-back later)
   - `imageData` — the screenshot PNG of that app's frontmost window
3. **Three-way routing** — `Task { @MainActor }` checks `DraftSessionController` state and routes:

| Session State | ⌥Space Action |
|---------------|---------------|
| Not in session | `startSession(imageData:sourceApp:)` — shows overlay, starts voice + vision in parallel |
| Listening/drafting/streaming | `stopSessionAndDraft()` — stops voice, awaits vision, streams draft |
| Review | `cancelSession()` — hides overlay, discards draft |

4. **Vision runs in parallel** — `DraftSessionController.startSession()` fires vision processing as a parallel `Task` stored as `visionTask`. Voice recording runs simultaneously.
5. **Vision awaited before drafting** — `stopSessionAndDraft()` calls `await visionTask?.value` before checking `lastCapturedContext`, ensuring vision results are available even when the user speaks quickly.

## Hotkey IDs

- **ID 1** — ⌥D (Draft mode): screenshot + voice + AI rewrite + review
- **ID 2** — ⌥Space (Dictation mode): voice only → light polish → auto-paste

Both use signature `0x44524654` ('DRFT').

## Critical Design Decision: Sync Capture in C Callback

The screenshot AND the frontmost app reference MUST be captured synchronously inside `hotkeyHandler()` before any `Task { @MainActor }` dispatch. If deferred to async, macOS shifts window focus to Draft, and you capture Draft's own window instead of the target app. The stored `sourceApp` would also be wrong.

```swift
private func hotkeyHandler(...) -> OSStatus {
    // hotkeyID.id == 1: ⌥D (Draft)
    let frontApp = NSWorkspace.shared.frontmostApplication
    let imageData = frontApp.flatMap { ScreenCapture.captureFrontmostWindow(of: $0) }
    Task { @MainActor in
        guard let session = _sharedSessionController else { return }
        if session.isInSession {
            if session.overlayController?.state == .review {  // Optional chaining — overlayController is Optional
                session.cancelSession()
            } else {
                session.stopSessionAndDraft()
            }
        } else {
            session.startSession(imageData: imageData, sourceApp: frontApp)
        }
    }
    return noErr
}
```

### Global References

The C callback can't capture Swift closures, so two `weak` module-level references bridge the gap:
- `_sharedEngine` — set by `registerHotkey()`, used for legacy `processCapture()` path
- `_sharedSessionController` — set via `ContextCaptureEngine.sessionController` didSet, used for v2 routing

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
    var talkingTo: String?      // "Sarah Graham" — from the conversation header/title bar
    var formality: String?      // "casual", "professional", "formal"
    var conversation: String?   // Full conversation thread text (all messages, all participants)

    var hasConversation: Bool   // True if conversation is non-empty
    var displayText: String     // Transparent labeled sections for the UI TextEditor
    func draftingPrompt(userInstructions: String) -> String  // Assembles full prompt for DraftEngine
    static func parse(from text: String) -> CapturedContext  // Parses Haiku's plain-text response
}
```

**`displayText`** shows the user exactly what was captured — transparent labeled sections (PLATFORM, TALKING TO, FORMALITY, CONVERSATION) so there's no mystery about what Draft "sees."

**`draftingPrompt()`** assembles the full drafting prompt with conversation context + user's voice instructions as separate labeled sections, followed by a 6-rule INSTRUCTIONS block: (1) instruction type awareness — handles specific intent, tone directives, or a mix; (2) conversation is background context for the reply; (3) match conversational energy/length; (4) no parroting back what the other person said; (5) no AI fluff (unnecessary greetings, sign-offs, exclamation points); (6) output only the reply text, no labels or explanations.

**`parse()`** is a line-by-line parser using `hasPrefix` checks. An `inConversation` flag captures everything after the "CONVERSATION:" header until end of text.

## Legacy Interface: `processCapture()`

`processCapture(imageData:sourceApp:)` is the v1 capture pipeline that runs vision extraction directly and calls `onContextCaptured`. It is **preserved for compatibility** but unused in the v2 floating overlay flow — `DraftSessionController` handles vision processing internally. The `onContextCaptured` and `onHotkeyFired` callbacks are marked as legacy.

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

### Optional Chaining for overlayController

Since `DraftSessionController.overlayController` is now `Optional` (not IUO), the hotkey callback uses `session.overlayController?.state` with optional chaining.

## Hotkey Details

- **Draft shortcut:** Option+D (`optionKey`, `kVK_ANSI_D`) — hotkey ID 1
- **Dictation shortcut:** Option+Space (`optionKey`, `kVK_Space`) — hotkey ID 2
- **Registration:** Carbon `RegisterEventHotKey` with signature `0x44524654` ('DRFT')
- **Why Carbon:** `NSEvent.addGlobalMonitorForEvents` is a passive observer — apps can consume events before the monitor sees them. Carbon hotkeys intercept at OS level (same mechanism as Alfred/Raycast).

## Screen Recording Permission

`CGWindowListCreateImage` requires Screen Recording permission. If not granted, capture returns nil and shows an error. The user must manually grant permission in System Settings → Privacy & Security → Screen Recording. Rebuilding the app may revoke permission (new code signature).

## Public Interface

```swift
// ContextCaptureEngine
@Published var isCapturing: Bool
@Published var capturedContext: CapturedContext?
@Published var captureError: String?
@Published var sourceApp: NSRunningApplication?  // The app that was screenshotted

var onContextCaptured: ((CapturedContext) -> Void)?  // Legacy — unused in v2
var onHotkeyFired: (() -> Void)?                     // Legacy — unused in v2
var promptStore: PromptStore?                        // Set by DraftAppState — provides model + context extraction prompt
var sessionController: DraftSessionController?       // Set by DraftAppDelegate — wires hotkey to v2 session

func registerHotkey()
func unregisterHotkey()
func processCapture(imageData: Data?, sourceApp: NSRunningApplication?) async  // Legacy v1 path
func manualCapture(app: NSRunningApplication?) async

// ScreenCapture
static func captureFrontmostWindow(of app: NSRunningApplication) -> Data?
```

## Verification

After modifying capture or context extraction, verify with these checks:

- **Three-way routing:** ⌥Space starts session → ⌥Space stops and drafts → ⌥Space during review cancels
- **Vision race condition:** Speak quickly (< 2s) after ⌥Space → debug log should show `"vision complete"` BEFORE `"streaming draft"`, with `context: yes`
- **Vision timeout:** If vision takes > 8s, fallback prompt fires → draft should still appear (without context)
- **Hotkey capture:** Open Slack/iMessage → press ⌥Space → check debug log for vision processing
- **Source app stored:** After capture, paste-back should target the correct app
- **Permission denied:** If Screen Recording permission is missing, should show error message (not crash)
- **Parse accuracy:** Check that `CapturedContext.parse()` correctly splits the labeled sections — `platform` should be lowercase, `talkingTo` should be the name from the header (not from message content)
- **Debug log:** `tail -f ~/draft-debug.log | grep "SESSION\|VISION"` shows all capture/session events
