# Security Policy

## Privacy Architecture

Transcripted is local by default.

Its core product workflows are:

- local dictation capture
- local meeting capture and transcription
- local artifact generation for humans and agents

Those artifacts are written as files you can inspect directly rather than being
hidden behind a cloud-only backend.

The app now defaults to Transcripted-named storage. Meeting and dictation
captures can be relocated through the app's capture-library setting, while app
state, logs, cache, and temporary recordings stay under
`~/Library/Application Support/Transcripted/`.

Historic `Draft` paths remain in the repo for migration, validation, and
standalone-tool fallback when older artifacts are the only data on disk.

Data stored locally today:

| Data | Location | Format |
|------|----------|--------|
| Meeting transcripts | `<capture-library>/meetings/*.md` | Markdown |
| Meeting sidecars + index | `<capture-library>/meetings/*.json`, `<capture-library>/meetings/transcripted.json` | JSON |
| Speaker database | `~/Library/Application Support/Transcripted/state/speakers.sqlite` | SQLite |
| Stats database | `~/Library/Application Support/Transcripted/state/stats.sqlite` | SQLite |
| Failed transcription queue | `~/Library/Application Support/Transcripted/state/failed_transcriptions.json` | JSON |
| Dictation logs | `<capture-library>/dictations/*.md` | Markdown |
| App debug log | `~/Library/Application Support/Transcripted/logs/debug.log` | Text |
| App events | `~/Library/Application Support/Transcripted/logs/events.jsonl` | JSON Lines |
| Temporary speaker clips + raw recordings | `~/Library/Application Support/Transcripted/tmp/recordings/` | WAV |
| Model cache | `~/Library/Caches/models/mlx-community/` | MLX / CoreML |

Operational caveats:

- first launch may download local models from HuggingFace if they are not already cached
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
- local data protection for transcripts, sidecars, databases, and diagnostics logs
- model integrity for downloaded local ML artifacts
- memory safety in CoreAudio and audio-processing code
- any optional network paths used for beta updates or diagnostics

Out of scope: generic hosted-service attacks. Transcripted does not depend on
cloud APIs for its core product workflows.
