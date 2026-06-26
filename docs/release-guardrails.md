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
- **Notarized artifact:** a final signed, notarized
  `build/Transcripted-<version>.dmg` built from the intended source revision.
- **Packaged app smoke:** the release candidate passes packaged-app smoke with
  the matching app, DMG, and dSYM.
- **Release surface audit:** GitHub release, `docs/appcast.xml`, live appcast,
  `/download/latest.dmg`, download page, Homebrew cask, Sentry release, and
  dSYM status are checked as separate rows.

## Safe While Justin Is Away

These are safe without extra approval:

- docs-only release planning
- read-only release-health checks
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
