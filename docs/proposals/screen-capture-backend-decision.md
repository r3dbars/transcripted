# Legacy ScreenCaptureKit backend: owner decision

Status: unselected proposal for REVIEW.md item CORE-AUDIO-6. This document
does not authorize deleting a backend or changing capture permissions.

## What the current source says

Reviewed against main at `8a38235eef00816a79daa1324387a21ef880204d`.

- `Audio`'s default system-audio factory constructs
  `CoreAudioSystemAudioCapture`. The app's system-audio permission requester
  constructs that backend too.
- The tracked constructors of `SCKAudioCapture` are in
  `Tests/TranscriptedCoreTests/AudioTests/SCKAudioCaptureInterleavingTests.swift`.
  It is an internal class, with deterministic stream-control seams for those
  tests. This is a source inventory, not evidence about the owner's running app.
- The header in `SCKAudioCapture.swift` incorrectly says CoreAudio was deleted
  and this is the only remaining backend. The Core agent guide already describes
  it as a legacy backend retained for regression tests.
- The same header claims audio-only output gives a narrower permission prompt.
  The Core guide warns that this implementation still enumerates shareable
  screen content. Audio-only output does not establish its TCC permission scope.
  No native permission experiment was run for this proposal.
- `AudioRecoveryTuning.SystemAudio` supplies this backend's restart limit and
  stall timeout. The enclosing file also owns active mic recovery policies and
  `AudioRecoveryTuning.Mic`; deleting the whole file would remove unrelated code.

## Choose the intended role

No option is selected. The owner can revise any option.

- [ ] A. Keep the legacy backend as an explicit regression-test implementation.
      Correct its header to identify the production CoreAudio factory and the
      test-only construction sites. Remove the unsupported permission claim.
      Keep its stream ownership, cleanup, and recovery tests.
- [ ] B. Retire the legacy implementation and its specific test seams. Remove
      the five files below, review the backend-specific tests for retirement or
      migration, and remove only recovery tuning proven exclusive to this
      implementation. Preserve useful shared-contract coverage against the
      production backend or injected fakes before retiring that coverage.
- [ ] C. Assign a different role. Specify its consumers, supported permission
      behavior, construction path, and required tests before changing code.

The five implementation files in option B are all under
`Sources/TranscriptedCore/Audio/`:

- `SCKAudioCapture.swift`
- `SCKAudioCapture+Recovery.swift`
- `SCKAudioCapture+StreamCleanup.swift`
- `SCKAudioCapture+Testing.swift`
- `SCKAudioCaptureSupport.swift`

## Boundaries for the implementation after a decision

Keep the production CoreAudio factory, system-audio permission flow, mic
selection and AirPods protections, and the shared `SystemAudioCaptureEngine`
contract. Audit all remaining consumers before removing support types, build
entries, framework linkage, or tests. Retiring this backend does not by itself
authorize removing ScreenCaptureKit from other features or changing Writing's
Screen Recording behavior.

Review the final diff independently and run its mapped checks and isolated
verification. Report builds, deterministic tests, and native permission or
hardware proof separately. This worksheet supplies no runtime or hardware proof.

Owner selection and any conditions: pending.
