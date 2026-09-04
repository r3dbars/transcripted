# Transcripted Lab package guidance

Transcripted Lab is an experiment orchestrator, not a second implementation of Transcripted.

## Boundaries

- Reuse repository-owned scripts and production benchmark seams.
- Do not copy the diarizer, STT engine, dictation session, speaker matcher, or artifact writer into this package.
- Add a narrow production adapter only when the app has no measurable seam for a required benchmark.
- Keep `TranscriptedLabKit` Foundation-only. The SwiftUI target consumes it; the CLI consumes the same API.
- Keep reports versioned, Codable, and backward-readable whenever practical.
- Do not persist raw audio, embeddings, prompt text, transcript bodies, or speaker clips in Lab JSON reports.

## Hard gates

Never average these away:

- cross-person false merge or false automatic speaker name
- profile contamination regression
- lost or duplicated audio/text
- speech/silence inversion
- delivery failure
- process crash, timeout, or blocking QA failure

## Validation

For changes inside this package:

```bash
swift test --package-path Tools/TranscriptedLab
swift build --package-path Tools/TranscriptedLab --product transcripted-lab
swift build --package-path Tools/TranscriptedLab --product TranscriptedLab
Tools/TranscriptedLab/script/build_and_run.sh --verify
```

The app target is macOS-only. The package manifest intentionally omits it on non-macOS hosts so the Foundation-only kit and CLI remain testable elsewhere.
