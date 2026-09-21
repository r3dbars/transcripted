# Audio-only permission proof

This standalone local AppKit probe uses Core Audio process taps. It does not
import ScreenCaptureKit, enumerate displays, request microphone permission,
save audio files, or transmit samples. It retains only a frame count and peak.
The prototype is not the production meeting backend.

Build from the repository root:

```sh
mkdir -p build/AudioOnlyProbe.app/Contents/MacOS
cp experiments/audio-only-probe/Info.plist build/AudioOnlyProbe.app/Contents/Info.plist
xcrun swiftc -module-cache-path /private/tmp/transcripted-audio-probe-module-cache -target arm64-apple-macos26.0 experiments/audio-only-probe/main.swift -o build/AudioOnlyProbe.app/Contents/MacOS/AudioOnlyProbe
codesign --force --sign - build/AudioOnlyProbe.app
```

Open the app, play audio in another app, and click **Test system audio only**.
Approve the system-audio request if needed. Verify the app appears only in the
lower **System Audio Recording Only** section of Privacy & Security →
Screen & System Audio Recording. A positive peak proves audio reached the
probe; silence is inconclusive, not proof of permission denial.

## Observed September 18, 2026

- Local probe completed its eight-second capture: 401,920 frames, peak 0.56187415.
- System Settings showed `AudioOnlyProbe` enabled under System Audio Recording
  Only and absent from the broader screen-recording list.
- Installed Transcripted 1.1.57 remained broad permission off, audio-only on;
  that older ScreenCaptureKit-based build had failed meeting permission preflight.

This proves the Core Audio route on this Mac. It does not prove production
meeting integration, another Mac, denied-permission handling, route changes,
sleep/wake, upgrade behavior, or release readiness.

## Production-backend and negative control

Compile the same app with `-D PRODUCTION_CAPTURE` and these additional inputs
to exercise production code rather than the prototype implementation:

- `Sources/TranscriptedCore/Audio/CoreAudioSystemAudioCapture.swift`
- `Sources/TranscriptedCore/Audio/CoreAudioTapBufferRing.swift`
- `Sources/TranscriptedCore/Audio/SystemAudioCaptureEngine.swift`

The initial production implementation received 383,488 frames at peak
0.54778624. With explicit owner approval, the probe's narrow permission was
disabled and **Quit & Reopen** applied. Capture still returned 383,488 frames,
but peak was 0.0. Re-enabling narrow permission and applying Quit & Reopen
restored audible capture: 383,488 frames, peak 0.47583646.

**Important:** successful start and frame delivery do not establish permission.
The denied tap supplies zero-filled buffers. A finite nonzero signal verifies
capture at that moment; zero-filled buffers are inconclusive because legitimate
silence is indistinguishable. Do not invent a permission-denied error from a
generic Core Audio status, use private TCC APIs, or request screen capture as a
fallback. These tests changed only the probe permission; Transcripted remained
audio-only enabled and broad screen access disabled.

## Intended rollout

- Every updated app uses the Core Audio backend.
- Existing users keep their existing permission settings; narrowing an old
  screen/audio grant is optional, not a forced migration.
- New installations request system audio only.
- No mandatory external playback step before each meeting. Silent capture is
  unverified, not a fresh permission grant; runtime silence warnings still apply.
- No release has been published by this experiment.

## Final local checks

After the cancellation/recovery review fixes, a timed built-in Glass chime was
captured by the production backend: 383,488 frames, peak 0.030471554. Quiet
attempts remained correctly inconclusive. Narrow permission remained enabled.

- Full fast suite after the Meetings plus-menu addition: 14,066 assertions passed, zero failures.
- Focused permission runner: 209 assertions passed.
- Isolated Core Audio ring/lifecycle suite: 19 tests passed.
- Independent diff review found and verified a fix for reentrant recovery
  restarting after stop. No remaining blocking finding for a local experiment.
- Deferred P2 (resolved below, in "Hardening follow-up"): the host closed normal
  writer admission at stop, so PCM still queued in the new backend ring was
  dropped. Backend-only drain was insufficient; the fix is the exact-attempt
  finishing handoff described further down, not a change to this earlier build.
- Full app build and launch smoke passed. The full QA bench also passed
  (core package tests, integration and deterministic E2E smoke, imported-audio
  artifact checks, synthetic audio matrix, and fixture-based release checks).
- The owner tested the local app; a retained meeting displayed both local speech
  and system-playback speech. This is a single-Mac smoke result, not a clean-install
  or upgrade permission matrix.
- The Meetings header now exposes a compact plus menu for recording a meeting or
  transcribing a file. Native UI inspection verified both menu actions and the
  file-picker path; the owner accepted the final icon treatment.
- Hardware route-switch, sleep/wake, fresh-install and old-grant upgrade checks,
  and signed release verification remain separate gates. Do not treat these
  local results as a shipping sign-off.

## Hardening follow-up (September 19)

The earlier checks above describe the initial experiment, not release approval.
The follow-up implementation adds a nonblocking unverified-system-audio prompt
after an inconclusive preflight or ten seconds without recording signal. Keeping
the recording leaves an amber unverified label; actual signal clears it, and
later ordinary silence does not trigger the warning again. The optional saved
`system_audio_signal_verified` boolean records this evidence independently of
quality and does not claim to query live TCC state.

Normal stop now uses an exact-attempt finishing handoff for queued PCM instead
of the cancellation/discard path. Ring overflow is terminal and reported as
partial capture instead of concatenating samples across an untracked gap.
These changes require fresh regression and live proof; the checks above must
not be reused as proof for the new code. The live smoke now checks actual
nonzero saved system signal and durations, not merely WAV file size.

The finishing handoff depends on early tail admission and closing the writer
after drained writes. `SystemAudioStopTailHandoffTests` checks source order for
arming admission before the recording generation advances, then exercises the
real stop scheduler with a hooked backend and serial writer queue. It verifies
stereo sample markers for both early consumer delivery and final queued drain,
and verifies cancellation discards buffers before callback delivery. This is
bounded scheduler and source-order coverage, not an end-to-end invocation of
the production `Audio.stop()` wiring or a hardware recording.

Live verification found and corrected a harness circular wait: the external
tone now starts before first-frame readiness. The corrected smoke retained
5.2 seconds of mic audio and 5.2587 seconds of system audio, peak 0.34999.
A local integrated 56-second recording saved the synthetic spoken phrase,
including its final words, with `system_audio_signal_verified: true` and zero
reported gaps. This does not establish real-call or Bluetooth behavior.

An idle-output permission recheck also exposed a 122-second startup wait.
Historical-grant revalidation now has a three-second deadline; first consent
keeps its longer dialog budget. Backend terminal failure resolves inconclusive,
never denied. The final fast suite passed 14,094 assertions with zero failures.
Fresh-account, old-broad-grant upgrade, integrated denial/recovery, long-call,
route-switch, sleep/wake, and exact notarized update checks remain release gates.
