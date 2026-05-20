# Transcripted 1.1.43 Release Candidate Notes

## Summary

Transcripted 1.1.43 is a candidate reliability and first-run polish release
for meeting capture, dictation transcription, app quitting, Settings, and the
release pipeline.

Do not publish this candidate yet. Version, Sparkle, and Homebrew metadata
still point at the real shipped `1.1.42` release until an approved release
artifact exists.

## User-visible changes

- Settings refreshes permission status after macOS permission prompts return,
  so Calendar access should not look stuck until restart.
- Quitting during an active meeting now asks whether to keep recording, stop
  and transcribe, or save audio and quit.
- General settings are more compact and remove duplicate shortcut controls.
- Failed meeting audio is preserved long enough for retry, delete, or age-based
  cleanup instead of disappearing too early.
- Paste Last Dictation now avoids unsafe paste targets more carefully.

## Reliability and ops changes

- Hardens Parakeet/CoreML inference lifetime handling for the latest `1.1.42`
  fatal crash shape.
- Counts meeting-segment ASR work as active transcription so cleanup does not
  release shared inference resources too early.
- Copies CoreML-backed diarization output into Swift-owned values before
  returning from transcription work.
- Bundles offline diarizer models in beta and release builds by default.
- Keeps meeting ASR work from blocking dictation UI state.
- Generates and uploads Sentry dSYMs during the release flow so production
  crashes can symbolicate app frames.
- Extends release smoke coverage to catch packaging and release-gate failures
  before publication.

## Known caveats

- `1.1.42` shipped less than a day before this candidate note was prepared, so
  wait for more live usage before publishing.
- Sentry still has one unresolved latest-release `APPLE-MACOS-S` fatal crash;
  the merged CoreML lifetime fix targets that shape, but the next release needs
  monitoring to prove it.
- Open issue `#500` remains the manual audio-output-volume watch item.
- Existing installs will not see `1.1.43` in-app unless a real GitHub release
  artifact is approved and `docs/appcast.xml` is updated for that artifact.

## Current verification snapshot

- `bash scripts/release/verify-sparkle-release.sh 1.1.42`
- `python3 scripts/ops/nightly-security-check.py --write-report build/nightly-security-report.json`
- Nightly build memory at `617b6d24` is green across dependency rebuild, app
  build, fast tests, integration smoke, and Swift package tests.
