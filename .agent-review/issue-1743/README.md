# Issue #1743 evidence

Base: freshly fetched `origin/main`, `350b5020` (1.1.60).
Original `/Users/redbars/transcripted` checkout left clean on its existing branch.
Fix worktree: `/Users/redbars/transcripted-issue-1743`.

## Findings

- Menu popover opening calls `NSApp.activate(ignoringOtherApps: true)` in
  `TranscriptedApp.showMainPopover`. Start Dictation then dismisses the popover,
  reactivates the source editor, and calls the shared session start.
- Global hotkeys call that session directly, with no preceding activation.
- Both paths use the same bounded microphone readiness/recovery loop. The
  existing ready-engine fast path already falls back to that loop.
- The exact reported text, "Mic wasn't ready yet. Nothing was recorded. Try
  again.", comes from `cancelPendingDictationStartAfterEarlyRelease`. It means
  a physical-key stop/release reached the controller while startup was pending.
  It does not identify a CoreAudio exception or prove CrowdStrike involvement.
  The issue does not specify push-to-talk versus hands-free mode.

## Change

Background hotkey starts show the existing starting panel, request activation,
wait for AppKit to report active (at most 500 ms), and restore the captured
editor before entering the existing microphone startup code. Menu, already-active,
and shared meeting-mic starts bypass this preparation. A refused activation
still falls through to the existing microphone readiness budget.

Paste target capture precedes activation. Cancel/release never admits a late
recording. Cleanup only restores while Transcripted is active, and a newer
preparation supersedes old cleanup. If cancellation arrives before macOS finishes
activation, bounded cleanup still observes that pending activation and restores
focus. The user can still intentionally cancel a pending push-to-talk start;
this change does not record audio after key release.

## Reproduction and validation

`Tests/DictationStartActivationTests.swift` uses an injected foreground-sensitive
mic: the original background start fails, the menu's foreground round trip
succeeds, and the production hotkey preparation makes the same simulated mic
ready. This is a deterministic reproduction of the reported readiness condition,
not an M5/Falcon hardware reproduction. Tests also cover refusal/timeout,
already-active starts, cancellation, late activation, supersession, and preserving
a third app's focus. Small source-contract assertions cover controller wiring;
they are not end-to-end capture tests.

`ActivationProbe.swift` runs the production preparation helper and production
`FloatingOverlayPanel` in a temporary native AppKit app, without microphone,
clipboard, model, telemetry, or production preference access. Launch it in the
background. `activation.json` records an accessory-app activation and editor
restoration. `cancelled-activation.json` records cancellation at 1 ms: preparation
is rejected but late activation still restores the original app. The latter
probe failed before the late-cancellation fix (activation arrived after cleanup,
leaving the probe frontmost) and passed after it.

Earlier windowless probes did not activate; including the actual starting panel
matches the production ordering. One intermediate focus probe did not observe
source restoration; a subsequent probe recording source/own/final process IDs
confirmed restoration. These are bounded observations, not a claim of a complete
macOS focus/Spaces matrix.

To run the saved cancellation probe, compile `ActivationProbe.swift` with
`Sources/UI/Overlay/DictationStartActivation.swift` and
`Sources/UI/Overlay/FloatingOverlayPanel.swift` using `swiftc -parse-as-library`.
Put the binary in a temporary `.app` with an Info.plist containing its
`CFBundleExecutable`, a unique `CFBundleIdentifier`, `CFBundlePackageType=APPL`,
and `LSUIElement=true`, then `open -g` that app. It writes
`/tmp/transcripted-1743-live-activation.json` and exits. For the normal-start
probe, remove the nested 1 ms cancellation task.

## Review and remaining proof

Independent agent review covered the full diff against the base and identified
the late-cancellation probe above. No merge, release, issue comment, or reporter
contact was performed. No low-level microphone routing or device choice changed.

The reporter's managed M5/Tahoe/Falcon setup is unavailable. Physical hotkey
capture, actual speech, paste-back, and foreground/background mic behavior on
that machine remain unverified. Before calling the customer issue resolved,
check hands-free start/stop from another editor, held push-to-talk, release while
starting, menu start then hotkey stop, and original-editor paste-back on that Mac.

The pre-fix cancellation probe values are transcribed from the captured tool
output in `cancelled-activation-before.json`; process IDs were omitted from both
before/after artifacts. The saved probe source is the cancellation variant.

## Completed checks

- `bash run-tests.sh --filter DictationStartActivation`: 37 assertions passed.
- Final `bash build.sh --no-open`: passed, including the isolated launch smoke;
  launch-to-interactive 604 ms against a 3,000 ms budget. Initial environment-only
  build skipped launch; this final build did not skip it.
- `python3 scripts/dev/check-build-source-lists.py`: passed.
- `bash -n run-tests.sh` and `bash -n scripts/entrypoints/run-tests.sh`: passed.
- `git diff --check`: passed.
- Independent review: passed after the late-cancellation repair. Focus activation
  completing beyond the 500 ms cap is outside the bounded native probe evidence.

Build, targeted/full test, and preflight logs are kept outside the build directory
at `/tmp/transcripted-1743-{build,targeted,tests,preflight}.log` so rebuilding does
not remove the evidence. The build reused copied dependency outputs whose input
SHA256 matched the current source; no original-checkout dependency was modified.

The normal native activation probe was rerun against the final helper with the
production non-key `FloatingOverlayPanel` and accessory activation policy. All
six checks in `activation.json` passed, including original-editor restoration.

Final `bash run-tests.sh`: **13,993 assertions passed, zero failures**. The native
1 ms cancellation probe was also rerun against the final helper: preparation
was rejected, actual activation was observed, and editor focus was restored.
