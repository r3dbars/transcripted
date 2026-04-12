# Security Policy

## Privacy Architecture

Transcripted is local by default.

Its core product workflows are:

- local dictation capture
- local meeting capture and transcription
- local artifact generation for humans and agents

Those artifacts are written as files you can inspect directly rather than being
hidden behind a cloud-only backend.

Fresh installs default to Transcripted-named storage. If a legacy `Draft`
Application Support folder already exists, current builds continue using it for
compatibility while the rename settles.

Data stored locally today:

| Data | Location | Format |
|------|----------|--------|
| Meeting transcripts | `~/Library/Application Support/Transcripted/...` or legacy `Draft/...` | Markdown |
| Meeting sidecars + index | `~/Library/Application Support/Transcripted/...` or legacy `Draft/...` | JSON |
| Speaker database | `~/Library/Application Support/Transcripted/...` or legacy `Draft/...` | SQLite |
| Speaker clips | `~/Library/Application Support/Transcripted/...` or legacy `Draft/...` | WAV |
| Dictation logs | `~/Library/Application Support/Transcripted/...` or legacy `Draft/...` | Markdown |
| App events | `~/Library/Application Support/Transcripted/...` or legacy `Draft/...` | JSON Lines |
| Feedback log | `~/Library/Application Support/Transcripted/...` or legacy `Draft/...` | JSON Lines |
| Style profile | `~/Library/Application Support/Transcripted/...` or legacy `Draft/...` | Markdown |
| Prompt overrides | `~/Library/Application Support/Transcripted/...` or legacy `Draft/...` | JSON |
| Model cache | `~/Library/Caches/models/mlx-community/` | MLX / CoreML |

Operational caveats:

- first launch may download local models from HuggingFace if they are not already cached
- signed builds can optionally fetch the Sparkle appcast for in-app updates
- beta builds can optionally contact the update/log proxy for update checks and diagnostics shipping
- core dictation and transcription do not require cloud APIs

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Older releases | Best effort |

## Reporting a Vulnerability

If you discover a security vulnerability, report it responsibly:

1. Do not open a public GitHub issue for security vulnerabilities
2. Open a private GitHub Security Advisory at <https://github.com/r3dbars/transcripted/security/advisories/new>
3. Include:
   - description of the vulnerability
   - steps to reproduce
   - potential impact
   - suggested fix, if any

We will acknowledge your report within 48 hours and aim to provide a fix within
7 days for critical issues.

## What we care most about

Given that Transcripted is local-first software, the main security concerns are:

- audio capture permissions and ensuring capture only happens when the user intends
- accessibility and paste-back safety when Transcripted writes into another app
- local data protection for transcripts, sidecars, and feedback files
- model integrity for downloaded local ML artifacts
- memory safety in CoreAudio and audio-processing code
- any optional network paths used for beta updates or diagnostics

Out of scope: generic hosted-service attacks. Transcripted does not depend on
cloud APIs for its core product workflows.
