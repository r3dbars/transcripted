# Security Policy

## Privacy Architecture

Transcripted processes all audio **100% locally** on your Mac. No audio, transcripts, or speaker data is ever sent to external servers. There are no API keys, no cloud services, and no analytics.

Data stored locally:

| Data | Location |
|------|----------|
| Transcripts | `~/Documents/Transcripted/` |
| Speaker voice fingerprints | `~/Documents/Transcripted/speakers.sqlite` |
| Recording statistics | `~/Documents/Transcripted/stats.sqlite` |
| Application logs | `~/Library/Logs/Transcripted/app.jsonl` |

Audio recordings are deleted after successful transcription.

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Older releases | Best effort |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do not** open a public GitHub issue for security vulnerabilities
2. Email your report to the maintainers (open a private GitHub Security Advisory at https://github.com/r3dbars/transcripted/security/advisories/new)
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

We will acknowledge your report within 48 hours and aim to provide a fix within 7 days for critical issues.

## Scope

Given that Transcripted is a local-only application, the primary security concerns are:

- **Audio capture permissions** — ensuring the app only captures audio when the user intends
- **Local data protection** — transcript and speaker database file permissions
- **Model integrity** — ensuring downloaded ML models haven't been tampered with
- **Memory safety** — preventing audio buffer overflows or use-after-free in CoreAudio callbacks

Out of scope: network-based attacks (the app makes no network requests after initial model download).
