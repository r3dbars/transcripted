# UI Components

## What This Does

SwiftUI views for the Draft app — input area, voice controls, context capture, Draft button, polished output display, style profile viewer, style onboarding, and API key entry.

## Key Files

- `ContentView.swift` — Main app view with `ContentView` (owns all engines, onboarding gates) and `DraftTab` (the primary drafting interface)
- `StyleOnboardingView.swift` — 5-step onboarding flow: intro (name) → source choice → (iMessage preview OR paste samples) → profile result
- `APIKeyEntryView.swift` — Overlay shown on first launch to enter Anthropic API key
- `PreviousAppTracker.swift` — Tracks which app the user was in before switching to Draft
- `AppLogger.swift` — Debug logger with in-app log panel and file output

## App Launch Flow (Sequential Gates)

```
Launch
  ↓
Has API key? ──No──→ APIKeyEntryView (overlay)
  │ Yes
  ↓
Completed style onboarding? ──No──→ StyleOnboardingView (overlay)
  │ Yes
  ↓
Main App (TabView: Draft tab + Style tab)
```

Both gates are overlays on top of the TabView. Once cleared, they don't reappear (API key in Keychain, onboarding flag in UserDefaults).

## ContentView.swift Section Map (719 lines)

Use this to jump to the right area when modifying ContentView:

```
Lines   1-51   ContentView          — @StateObject engines, TabView, onboarding overlays, .task init
Lines  53-72   DraftTab (struct)    — @ObservedObject declarations, @State vars, @FocusState
Lines  74-301  DraftTab body        — Header, context bar, inputAreaView, voice indicator, controls, outputAreaView, debug log
Lines 302-404  .onChange handlers   — Speech sync (303-317), draft completion (318-329), input tracking (330-336), context capture wiring (338-404)
Lines 407-426  triggerAutoDraft()   — Parallel pipeline completion → auto-draft
Lines 428-464  inputAreaView        — Input TextEditor with placeholder, Enter key handler
Lines 466-544  outputAreaView       — Output TextEditor with Copy/Paste buttons, Enter key handler
Lines 546-571  triggerDraft()       — Manual draft trigger (Enter or button), context-aware vs. plain
Lines 573-604  Accept & Style       — acceptAndCopy(), acceptAndPasteToSourceApp(), recordAcceptedExample()
Lines 606-670  Paste to App         — pasteTargetApp, pasteToApp(), waitForActivation() polling
Lines 673-718  StyleProfileView     — Second tab showing style.md contents
```

`ContentView` owns all engines as `@StateObject` and wires them together:
- `SpeechEngine`, `DraftEngine`, `StyleEngine`, `AppLogger`, `PreviousAppTracker`, `ContextCaptureEngine`

`DraftTab` is an extracted struct that receives all engines as `@ObservedObject` and contains the main drafting UI.

## Layout Structure

```
┌─────────────────────────────────────────┐
│ Draft           [Capturing...]    ⚙️    │  ← Header + capture status + settings
├─────────────────────────────────────────┤
│ Context              [Capture Screen]   │  ← Context label + capture button + ⌥Space hint
├─────────────────────────────────────────┤
│ PLATFORM: Slack                         │
│ TALKING TO: Sarah Graham                │
│ FORMALITY: casual                       │  ← Input TextEditor with labeled context sections
│                                         │
│ CONVERSATION:                           │
│ Sarah: Hey, are you free for lunch?     │
│ You: ...                                │
│                                         │
│ YOUR INSTRUCTIONS:                      │
│ [voice transcription / typed text]      │
├─────────────────────────────────────────┤
│ 🔴 "listening text here..."             │  ← Voice indicator (when recording)
├─────────────────────────────────────────┤
│ [⌘R Record] [✨ Draft]        [Clear]  │  ← Controls
├─────────────────────────────────────────┤
│ Drafted Message     [Copy] [Paste to…] │
│ "Polished text from Haiku..."           │  ← Output area (purple tint, editable)
├─────────────────────────────────────────┤
│ ▶ Debug Log (N)                         │  ← Collapsible debug panel
└─────────────────────────────────────────┘
```

Second tab: **Style Profile** — shows style.md contents (summary + examples).

## Keyboard Shortcuts

- **Enter** (in input area) — Triggers Draft (sends to Haiku)
- **Enter** (in output area) — Pastes drafted message to source app
- **Shift+Enter** — Inserts newline (in both text areas)
- **⌘R** — Toggle Record/Stop voice input
- **Option+Space** — Global hotkey: capture screen context (works from any app)

### Enter Key Implementation

Uses `.onKeyPress(keys: [.return], phases: .down)` on both TextEditors. The `keys:phases:` variant is required (not the simpler `onKeyPress(.return)`) because it passes the full `KeyPress` object with `.modifiers` — needed to distinguish Enter from Shift+Enter.

Input and output TextEditors are extracted into `inputAreaView` and `outputAreaView` `@ViewBuilder` computed properties. This was necessary because Swift's type-checker couldn't handle the complexity of inline `.onKeyPress` closures within the main `body`.

### Auto-Focus Output

When `drafter.draftedText` changes (draft completes), `isOutputFocused` is set to `true` via `.onChange(of:)`, moving the cursor into the output TextEditor automatically. This enables the flow: speak → Enter → (draft appears) → cursor is already in output → edit → Enter → pasted.

