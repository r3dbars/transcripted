# Browser focus semantics: owner decision pending

Unselected worksheet for MEETING-A-4. This document changes no browser
reading, prompt, auto-record, or permission behavior.

## Current source boundary

Reviewed main: `8a38235eef00816a79daa1324387a21ef880204d`. These are source
observations, not a live browser or Accessibility result.

`BrowserWindowTitleReader.windowTitles` sets `isFocused` only when the
browser is the frontmost app and the window is its AX-focused window. In
the focused-window-only fallback, it likewise requires the frontmost app.
Its `isSystemFront` values express that same frontmost-window condition.
The reader therefore does not currently produce the test combination
`isFocused: true, isSystemFront: false`.

`BrowserWindowTitle.isFocused` nevertheless documents a browser's internal
AX focus even when the browser is in the background. Two tests construct
that combination: one rejects it as auto-record proof while allowing a
named Meet title to prompt, and one classifies a background focused
non-call title as `.notCall`. They exercise the pure classifier with
synthetic inputs; they do not demonstrate what the actual reader emits.

The classifier can recognize an in-call title from any returned window,
regardless of focus. Ordinary call-site/non-call titles require `isFocused`.
Auto-record's focused title proof separately requires `isSystemFront`.
`claimedCallShortcut` also distinguishes a frontmost shortcut or recent
activation near microphone admission; the detector restricts that claim to
the browser family holding the microphone. Any change must retain that
shortcut ownership rule and the non-call veto behavior intentionally chosen.

Sources: [reader](../Sources/Meeting/BrowserWindowTitleReader.swift),
[value and classifier](../Sources/Meeting/BrowserCallEvidence.swift),
[detector adapter](../Sources/Meeting/MeetingPromptDetector+BrowserEvidence.swift),
and [tests](../Tests/BrowserCallEvidenceTests.swift).

## Choices for Justin

- [ ] **A — Keep the current frontmost focus rule.** Correct the value's
  documentation and rewrite the misleading background-focus test contract
  around reader-reachable inputs. Decide separately whether to retain both
  focus fields for their distinct consumers; do not remove one implicitly.
- [ ] **B — Distinguish internal browser focus from system focus.** Have the
  reader emit internal AX focus as `isFocused`, keeping `isSystemFront`
  frontmost-only. Specify how background non-call titles interact with
  shortcut ownership and prompting before implementing this behavior change.
- [ ] **C — Revise the intended behavior or scope.**

No choice is selected. Record / dismiss / remind and automatic meeting
detection remain protected product surfaces; this worksheet does not
approve changing them.

## Proof after a choice

Cover the actual adapter's focus-value construction with deterministic inputs:
frontmost/background browser, focused/other window, unavailable frontmost PID,
and focused-window fallback. Exercise named call, ordinary call-site,
non-call and unknown classification separately from auto-record proof.
Include a shared browser-helper shortcut with foreground and recent-activation
claims, plus an unrelated browser family. Review the complete wiring and
fixture isolation before execution. Native AX access, permissions and actual
browser focus need a separate manual check; pure classifier tests cannot
prove them.

No browser, AX permission, meeting capture, preference store or native app
was accessed for this worksheet. No test was run or rewritten.
