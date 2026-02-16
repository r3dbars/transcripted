# Screen Capture & Context Extraction

## What This Does

Captures a screenshot of the user's current app window and sends it to Haiku Vision to extract conversation text. Triggered by a global hotkey (Ctrl+Option+D) that works from any app.

## Key Files

- `ContextCaptureEngine.swift` — Hotkey registration, screenshot orchestration, API call
- `ScreenCapture.swift` — Low-level window capture via CGWindowListCreateImage

## How It Works

1. **Hotkey fires** — Carbon `RegisterEventHotKey` intercepts Ctrl+Option+D at OS level
2. **Synchronous screenshot** — The C callback captures the frontmost window IMMEDIATELY (before any async dispatch), using `NSWorkspace.shared.frontmostApplication` to get the correct app
3. **Async processing** — `Task { @MainActor }` sends the screenshot to Haiku Vision API
4. **Context delivered** — `onContextCaptured` callback fills ContentView's input with extracted text
5. **Draft activates** — `NSApplication.shared.activate()` brings Draft to front

## Critical Design Decision: Sync Capture in C Callback

The screenshot MUST happen synchronously inside `hotkeyHandler()` before any `Task { @MainActor }` dispatch. If deferred to async, macOS has time to shift window focus to Draft, and you capture Draft's own window instead of the target app. This was the hardest bug to find.

```swift
private func hotkeyHandler(...) -> OSStatus {
    // CORRECT: capture NOW while target app is still frontmost
    let frontApp = NSWorkspace.shared.frontmostApplication
    let imageData = frontApp.flatMap { ScreenCapture.captureFrontmostWindow(of: $0) }
    Task { @MainActor in
        await _sharedEngine?.processCapture(imageData: imageData)
    }
    return noErr
}
```

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
@Published var capturedContext: String
@Published var captureError: String?
var onContextCaptured: ((String) -> Void)?

func registerHotkey()
func unregisterHotkey()
func processCapture(imageData: Data?) async
func manualCapture(app: NSRunningApplication?) async

// ScreenCapture
static func captureFrontmostWindow(of app: NSRunningApplication) -> Data?
```
