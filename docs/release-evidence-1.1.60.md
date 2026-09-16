# Transcripted 1.1.60 release evidence

Release requested by the owner on 2026-09-16. Source includes the reliability
changes merged through PR #1740 and the independently reviewed AirPods tap-format
fix (e65523f8).

## Physical checks before packaging

On the AirPods fix build, local diagnostics confirmed successful dictation,
non-silent 24 kHz Bluetooth input, pasteback, and transcript persistence. Further
tests covered switching from the built-in microphone back to AirPods, idle
sleep/wake, and putting AirPods in their case for about ten seconds before
reconnecting. The reconnect capture lasted 22.6 seconds. Observed stop-to-paste
times for these checks were 254–384 ms. These are local observations, not a
population-wide latency guarantee.

The owner also reported that meeting testing was good. This is owner-reported
manual evidence, not an independently inspected meeting artifact.

## Explicit proof limits and accepted exceptions

- The owner requested this named release after disclosure that Sentry API
  authentication was unavailable. Crash-free rate, remote release registration,
  and remote dSYM upload remain UNKNOWN until verified; they are not green.
  Retain the exact release dSYM for the later authenticated upload.
- No physical Logitech C920 was available. The owner declined that hardware
  test and requested release. Do not claim the customer C920 report is proven
  resolved. Automated USB binding checks do not replace physical-device proof.
- The observed AirPods checks used unprocessed microphone capture. They do not
  prove every voice-processing mode, Zoom coexistence, or macOS/device combination.
- Packaging, notarization, exact artifact checks, and live distribution checks
  remain separate requirements. This note does not waive failures in them.

The trusted packaging workflow builds from `c707b634`; the packaged binary's
build revision remains that commit even after later metadata-only commits. A
synthetic 1.1.60 release-health fixture checks metadata parity, not whether the
GitHub asset, Sparkle feed, or Homebrew update is publicly available.

## Rollback baseline

Previous public release: v1.1.59. Its GitHub asset is
`https://github.com/r3dbars/transcripted/releases/download/v1.1.59/Transcripted-1.1.59.dmg`.
The previous Homebrew SHA-256 is
`e245f148b2aa19437624b198d09f9cb18621fbd63909399fbfba45f395d0a09c`.
Restore all download surfaces together if rollback is necessary; deleting a
release alone does not restore Sparkle, Homebrew, or the website.
