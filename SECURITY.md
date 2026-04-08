# Security Policy

## The short version

Transcripted is local-first software. The security story here is mostly about
keeping captured audio and transcripts on your Mac.

Core behavior today:

- dictation runs locally on your Mac
- meeting capture and transcription stay local
- transcripts and feedback data are written to local files you control

Current builds still use some `Draft`-named application-support paths while the
transition settles.

Data stored locally today:

| Data | Location | Format |
|------|----------|--------|
| Meeting transcripts | `~/Library/Application Support/Draft/meetings/transcripts/` | Markdown |
| App events | `~/Library/Application Support/Draft/events.jsonl` | JSON Lines |
| Feedback log | `~/Library/Application Support/Draft/feedback.jsonl` | JSON Lines |
| Style profile | `~/Library/Application Support/Draft/style.md` | Markdown |
| Prompt overrides | `~/Library/Application Support/Draft/prompts.json` | JSON |
| Model cache | `~/Library/Caches/models/mlx-community/` | MLX / CoreML |

Beta builds can optionally contact the update/log proxy for update checks and
diagnostics shipping. Core dictation and transcription do not require cloud APIs.

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Older releases | Best effort |

## Reporting a Vulnerability

Please do not open a public GitHub issue for a security problem.

Instead, open a private GitHub Security Advisory:

[https://github.com/r3dbars/transcripted/security/advisories/new](https://github.com/r3dbars/transcripted/security/advisories/new)

Please include:

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will acknowledge your report within 48 hours and aim to provide a fix within 7 days for critical issues.

## What we care most about

Because Transcripted captures private spoken context, the main concerns are:

- **Audio capture permissions** — ensuring the app only captures audio when the user intends
- **Accessibility and paste-back safety** — ensuring automation targets the app the user intended
- **Local data protection** — transcript and feedback file permissions
- **Model integrity** — ensuring downloaded ML models haven't been tampered with
- **Memory safety** — preventing audio buffer overflows or use-after-free in CoreAudio callbacks

Out of scope: generic hosted-service attacks. Transcripted does not depend on cloud APIs for its core product workflows.
