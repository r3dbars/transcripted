# Transcripted 1.1.36 Release Notes

## Summary

Transcripted 1.1.36 is a reliability and polish release for meeting capture,
dictation recovery, onboarding, and the Settings home experience.

## User-visible changes

- Meeting transcripts can use the active Apple Calendar event title instead of
  a generic meeting name.
- The meeting save status is less likely to get stuck after back-to-back
  recordings.
- The public README now shows a quicker product tour plus focused meeting and
  dictation recording GIFs.
- Meeting-only onboarding keeps dictation shortcuts fully off when the user
  chose that path.
- The Settings home screen has cleaner Meetings and Dictation tabs and a fixed
  collapsed-sidebar header layout.
- The feedback issue picker now stays within the report sheet instead of
  stretching the settings window.
- The Agent setup page explains the Claude Desktop tools path and local-agent
  prompt path more clearly.

## Reliability and ops changes

- Fixes the meeting stop race that could let old audio cleanup affect a newer
  recording session.
- Stops the meeting mic engine before removing the input tap, matching the
  production CoreAudio crash shape from 1.1.35.
- Improves built-in microphone plus Bluetooth output recovery for valid 24 kHz
  speech-bus routes.
- Avoids cancelling active dictation inference while CoreML transcription is in
  flight.
- Preserves meeting start trigger attribution through speaker review so saved
  and failed meeting telemetry keeps its original source.
- Makes CLI and MCP legacy transcript reads skip malformed rows instead of
  crashing.
- Keeps beta/distribution builds from accidentally shipping thin artifacts
  without bundled Parakeet models unless both opt-outs are explicit.
- Keeps every health-probe lane running even when one provider is missing local
  credentials.
- Aligns the root Claude read order with the current agent onboarding docs.

## Known caveats

- Open issue #500 still needs the focused manual browser/app/device audio
  matrix.
- The latest 1.1.35 meeting crash and transcript-failure events happened before
  the post-release audio fixes, so this build still needs normal live-release
  monitoring after publication.
