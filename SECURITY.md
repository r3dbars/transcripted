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
- signed builds can optionally fetch the Sparkle appcast for in-app updates
- beta builds can optionally contact the update/log proxy for update checks and diagnostics shipping
- core dictation and transcription do not require cloud APIs

## Model integrity

Model files come from `https://huggingface.co` only. There is no third-party
mirror fallback: if huggingface.co is unreachable, the download fails closed
rather than silently degrading to a less-trusted source whose manifest could
supply attacker-controlled digests.

LFS-tracked files (weights) are verified against the SHA-256 digest reported by
the HuggingFace API before being moved into the cache. Non-LFS files
(tokenizer.json, config.json, etc.) ride on HTTPS to huggingface.co with no
per-file digest — those are documented but not currently hash-pinned.

## Beta build entitlements

The beta build is intentionally less hardened than a typical sandboxed Mac app.
`config/entitlements/beta.plist` sets:

- `com.apple.security.app-sandbox` = false
- `com.apple.security.cs.disable-library-validation` = true
- `com.apple.security.cs.allow-jit` = true

Combined with the TCC permissions Transcripted asks for (microphone, screen
recording, accessibility, calendars), this means: anything running as your user
that can write into `Transcripted.app/Contents/Frameworks/` can load its own
code into the running app and inherit those permissions, including the ability
to inject keystrokes into other apps via the paste-back path.

The reason library validation is disabled is that the on-device ML stack (MLX,
WhisperKit, CoreML model bundles) currently ships dylibs that do not all carry
the same team-id signing as the app, so strict library validation refuses to
load them. We treat that as a known cost of running ML locally on macOS today.

The entitlement contract is intentionally narrow even while the app is not
sandboxed. `config/security/nightly-security-manifest.json` forbids broad OS
entitlements such as user-selected file read/write access, Apple Events
automation, camera, location, contacts, photos, media-library, and network
server access; `scripts/ops/nightly-security-check.py` fails if those appear in
the local, beta, or built-app entitlement set.

Practical implications for users:

- install Transcripted from a trusted source (the signed DMG from GitHub
  Releases) and verify the Developer ID before granting permissions
- treat user-level malware as already game-over for these permissions, since
  it could substitute a framework binary and inherit them
- the local-test entitlements profile (`config/entitlements/local.plist`) is
  meant for ad-hoc smoke builds only and shares the sandbox-off posture — it
  is not the shipping profile

If a future version of the ML stack supports team-id-consistent signing for all
embedded dylibs, the `disable-library-validation` entitlement will be removed.

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
