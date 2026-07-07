# Release Guardrails

Use this when Justin is away, offline, or has not explicitly said to publish.

Default state: **do not publish**. Agents may build, test, audit, and prepare a
draft release plan, but must not tag, notarize for shipment, publish a GitHub
release, update Sparkle/appcast, update Homebrew, deploy download pages, or
announce a release unless Justin explicitly says to do that exact action.

## Required Release Gates

A user-facing Transcripted release needs all of these gates:

- **Justin go:** a clear, current instruction from Justin naming the release or
  publish action.
- **Fresh QA:** current-branch or current-main QA from this release candidate,
  not old proof from a prior build.
- **Manual QA:** human proof for install, launch, menu bar, dictation, meeting
  capture, pasteback, update prompts, and any hardware/audio route touched by
  the release. Missing manual proof is `YELLOW` or `UNKNOWN`, never green.
- **Crash-free rate:** `scripts/ops/check-crash-free-rate.py --version <version>`
  must return green. Crash-free-sessions below the threshold (default 99.5%) is
  a hard `RED` block. If the check cannot verify the rate — credentials absent,
  the Sentry API is unreachable, or the release has no/too-little session data —
  it is `YELLOW`/`UNKNOWN`, never green, and the release is not cleared. The
  script exits non-zero for both cases (red `1`, yellow `3`), so a wrapper can
  gate on exit code. See "Crash-free-rate gate" below.
- **Notarized artifact:** a final signed, notarized
  `build/Transcripted-<version>.dmg` built from the intended source revision.
- **Packaged app smoke:** the release candidate passes packaged-app smoke with
  the matching app, DMG, and dSYM.
- **Release surface audit:** GitHub release, `docs/appcast.xml`, live appcast,
  `/download/latest.dmg`, download page, Homebrew cask, Sentry release, and
  dSYM status are checked as separate rows.

## Crash-free-rate gate

`scripts/ops/check-crash-free-rate.py` is the automated go/no-go for release
health. It queries Sentry's Release Health (Sessions) API for the crash-free
session rate and crash-free user rate of `transcripted@<version>` and maps the
result to a verdict:

- `green` (exit `0`): crash-free-sessions >= threshold on enough session data.
- `red` (exit `1`): crash-free-sessions below threshold. Hard block.
- `yellow`/`unknown` (exit `3`): cannot verify — no `SENTRY_AUTH_TOKEN`, Sentry
  unreachable, or the release has no/too-little session data. Never green.

Both `red` and `yellow` exit non-zero, so a release is not cleared to ship if
crash-free is below threshold OR unverifiable. This matches how missing manual
proof is treated: unknown is never green.

Defaults (all overridable by flag or env, see `--help`):

- `--threshold 99.5` (`CRASH_FREE_SESSION_THRESHOLD`) — crash-free-sessions
  floor. 99.5% is the common release-health ship line (Sentry's default
  release-health target; above Google Play's ~98.9% bad-behavior floor).
- `--user-threshold 99.0` (`CRASH_FREE_USER_THRESHOLD`) — crash-free-users
  floor, a looser secondary gate (one crashing user with many sessions skews it).
- `--min-sessions 25` (`CRASH_FREE_MIN_SESSIONS`) — below this the rate is not
  trusted and the verdict is `yellow`, not a false green on thin data. For a
  low-volume release, widen `--stats-period` (e.g. `14d`) rather than shipping
  on a handful of sessions.
- `--stats-period 24h` (`SENTRY_STATS_PERIOD`) — lookback window.

Note: as of this writing the Transcripted Sentry project reports no session
data, so a live run returns `yellow`/`unknown` for real releases (session
tracking is not populating Release Health). That is the correct safe posture —
the gate blocks rather than false-greening — and it also surfaces that Release
Health is not yet wired up in the app's Sentry SDK. Wiring session tracking is
what turns this gate green-capable; until then crash-free is an `UNKNOWN` row,
handled by manual QA.

## Safe While Justin Is Away

These are safe without extra approval:

- docs-only release planning
- read-only release-health checks
- `check-crash-free-rate.py` (read-only Sentry Release Health query)
- local packaging dry runs that do not publish or notarize for shipment
- draft PRs
- draft release notes clearly marked as not published
- `post-dmg-release-audit.py` in read-only mode

## Not Safe Without Explicit Go

Do not do any of these unless Justin explicitly asks:

- create, edit, publish, or un-draft a GitHub release
- create or push a release tag
- run the final notarized publish path for a user-facing artifact
- replace or upload the live DMG
- update or push `docs/appcast.xml` for a new public version
- run `scripts/release/update-cask.sh` for a public version
- update the Homebrew tap/cask
- deploy website/download changes that point users at a new build
- rotate release, signing, Sparkle, Sentry, Cloudflare, or Homebrew secrets

## Boundary Notes

Sparkle, appcast, Homebrew, and the website are release surfaces, not cleanup
steps. A DMG can exist without being public. A GitHub release can exist without
Sparkle clients discovering it. Homebrew can still point at an older build.

Keep those boundaries explicit in closeouts:

- `artifact`: local build or published DMG
- `Sparkle/appcast`: committed and live feed state
- `Homebrew`: cask version and checksum state
- `website/download`: live route state
- `manual QA`: human/hardware proof state
