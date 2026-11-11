# Dictation display selection: owner decision

Status: unselected proposal for REVIEW.md item UI-OVERLAY-A-2. No placement,
microphone-start, Accessibility, permission, or telemetry behavior changes.

## What needs a decision

The island currently tries to appear on the display containing the destination
app's focused text field. Finding that field can delay the starting island and
the later microphone-start work. Choose the desired placement and latency
contract before changing which display a person sees it on.

## Current source evidence

Reviewed against main at `8a38235eef00816a79daa1324387a21ef880204d`.

- `NotchIslandController.currentScreen()` returns its cached screen while the
  island is shown. An uncached choice asks for a focused field only when
  dictation opens the island and more than one display exists.
- `NotchIslandScreenChoice` in `NotchIslandGeometry.swift` prefers the field's
  center, then the pointer's display, then the main or first display. The
  controller keeps that display for the show. This is not a lookup on every
  dictation start regardless of current visibility or display count.
- `focusedFieldRect()` calls the main-actor `AccessibilityBridge` synchronously
  for the target app, or a frontmost non-Transcripted app fallback. The bridge
  rejects secure fields and returns nil when access or a usable field is absent.
- The bridge sets a two-second messaging timeout on the app element and the
  focused element. Multiple AX messages are involved; that is not a measured
  two-second end-to-end startup budget.
- The start-admission path calls `showStartingIsland` synchronously before
  returning its decision to the later recording path. When the uncached display
  lookup is reached there, its time is on that start path.

No Accessibility call, target-app query, display inventory, microphone operation,
or startup measurement was performed for this source review. The frequency and
size of the delay on real multi-display setups remain unmeasured.

## Choose the placement contract

All options remain unselected; the owner may revise them.

- [ ] A. Preserve focused-field placement and measure the separate display-lookup
      and microphone-start stages first. Use the results to decide whether a
      latency change is warranted without assuming every start pays this cost.
- [ ] B. Show immediately on the pointer's display with the main-display
      fallback. Explicitly decide whether it must stay there or may move after
      a later focused-field result before implementing that visible change.
- [ ] C. Use a bounded background lookup or fresh cached field location. Define
      freshness, target-app and take ownership, deadline, fallback, and whether
      late results may move the island. Never let an older lookup relocate a
      newer take or reuse another app's field.

Owner conditions: pending, including acceptable startup delay, screen priority,
and whether placement may change during a show.

Preserve secure-field rejection, permission fallbacks and actual paste-target
resolution. An overlay's position does not prove pasteback succeeded. Any new
worker path needs reviewed isolation and ownership; moving the existing
main-actor helper into a detached task is not an implementation design by itself.

Validate the chosen behavior on single and multiple displays with responsive,
slow and unavailable target apps, stale lookups and a changed target. Use approved
aggregate timing evidence; do not export focused text or private app/window data.
This worksheet does not select a policy or complete UI-OVERLAY-A-2.
