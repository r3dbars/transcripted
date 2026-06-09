# Transcripted 1.1.47 Release Prep Dry Run

Date: 2026-06-08

Status: HOLD. Do not cut 1.1.47 yet.

This is a prep artifact only. It does not authorize a version bump, GitHub
release, appcast update, Homebrew cask update, or website production change.

## Current Release Truth

- Shipped release remains `1.1.46`.
- Local `HEAD` during this dry run was `4e226db0`, `origin/main`, merged through
  PR `#1017`.
- `Info.plist` still reports `CFBundleShortVersionString = 1.1.46`.
- `docs/appcast.xml` still points at `1.1.46`.
- `Casks/transcripted.rb` still points at `1.1.46`.
- Live `/download/latest.dmg` redirected to the `1.1.46` GitHub release asset.
- The queued PR set `#1018` through `#1031` was not present in this checkout.

## Verified Present

- Release docs exist:
  - `docs/release-packaging.md`
  - `docs/sparkle-updates.md`
  - `docs/release-notes-template.md`
- Release scripts exist:
  - `build-beta.sh`
  - `scripts/entrypoints/build-beta.sh`
  - `scripts/release/register-sentry-release.sh`
  - `scripts/release/generate-sparkle-appcast.sh`
  - `scripts/release/verify-sparkle-release.sh`
  - `scripts/release/update-cask.sh`
- Release shell scripts passed `bash -n`.
- Release Python scripts passed syntax compile with a repo-safe pycache path.
- `sentry-cli`, `gh`, `dwarfdump`, and `dsymutil` are installed.
- Local Parakeet and offline diarizer model bundles are present.

## Blockers

- `gh auth status` failed during the dry run with an invalid token. It later
  showed healthy auth after the environment changed, but this must be rechecked
  immediately before release.
- No valid `Developer ID Application` signing identity was found during the dry
  run.
- No notarization credentials were available. `NOTARY_PROFILE` was not set.
- Built dependencies were missing in the worktree:
  - `deps-libs/libDraftDeps.a`
  - `deps-libs/.build-deps-stamp`
  - `deps-frameworks/Sparkle.framework`
  - `deps-frameworks/Sentry.framework`
  - Sparkle release tools under `deps-tools/sparkle/bin/`
- Sentry release auth was not available in the shell during the dry run.
- Cloudflare deploy credentials were not available in the shell during the dry
  run.
- `create-dmg` was not installed. This is not a hard blocker because
  `build-beta.sh` has a Finder-layout fallback.
- Release notes are not publish-ready. `docs/release-candidate-1.1.47.md` is a
  good base, but it needs a refresh after the `#1018` through `#1031` merge room
  resolves.

## Release Notes Readiness

`docs/release-candidate-1.1.47.md` is usable as a starting point. It already
separates user-visible changes, reliability and ops changes, caveats, and
verification.

Before publishing, refresh it for:

- June 7 QA buildout merges through `#1017`.
- Any accepted PRs from `#1018` through `#1031`.
- Any PRs that are explicitly held and should not be described as shipped.
- The final manual QA state for issue `#500`, issue `#825`, and any release
  gate items still marked incomplete.

## Post-Approval Command Plan

Run this only after Justin explicitly approves the cut and the PR queue is
resolved.

```bash
git status --short
gh auth status
bash build-deps.sh --force
python3 ~/.codex/skills/transcripted-release/scripts/bump_release_version.py --repo "$PWD" --version 1.1.47

python3 scripts/ops/privacy-leak-sweep.py --write-report build/privacy-leak-sweep-report.json
bash build.sh --no-open
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash run-tests.sh
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash run-integration-smoke.sh
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift test
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 bash scripts/ops/transcripted-qa-bench.sh --mode full

NOTARY_PROFILE=<profile> bash build-beta.sh '' Justin
dwarfdump --uuid build/Transcripted.app/Contents/MacOS/Transcripted
dwarfdump --uuid build/Transcripted.app.dSYM

gh release create v1.1.47 build/Transcripted-1.1.47.dmg \
  --repo r3dbars/transcripted \
  --title "Transcripted 1.1.47" \
  --notes-file docs/release-candidate-1.1.47.md

SENTRY_REQUIRE_DEBUG_FILES=1 bash scripts/release/register-sentry-release.sh 1.1.47

mkdir -p build/sparkle-updates
cp build/Transcripted-1.1.47.dmg build/sparkle-updates/
bash scripts/release/generate-sparkle-appcast.sh build/sparkle-updates
bash scripts/release/verify-sparkle-release.sh 1.1.47
bash scripts/release/update-cask.sh 1.1.47

python3 scripts/ops/nightly-security-check.py --strict --live-release-surfaces
python3 scripts/ops/nightly-security-check.py --strict --require-sentry-release-health
python3 scripts/ops/nightly-security-check.py --strict --require-release-debug-files
```

After GitHub release publication, update and verify the website/download handoff
from the active Transcripted web repo:

- `/download`
- `/download/latest.dmg`
- `/appcast.xml`
- `/llms-full.txt`
- support and privacy release-truth references

## Needed Secrets And Manual Approvals

- GitHub CLI auth with release publish access for `r3dbars/transcripted`.
- `Developer ID Application` signing certificate.
- Apple notarization profile exposed as `NOTARY_PROFILE`.
- Sparkle private EdDSA signing key in the local keychain, plus Sparkle tools
  from `bash build-deps.sh --force`.
- Sentry token or configured `sentry-cli` auth with release and debug-file
  upload scopes.
- Cloudflare Pages deploy credentials for the website handoff, if live web
  release surfaces need to change.
- Manual release approval from Justin after the merge room and release notes
  refresh.

## Smallest Next Action

Resolve the `#1018` through `#1031` queue, then rerun this dry run from fresh
`origin/main` after `gh auth`, signing identity, `NOTARY_PROFILE`, and
`bash build-deps.sh --force` are all green.
