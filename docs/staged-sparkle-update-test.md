# Staged signed 1.1.75 → 1.1.76 RC verification

This disposable validation branch tests the unchanged final notarized RC before
publication. It does not change a release surface or signed application. Only
the existing `staged-update-proof` workflow mode selects it; normal required CI
routing and the main-only signing workflow remain unchanged.

This version-specific recipe is fixed to 1.1.75 -> 1.1.76 and its pinned RC.
It is not the current release checklist. Current release work starts with
`docs/release-packaging.md` and `docs/sparkle-updates.md`; broader validation
is in `docs/qa-test-bench.md`.

The source checkout is fixed at `caa17f1bb522324bf8f756239347fb4c6308ab52`.
The harness checkout and receipt separately pin `github.workflow_sha`.
The only accepted new artifact is final RC run `41978929739`, artifact
`13394641882`, with its exact API metadata, ZIP length and SHA256. All archive
members are allowlisted before extraction. The signed feed, 1.1.76 DMG and
75→76 delta must also match their individually pinned raw bytes. New assets
are never fetched from a public 1.1.76 URL, rebuilt or re-signed. Only the old
public 1.1.75 DMG is downloaded from GitHub Releases.

The job needs only `contents: read` and `actions: read`. It runs on hosted
`macos-26` ARM64, with the `runner` account and `/Users/runner` home independently
checked by the harness. It refuses a product preference domain, capture/state
folders, alternate installed app, shared FluidAudio model cache, or existing
Transcripted process. No owner account, runner policy, TCC or security setting
is changed.

```sh
# Pure guard tests: safe without macOS, apps, network or preferences.
python3 harness/Tests/BuildDependencies/StagedSparkleUpdateTests.py

# Native proof: only the admitted disposable hosted job may execute this.
python3 harness/scripts/release/test-staged-sparkle-update.py \
  --candidate-root candidate --output "$RUNNER_TEMP/staged-update-proof" \
  --rc-archive "$RUNNER_TEMP/final-rc.zip" \
  --rc-metadata "$RUNNER_TEMP/final-rc-metadata.json"
```

## Actual updater routes

The harness builds official Sparkle CLI 2.9.1 from pinned upstream source
`066e75a8b3e99962685d6a90cdd5293ebffd9261`. Every input and the full toolkit
archive are hash-pinned. Only this separate test CLI is ad-hoc signed; neither
Transcripted application is changed.

Both DMGs must have valid stapled notarization. Both enclosed apps must pass
deep strict code-signature and Gatekeeper checks, version/build, bundle ID and
the unchanged old-client Sparkle public key. Entire bundle manifests include
all files, modes, directories and literal symlink targets.

A loopback-only server serves a **test copy** of the feed with rewritten URLs.
The original signed feed is retained unchanged and hash-checked. Enclosure
signatures and delta validation attributes survive the rewrite. Full and delta
runs each start with a pristine old app at a new owned path. Full offers no
delta; delta keeps the full fallback but fails if it is requested. Exit zero
alone is insufficient: each route requires the old PID to disappear, a new PID
at the same bundle path, a fresh report confirming launch/status item/popover,
and a complete installed-bundle match to the pristine notarized 1.1.76 app.

## Actual packaged CLI import

Before any app launch can populate a cache, `scripts/release/test-signed-candidate-cli.py`
relocates another exact copy of the signed candidate. It requires all bundled
Parakeet, Nemotron and ReDimNet2 models, verifies build identity, and generates
at least ten seconds of nonprivate synthetic speech using `say -o` (no playback).
It invokes the actual unchanged packaged helper under `sandbox-exec` with
`(deny network*)`, owned output/container/TMPDIR, `--no-download`,
`--no-speaker-identification`, and explicit default Nemotron/ReDimNet2 choices.
No `--models-dir` override is supplied; inherited experimental overrides are
removed. Alternate app/cache absence and the actual Parakeet resolution log
bind model provenance to the relocated candidate.

Success requires a whole JSON receipt, matching capture IDs, one committed
Markdown and retained WAV under the owned output, actual engine/voiceprint
metadata, numbered speakers only, expected synthetic words, readable retained
audio of matching duration, no publication/import scratch, unchanged source
audio and unchanged signed app/model manifests. It is packaged model plumbing
proof; it does not establish transcription or speaker accuracy for customer
recordings.

Telemetry and automatic update checks are disabled only in the proven absent
product domain of this disposable account. App launches receive an owned
container plus the AutomatedLaunchEnvironment runtime-report flag; the CLI
also uses its explicit owned paths. The prior launch environment and original
preference-domain absence must be restored. Every launched app is terminated
only by its exact owned path. Before deleting the admitted fresh domain once,
cleanup independently waits for every recorded owned app PID to exit. It then
observes the unchanged domain/standard-plist/ByHost-plist absence conditions for
at most thirty seconds, without repeated deletion. Only presence booleans and
counts enter the receipt. If a standard plist remains without a ByHost plist, cleanup may claim
that exact file into a new private quarantine only after descriptor-based
parent/file ownership, regular single-link type, bounded valid dictionary and
zero-key checks. The same inode and empty contents are revalidated after the
atomic move; all claimed bytes remain privately retained, even on success.
Races restore without overwriting a new source or remain retained and fail.
The unchanged three absence conditions must still pass afterward. No preference
bytes are unlinked and no additional domain deletion is attempted. Both earlier
hosted cleanup failures remain preserved; empty residue is not established as
their cause until an actual receipt supplies that metadata.

Only bounded `receipt.json` is uploaded (seven-day retention). Downloaded apps,
feeds, raw logs, transcript/audio and preference content stay on the disposable
runner. The receipt distinguishes source, workflow and RC identities.

This proves the external Sparkle install/relaunch pipeline and synthetic
packaged CLI import. Transcripted's human update prompt, live capture,
Bluetooth, pasteback, customer audio accuracy, and release health remain
separate checks. No retry-until-green is built in.

References: [official Sparkle CLI](https://sparkle-project.org/documentation/sparkle-cli/)
and [pinned CLI source](https://github.com/sparkle-project/Sparkle/tree/066e75a8b3e99962685d6a90cdd5293ebffd9261/sparkle-cli).
