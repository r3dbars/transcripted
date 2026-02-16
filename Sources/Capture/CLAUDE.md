# Screen Capture & Context Extraction

## What This Does

Captures a screenshot of the user's current app window, sends it to Haiku Vision to extract the full conversation thread, and stores the source app reference for paste-back. Triggered by a global hotkey (Ctrl+Option+D) that works from any app.

## Key Files

- `ContextCaptureEngine.swift` — Hotkey registration, screenshot orchestration, API call, source app storage
- `CapturedContext.swift` — Structured data extracted from a screenshot (platform, talkingTo, formality, conversation) + parser + prompt builder
- `ScreenCapture.swift` — Low-level window capture via CGWindowListCreateImage

## How It Works

1. **Hotkey fires** — Carbon `RegisterEventHotKey` intercepts Ctrl+Option+D at OS level
2. **Synchronous capture** — The C callback captures TWO things IMMEDIATELY (before any async dispatch):
   - `frontApp` — the `NSRunningApplication` reference (stored for paste-back later)
   - `imageData` — the screenshot PNG of that app's frontmost window
3. **Parallel activation** — `Task { @MainActor }` brings Draft to front AND fires `onHotkeyFired` callback (ContentView uses this to start voice recording in parallel with vision processing)
4. **Vision processing** — Screenshot sent to Haiku Vision with user's name and app name as hints
5. **Context parsed** — Haiku's plain-text response → `CapturedContext.parse()` → structured data
6. **Context delivered** — `onContextCaptured` callback fills ContentView's input with labeled sections

## Critical Design Decision: Sync Capture in C Callback

The screenshot AND the frontmost app reference MUST be captured synchronously inside `hotkeyHandler()` before any `Task { @MainActor }` dispatch. If deferred to async, macOS shifts window focus to Draft, and you capture Draft's own window instead of the target app. The stored `sourceApp` would also be wrong.

```swift
private func hotkeyHandler(...) -> OSStatus {
    // CORRECT: capture BOTH while target app is still frontmost
    let frontApp = NSWorkspace.shared.frontmostApplication
    let imageData = frontApp.flatMap { ScreenCapture.captureFrontmostWindow(of: $0) }
    Task { @MainActor in
        await _sharedEngine?.processCapture(imageData: imageData, sourceApp: frontApp)
    }
    return noErr
}
```

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

**`draftingPrompt()`** assembles the full drafting prompt with conversation context + user's voice instructions as separate labeled sections. Explicitly tells Haiku that USER'S INSTRUCTIONS are highest priority.

**`parse()`** is a line-by-line parser using `hasPrefix` checks. An `inConversation` flag captures everything after the "CONVERSATION:" header until end of text.

## Hotkey Details

- **Shortcut:** Ctrl+Option+D (`controlKey | optionKey`, `kVK_ANSI_D`)
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

var onContextCaptured: ((CapturedContext) -> Void)?  // Fires when vision processing completes
var onHotkeyFired: (() -> Void)?                     // Fires immediately on hotkey (before vision)

func registerHotkey()
func unregisterHotkey()
func processCapture(imageData: Data?, sourceApp: NSRunningApplication?) async
func manualCapture(app: NSRunningApplication?) async

// ScreenCapture
static func captureFrontmostWindow(of app: NSRunningApplication) -> Data?
```

## Verification

After modifying capture or context extraction, verify with these checks:

- **Hotkey capture:** Open Slack/iMessage → press ⌃⌥D → check debug log for `📸 CONTEXT RAW` showing platform, talkingTo, formality, and conversation text
- **Source app stored:** After capture, the "Paste to [App]" button should show the correct app name
- **Manual capture:** Click "Capture Screen" button → should capture the previous app (not Draft itself)
- **Permission denied:** If Screen Recording permission is missing, should show error message (not crash). Look for `❌ CAPTURE ERROR` in debug log
- **Parse accuracy:** Check that `CapturedContext.parse()` correctly splits the labeled sections — `platform` should be lowercase, `talkingTo` should be the name from the header (not from message content)
- **Console output:** `🔍 VISION RAW RESPONSE` in Xcode/terminal console shows the full Haiku Vision response for debugging prompt issues
