# Transcripted 1.1.36 Release Candidate Notes

This is prep only. No GitHub release, Sparkle appcast, or Homebrew cask entry
exists for 1.1.36 yet.

## Candidate summary

Transcripted 1.1.36 is a reliability hotfix candidate for meeting audio teardown
and dictation recovery issues seen after 1.1.35 shipped.

## User-visible changes

- Meeting transcripts can use the active Apple Calendar event title instead of
  a generic meeting name.
- The meeting save status is less likely to get stuck after back-to-back
  recordings.
- The public README now shows a quicker product tour plus focused meeting and
  dictation recording GIFs.
- Meeting-only onboarding keeps dictation shortcuts fully off when the user
  chose that path.

## Reliability and ops changes

- Fixes the meeting stop race that could let old audio cleanup affect a newer
  recording session.
- Stops the meeting mic engine before removing the input tap, matching the
  production CoreAudio crash shape from 1.1.35.
- Improves built-in microphone plus Bluetooth output recovery for valid 24 kHz
  speech-bus routes.
- Avoids cancelling active dictation inference while CoreML transcription is in
  flight.
- Makes CLI and MCP legacy transcript reads skip malformed rows instead of
  crashing.
- Keeps beta/distribution builds from accidentally shipping thin artifacts
  without bundled Parakeet models unless both opt-outs are explicit.

## Known caveats

- Open issue #500 still needs the focused manual browser/app/device audio
  matrix.
- The latest 1.1.35 Sentry meeting crash and transcript-failure events happened
  before the post-release audio fixes, so the fix needs release-side validation.
- Sparkle users will not see 1.1.36 until a real artifact is published and
  `docs/appcast.xml` is updated.
- Homebrew users will not see 1.1.36 until `Casks/transcripted.rb` is updated
  after the GitHub release asset exists.

## Release blockers

- Build and notarize the 1.1.36 DMG.
- Verify Sparkle metadata against the real published artifact.
- Update and verify the Homebrew cask from the published DMG.
- Confirm `https://transcripted.app/download` resolves to the 1.1.36 asset only
  after approval to publish.

## Publish next step

If approved, run the full release flow from `docs/release-packaging.md`: build
the notarized artifact, publish the GitHub release, generate and verify the
Sparkle appcast entry, update the cask, then verify the live download route.
