# Transcripted 1.1.43 Release Candidate Notes

## Summary

Transcripted 1.1.43 is the approved reliability and first-run polish release
for meeting capture, dictation transcription, app quitting, Settings, and the
release pipeline.

This release is ready to publish once the notarized `Transcripted-1.1.43.dmg`
is attached to GitHub Releases and the Sparkle, Homebrew, and public download
surfaces all point at that artifact.

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

## Watch items

- Sentry should be checked after live `1.1.43` usage lands to confirm the
  CoreML lifetime and speaker-finalization fixes cover the production shapes.
- Open issue `#500` remains the manual audio-output-volume watch item.
- Existing installs will not see `1.1.43` in-app until `docs/appcast.xml` is
  updated and pushed for the published GitHub release artifact.

## Current verification snapshot

- `bash build-deps.sh --force`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash build.sh --no-open`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash run-tests.sh`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash run-integration-smoke.sh`
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test`
- `NOTARY_PROFILE=Transcripted bash build-beta.sh transcripted-public-1.1.43 Transcripted`
