# Code Review — Draft v0.1 (Archived)

> **Note:** This review is from v0.1 (Feb 2026) when Draft used cloud APIs. Many referenced files (`AnthropicAPI.swift`, `SpeechEngine.swift`, `AuthCredential.swift`) no longer exist. Draft is now fully local with on-device MLX inference. Kept for historical reference only.

**Date:** 2026-02-23
**Reviewer:** Claude Code (automated)
**Scope:** Full codebase review of all Swift sources in `Sources/`
**Overall:** Solid, production-ready architecture with a few fixable issues

---

## Critical

### 1. Memory Leak — Timer Retain Cycle
**File:** `Sources/Speech/SpeechEngine.swift`
**Issue:** The silence timer's closure uses `[weak self]`, but the inner `Task` recaptures `self` strongly, creating a retain cycle that leaks `SpeechEngine` instances across sessions.

```swift
// Current (leaks)
silenceTimer = Timer.scheduledTimer(...) { [weak self] _ in
    Task { @MainActor in
        self?.commitVolatileOnSilence()  // Task captures self strongly
    }
}

// Fix
silenceTimer = Timer.scheduledTimer(...) { [weak self] _ in
    Task { @MainActor [weak self] in
        self?.commitVolatileOnSilence()
    }
}
```

- [x] Fix retain cycle in silence timer
- [x] Audit `doneTimer` for the same pattern
- [x] Fix retain cycle in `handleRecognitionResult` success + error paths

---

### 2. Race Condition — Rapid Hotkey Presses
**File:** `Sources/Capture/ContextCaptureEngine.swift:37-52`
**Issue:** Multiple fast Option+Space presses can hit the `if session.isInSession` check before the previous state transition completes, leading to unexpected behavior.

```swift
Task { @MainActor in
    if session.isInSession {  // State could change between check and action
        if session.overlayController.state == .review {
            session.cancelSession()
        } else {
            session.stopSessionAndDraft()
        }
    }
}
```

- [ ] Add debounce guard or make state transitions atomic
- [ ] Consider a minimum interval between hotkey actions (~200ms)

---

### 3. Force-Unwrap on Audio Format
**File:** `Sources/Speech/SpeechEngine.swift`
**Issue:** Force-unwrap will crash if format creation fails (possible with unusual audio hardware).

```swift
// Current (crashes on failure)
let monoFormat = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.sampleRate, channels: 1)!

// Fix
guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.sampleRate, channels: 1) else {
    log("AUDIO FORMAT | Failed to create mono format")
    return
}
```

- [ ] Replace force-unwrap with guard-let

---

## Important

### 4. File I/O on Main Thread
**File:** `Sources/Style/StyleEngine.swift`
**Issue:** `saveStyleFile()` runs on `@MainActor` and writes synchronously. As the style profile grows, this could cause UI hitches during streaming.

- [ ] Move file writes to a background queue
- [ ] Consider using `Task.detached` for I/O operations

---

### 5. Timer Invalidation Gaps
**File:** `Sources/Speech/SpeechEngine.swift`
**Issue:** `silenceTimer` and `doneTimer` are not always invalidated before reassignment, potentially leaving ghost timers that fire unexpectedly.

- [ ] Always call `.invalidate()` before reassigning timers
- [ ] Consider a helper: `replaceTimer(&timer, with: newTimer)`

---

### 6. Inconsistent Error Handling
**File:** `Sources/API/AnthropicAPI.swift`
**Issue:** Some methods throw `AnthropicAPIError`, others silently return `nil`. Callers can't distinguish "no result" from "network error" from "auth failure."

- [ ] Standardize on throwing errors for all API methods
- [ ] Reserve optionals for genuinely optional data, not error cases

---

## Suggestions

### 7. Magic Numbers
**Files:** `Sources/UI/FloatingOverlay.swift`, `Sources/Speech/SpeechEngine.swift`, `Sources/API/AnthropicAPI.swift`
**Issue:** Panel dimensions (480, 160, 340), silence thresholds (1.5, 2.5), vision timeout (8s) are inline constants.

- [ ] Extract to named constants or a config struct

---

### 8. Naming Conventions
**File:** `Sources/Capture/ContextCaptureEngine.swift:10-11`
**Issue:** `_sharedEngine` and `_sharedSessionController` use underscore prefix, unconventional in Swift.

- [ ] Rename to `sharedEngineRef` / `sharedSessionRef`

---

### 9. State Consolidation
**File:** `Sources/UI/FloatingOverlay.swift`
**Issue:** Multiple `@Published` properties could be grouped into state objects for cleaner SwiftUI architecture.

- [ ] Consider a `SessionState` struct to consolidate related published properties

---

## What's Done Well

- **Module separation** — Clean boundaries between Speech, API, Capture, Draft, Style, UI with dedicated CLAUDE.md per module
- **Keychain credential storage** — No hardcoded secrets, clean `AuthCredential` abstraction with two auth modes
- **Non-activating panel** — Dynamic `canBecomeKey` for different overlay states is sophisticated macOS development
- **Clipboard safety** — Save/set/paste/restore pattern prevents data loss on inject
- **Graceful speech engine** — Handles buffer resets, content shifts, and audio interface quirks (BEACN Mic mono workaround)
- **Externalized prompts** — `PromptStore` reads from JSON, analysis engine can improve prompts without recompilation
- **Documentation** — The CLAUDE.md system across all modules is exceptional for maintainability
