# Security Policy

## Privacy Architecture

Transcripted keeps its core workflows on-device:

- dictation runs locally on your Mac
- meeting capture and transcription stay local
- transcripts and feedback data are written to local files you control

Current builds still use Draft-named application-support paths for compatibility
while the Transcripted brand rollout settles.

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

Given that Transcripted is local-first software, the primary security concerns are:

- **Audio capture permissions** — ensuring the app only captures audio when the user intends
- **Accessibility and paste-back safety** — ensuring automation targets the app the user intended
- **Local data protection** — transcript and feedback file permissions
- **Model integrity** — ensuring downloaded ML models haven't been tampered with
- **Memory safety** — preventing audio buffer overflows or use-after-free in CoreAudio callbacks

Out of scope: generic hosted-service attacks. Transcripted does not depend on cloud APIs for its core product workflows.
