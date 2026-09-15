# Issue 1734: selected USB microphone startup

Status: implemented locally; physical customer resolution unconfirmed.
Date: 2026-09-14. Base: `origin/main` / `v1.1.59`,
`6c85575631cfe942e040f22fa57cad28abcb3a95`.
Branch: `codex/issue-1734-usb-input-settle`.

## Finding and release comparison

[Issue #1734](https://github.com/r3dbars/transcripted/issues/1734) reports
“Switching mic” followed by “Selected mic unavailable” after the hotkey with
a Logitech C920 on 1.1.59. The report has no diagnostic attachment. That UI
message is a generic readiness timeout, not a unique binding-failure signature.

`DictationInputDeviceBindingPolicy.apply` rejected a successful route command
when the immediately reread AUHAL device ID was stale. Its only production
caller, `ParakeetEngine.audioInputSnapshot`, already waits 300 ms after a
successful change and strictly verifies the selected physical device. The
premature throw prevents reaching that intended settling phase.

- `v1.1.58` is `efb55246414e5b2587fc94b95f71bffca51d3bfb`.
  Both release tags contain the immediate verification. It originated in
  `79f94e9611baa77373d2873b8bbc7c2ada3e959b` before 1.1.58; 1.1.57 lacked it.
- The selected-input/AirPods fix `4c67ef26` (#1726) makes ordinary dictation
  follow the Mac-selected input and accepts matched Bluetooth speech rates
  in the suppressed-fallback recovery case.
  A USB C920 remains `defaultIsSafe` under both releases; its format policy
  did not change.
- `65d248d7` (#1728) releases Apple voice processing during stop and cleanup
  and may discard a graph that cannot release it. This could change binding
  frequency or timing if Apple voice processing was enabled. That is a
  hypothesis, not evidence from this reporter. Pre-snapshot voice-processing
  unwrapping already existed in 1.1.58.
- Baseline binding failures retain the graph and schedule a prewarm retry.
  A delayed driver update might therefore succeed on a later baseline attempt.
  The focused reproduction proves premature rejection, not a persistent
  1.1.58-to-1.1.59 customer timeout.

[Existing draft #1735](https://github.com/r3dbars/transcripted/pull/1735)
proposes the same minimal production repair. Its source-level reproduction
was independently checked here; its C920 explanation is not hardware proof.

## Patch and preserved behavior

Reject target ID zero before touching the driver. After a successful route
command, return `true` so the caller reaches its existing delay and strict
verification. The return value means a command was issued, not readiness.

No timing budgets, device-selection defaults, audio formats, voice-processing
preferences, fallback routes, graph ownership, or Mac-wide input writes change.
Unchanged bindings still receive immediate verification. Driver errors
propagate; stale or zero device IDs after settling still fail closed.

## Verification

- Verification host: Apple Silicon, macOS 27.0, Apple Swift 6.3.3. The reported
  customer environment is macOS 26.4.1; this host is not an exact OS match.
- Focused harness compiles the real policy and preference sources with
  `Tests/TestHelpers.swift` and `Tests/DictationInputDeviceSelectionPolicyTests.swift`.
  A temporary `main.swift` invokes `testDictationInputDeviceSelectionPolicy()`
  and exits nonzero when `failedTests` is nonzero. Run binaries with
  `TRANSCRIPTED_DISABLE_FILE_LOGGER=1`.
- Pinned 1.1.59 policy with the new tests: **95/106 passed; 11 failed**.
  Ten failed assertions expose the premature rejection in the delayed-binding
  matrix; one exposes writing an unknown target to the driver.
- Candidate policy with the same tests: **106/106 passed**. The fake covers
  old-device and zero initial IDs, successful delayed selection, permanently
  stale and disconnected settled IDs, and unknown targets. Existing cases
  retain driver-error, settled no-write, USB, and Bluetooth selection coverage.
- Independent full-diff review against `origin/main`: **no actionable findings**.
  Reviewer traced the sole caller, strict settled verification, ownership,
  cancellation, error handling, and test coverage.
- `bash scripts/dev/agent-preflight.sh` and `git diff --check`: passed.
- `bash build-deps.sh --force`: passed after the initial app build reported
  stale local dependencies.
- `TRANSCRIPTED_SKIP_LAUNCH_SMOKE=1 bash build.sh --no-open`: passed, including
  app compilation, signing, and build performance budget. Launch smoke was
  deliberately skipped to leave the running app and a concurrent UI test alone.
- Full fast suite: **13,058/13,058 passed, zero failures**. The unmodified
  runner was invoked with caching disabled and a temporary `swiftc` wrapper
  that executes `xcrun swiftc -target arm64-apple-macos26.0 "$@"`. The installed
  Swift 6.3.3 defaults to macOS 28 even on this macOS 27 host; the wrapper
  matches production's explicit macOS 26 target without changing test scripts.

## Remaining proof and workspace preservation

No C920 was found in this Mac's audio-device inventory. No physical C920
capture, target-app paste, AirPods capture, Zoom receiver audio, or exact
reporter-environment reproduction was performed. The running app was not
replaced or relaunched. This is not a release-readiness claim.

For hardware confirmation, use the same C920 and settings, compare 1.1.59
with this candidate across cold starts, repeated dictation, input switching,
and unplug/reconnect. Confirm actual samples and final text, not just a ready
indicator. Preserve the selected-input behavior and test a route that remains
unavailable. Correlate local binding/settling diagnostics if failure persists.

The initial working tree was clean. The original
`fix/zoom-mic-share-while-transcripted-running` branch and its two commits above
the common ancestor remain intact at `0e9669de3e83f01b564949787ba0b090ec8cb29c`.
The owner subsequently authorized opening a draft PR for this work. No merge,
release, issue comment, or reporter contact was performed.
