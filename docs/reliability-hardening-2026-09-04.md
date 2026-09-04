# Speaker saving, audio shutdown, and Bluetooth dictation reliability

Status: implemented and independently reviewed. Full automated QA passed. Human PR review and affected hardware verification remain outstanding; this is not a release.

## Problems and behavior

| Trigger | Previous behavior | Result with this change |
| --- | --- | --- |
| Several diarizer rows share one source profile and merge into the same person | Second merge tries to consume an already removed profile; names fail to save | Merge the profile once; update every transcript row |
| Speaker finalization fails on a first-pass meeting | Review closes without a durable failed row; scratch cleanup may run | Retain available audio and persist a retry with original date/title and split-speaker setting |
| Retry queue cannot be written | Recovery may be inaccessible | Leave source audio in place and report queue persistence failure |
| Old naming callback fails after replacement | Stale failure can publish over newer state | Reject superseded failure publication |
| Native microphone stop blocks | System cancellation waits behind it | Stop each backend independently; finalize only after both writer queues and host-buffer drain finish |
| Optional persistent input maintenance runs during another app's capture | Global default input can change during that capture | Defer on external input activity or unknown activity, including at shutdown |
| A graph pinned to built-in later follows a different default | Selected route and actual AUHAL binding can disagree | Rebind when necessary and verify physical input before reporting readiness |
| Another route notification arrives during recovery | Restart intent was consumed by the older task | Retain intent until the current generation reaches a terminal outcome |
| Reconnect recovery fails after speech was captured | Some terminal paths discard earlier speech | Retain audio for explicit recovery; clear restart intent before publishing interruption |
| A tap delivers both 48 kHz and 24 kHz buffers | Flat samples can all be resampled at the final rate | Keep per-segment rates, trim by duration, and share one resampling path |

The flat dictation sample buffer and duplicate final-resampling branch were removed. Existing microphone selection, bounded retry budgets, same-route continuity checks, voice-processing preference, and no-per-session-global-input-write contracts remain.

## Historical fixes checked

- [#1702](https://github.com/r3dbars/transcripted/pull/1702): remove per-session Mac-wide input writes and fake Bluetooth prewarm.
- [#1618](https://github.com/r3dbars/transcripted/pull/1618): same-route continuity, 24/48 kHz settling, and bounded restart recovery.
- [#1483](https://github.com/r3dbars/transcripted/pull/1483): Bluetooth readiness and silence versus missing callback recovery.
- [#1387](https://github.com/r3dbars/transcripted/pull/1387), [#939](https://github.com/r3dbars/transcripted/pull/939), [#942](https://github.com/r3dbars/transcripted/pull/942): graph rebuild loops, timeouts, and built-in fallback.

## Automated verification

- Forced native dependency rebuild passed for the core changes.
- Full QA bench: 15/15 checks passed on the combined candidate.
- App build, launch-performance budget, deterministic E2E, slow pasteback, and app/core integration passed.
- Fast suite: 12,557 assertions passed, zero failures.
- Core suite: 1,079 tests, 13 opt-in tests skipped, zero failures. Skips require live capture, unstaged model/audio fixtures, or private corpus data.
- QA package: 65 tests passed.
- Artifact round trip, small stress test, imported-audio artifact smoke, synthetic audio reliability, release-health fixtures, and PostHog task fixtures passed.
- Independent full-diff review against main approved after correcting stale failure ownership and separating retained audio from restart intent.

## Additional runtime performance finding

The opt-in runtime budget check failed against the existing mixed-version, last-two-weeks local log: stop-to-paste p95 was 2050 ms (ceiling 850 ms), and the stop pipeline p95 was 2206 ms (ceiling 1100 ms). Decode was the slowest reported stage (p95 1134 ms). The build script explicitly treats these ambient logs as observations of previously running binaries, not measurements of the candidate being built. No thresholds were raised. Candidate-specific latency measurement remains outstanding.

## Remaining proof and constraints

Automated policy/buffer tests and source wiring contracts do not establish real Bluetooth driver behavior. Before calling the affected hardware paths verified, exercise repeated dictation with Bluetooth playback, built-in/USB/headset input selection, 24/48 kHz transitions, disconnect/reconnect during speech, stop during recovery, and Zoom coexistence. Confirm accurate transcripts, no lost prefix, no unintended restart, and no playback disturbance.

The reported Zoom microphone takeover is not reproduced or attributed conclusively. Native backend hangs cannot be forcibly interrupted by the new independent cleanup scheduler; existing timeout/journal recovery still applies. External input checks and a subsequent global route write cannot be atomic with another app starting capture.

Conflicting/dependent speaker merge plans remain safe failures with retry rather than automatic identity-graph reconciliation. Retry rebuilds the meeting; typed speaker choices are not separately persisted for naming-only replay.

No raw audio, transcripts, device identifiers, credentials, or customer diagnostics are included. No version bump, installation replacement, merge, or publication is part of this change.