## Source App Paste-Back

### How It Works

1. **Hotkey callback** stores `contextCapture.sourceApp` (the exact `NSRunningApplication` that was screenshotted)
2. **`pasteTargetApp`** computed property: returns `contextCapture.sourceApp ?? previousAppTracker.previousApp`
3. **Button label** shows the actual app name: "Paste to Messages", "Paste to Slack", etc.
4. **Paste flow:**
   - Copy text to `NSPasteboard`
   - Activate the target app via `app.activate()`
   - **Poll for activation** via `waitForActivation(of:attempt:then:)` — checks `app.isActive` every 100ms, up to 15 attempts (1.5s timeout)
   - Once active, simulate ⌘V via `CGEvent`
5. **Record example** — After pasting, calls `styleEngine.recordExample()` to save for style learning

### Why Polling Instead of Fixed Delay

A fixed 300ms delay was unreliable — app activation timing varies by system load, app state, and whether the app needs to come to the foreground from minimized. Polling `app.isActive` at 100ms intervals adapts to the actual activation speed.

## Parallel Voice + Vision Pipeline

When the hotkey fires:
1. `onHotkeyFired` callback starts voice recording immediately
2. Vision processing runs in parallel (takes 1-3 seconds)
3. When context arrives via `onContextCaptured`, it's injected into `inputText` as labeled sections
4. Voice transcription continues appending after "YOUR INSTRUCTIONS:" label
5. User can speak their instructions while Haiku is still analyzing the screenshot

## State Coordination

- Speech output syncs to `inputText` via `.onChange(of:)` — `finalTranscript` and `volatileText` both update the TextEditor
- Context capture fills `inputText` via `onContextCaptured` callback, prepends labeled sections
- `@FocusState` on both TextEditors for cursor management
- Style training pairs recorded when user hits Copy or "Paste to [App]" (AI draft vs. user's edited version + platform + edit distance)
- Style summary auto-regenerates via graduated frequency: every 3 examples early on (1-20), then every 5-10 once the profile stabilizes (determined by `styleEngine.shouldRefineNow()`)

## StyleOnboardingView

5-step flow as a full-screen overlay (two branching paths after source choice):

```
.intro → .sourceChoice → .imessagePreview (if iMessage) → .result
                       ↘ .samples (if manual paste)     → .result
```

1. **Intro** — Welcome message, name input field (saved to UserDefaults for vision identity)
2. **Source Choice** — Two cards: "Import from iMessages" (recommended, reads ~/Library/Messages/chat.db) or "Paste Samples Manually"
3a. **iMessage Preview** — Read-only ScrollView showing loaded messages, privacy notice, message count, "Analyze These Messages" button. Includes expandable "Add Slack, email, or other writing samples" section for supplementary paste — combined text is sent together for a richer profile. Handles errors: FDA denied (link to System Settings + retry), no database/empty (fallback to manual paste)
3b. **Samples** — Large TextEditor for pasting writing samples, word count indicator, "Build My Profile" button
4. **Result** — Shows generated profile, "Looks Good" to accept, "Add More & Regenerate" goes back to source choice

Uses `iMessageReader` actor for database access, `StyleEngine.importBulkSamples()` for analysis, and `StyleEngine.completeOnboarding()` on accept/skip.

## PreviousAppTracker

Observes `NSWorkspace.didDeactivateApplicationNotification` to remember the last non-Draft app. Used as fallback when no source app is stored from a hotkey capture:
- Manual capture button (captures previous app's window)
- Paste fallback if no hotkey capture happened

Hardcoded bundle ID fallback (`com.justinbetker.draft`) since `Bundle.main.bundleIdentifier` can be nil for swiftc-built apps.

## Auth Setup Flow

1. On launch, if `drafter.hasCredential` is false → `APIKeyEntryView` overlay appears
2. Overlay shows name input + segmented picker (API Key / Claude Subscription)
3. API Key tab: `SecureField` for `sk-ant-...` with prefix validation
4. Subscription tab: step-by-step instructions for `claude setup-token` + paste field
5. "Connect" saves to Keychain → overlay dismisses
6. Gear icon → popover shows current auth mode + "Switch Auth Method" → clears Keychain → overlay reappears

## Verification

After modifying UI components, verify with these checks:

- **Full flow:** ⌥Space over Slack → speak instructions → Enter → edit draft → Enter → message pasted back to Slack
- **Keyboard shortcuts:** Enter in input triggers draft, Enter in output triggers paste, Shift+Enter inserts newline in both, ⌘R toggles recording
- **Auto-focus:** After draft completes, cursor should be in the output TextEditor (ready for edit → Enter)
- **Parallel pipeline:** ⌥Space → speak → vision context should appear at top of input while voice text appends below "YOUR INSTRUCTIONS:"
- **Paste-back:** "Paste to [App]" button should show correct app name. Pasting should activate the target app and simulate ⌘V.
- **Onboarding gates:** Delete API key (gear → Reset) → API key overlay appears. Reset onboarding flag → style onboarding appears. Both block the main UI.
- **Style tab:** Shows style.md contents. After accepting drafts, example count badge should increment.
- **Debug log:** Expand the debug panel at the bottom → all events should be logged with timestamps. Also available at `~/draft-debug.log`
- **Build:** `bash build.sh` — must compile cleanly (only warning: CGWindowListCreateImage deprecation)
