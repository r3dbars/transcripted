# Staged real Sparkle update test for 1.1.71

This bounded repair harness tests the already-published 1.1.70 -> 1.1.71 update
before the candidate appcast reaches main. It does not publish or modify any
release surface. It refuses native execution outside GitHub's hosted `runner`
account, even when the owner's shell sets CI environment flags.

Run on an ephemeral `macos-26` hosted job with two checkouts: `harness` contains
this script; `candidate` is a clean checkout of
`e42ad0f759612e0080f2d11bb5de12fda6b590bd`. Set `WORKFLOW_SHA` from
`github.workflow_sha`; the harness requires this exact commit to match its
own checkout and records it alongside the candidate revision.

```sh
python3 harness/Tests/BuildDependencies/StagedSparkleUpdateTests.py
python3 harness/scripts/release/test-staged-sparkle-update.py \
  --candidate-root candidate --output "$RUNNER_TEMP/staged-update-proof"
```

The output must be a new directory beneath the resolved RUNNER_TEMP. Upload
only `receipt.json` as the bounded result. Detailed compiler/updater/signature
logs and runtime reports remain local to the disposable runner; do not upload
or print these raw logs, which may contain absolute paths. A failure has a
bounded error kind/code. No retry-until-green is built in.

## What it does

1. Builds the official Sparkle CLI from source commit
   `066e75a8b3e99962685d6a90cdd5293ebffd9261` (2.9.1), with each input hash pinned.
   The repository's SPM distribution and Sparkle's full distribution do not
   ship this CLI binary. The official full toolkit is pinned to SHA256
   `c0dde519fd2a43ddfc6a1eb76aec284d7d888fe281414f9177de3164d98ba4c7`.
   Local compile-only validation succeeded; neither app was launched locally.
2. Disables analytics and crash reporting in the disposable account before
   launch. Both released versions recognize the same preference keys and
   `TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT` AutomatedLaunchEnvironment flag.
   Setting that flag in the hosted user's launch environment also covers
   Sparkle's relaunch. The previous launch environment is restored on exit.
   The flag suppresses app-internal checks/permission probes; the separate
   official CLI executes the real updater pipeline. Production session
   minimums are never manufactured by this test.
3. Downloads hash/size-pinned public DMGs and the 1.1.70 delta; checks stapled
   notarization, code signatures, Gatekeeper assessment, version/build,
   bundle ID and the unchanged Sparkle public key. No signing settings,
   keychain access, TCC grant, quarantine removal, or app re-signing is used.
4. Serves a copy of the candidate feed and exact artifact bytes on **127.0.0.1
   only**. URLs are rewritten for the test and irrelevant historical items
   removed. Enclosure signatures and delta validation metadata remain intact.
   Loopback transport uses the upstream CLI's existing ATS configuration;
   no application security settings are changed.
5. Runs full and delta routes separately from fresh copies of the old app.
   Full omits delta offers. Delta preserves the full fallback but fails if
   Sparkle requests it, so fallback cannot be reported as a delta pass.
6. Requires successful CLI installation, observed old PID disappearance and
   new PID at the same bundle path, a fresh runtime report affirming app
   launch/menu bar/popover, version/build 1.1.71, valid code signature and
   Gatekeeper assessment, and complete file/symlink-content equality with the
   pristine published 1.1.71 app. Mere probe/no-update/exit-zero is insufficient.
7. Terminates only the task's exact app path, stops its loopback server and
   attempts every launch-environment restoration. Cleanup failure fails the
   receipt. No host microphone or owner desktop is touched.

This proves external Sparkle selection, download, signature validation,
replacement and relaunch. It does **not** prove Transcripted's own updater
controller, a human seeing/clicking its prompt, real dictation/meeting capture,
pasteback, Bluetooth, or crash-free release health. Those remain separate.

## Native prompt path before public promotion

Sparkle 2.9.1 supports an `SUFeedURL` preference override (deprecated but still
implemented). Its `SPUUpdater.m` `retrieveFeedURL:` reads the host preference;
`SUHost.m` checks preferences before Info.plist. Transcripted 1.1.70 does not
implement `feedURLStringForUpdater:` or clear that preference. Its initial
configuration check still reads the unchanged valid HTTPS URL in Info.plist.
Thus a human can test the app's real Check for Updates and installation on a
**disposable account or VM**, without editing/re-signing the released app:

- Save the existing `SUFeedURL` value/type (or its absence) and the two
  telemetry preference values before changes. Use `defaults export` into an
  owned local backup for exact restoration; never expose the backup in logs.
- Disable `observability-anonymous-analytics-enabled` and
  `observability-crash-reporting-enabled` in `com.justinbetker.draft`.
- Set `SUFeedURL` in that domain to the immutable HTTPS candidate URL:
  `https://raw.githubusercontent.com/r3dbars/transcripted/e42ad0f759612e0080f2d11bb5de12fda6b590bd/docs/appcast.xml`.
- Launch the unchanged signed 1.1.70 app **without** AutomatedLaunchEnvironment
  flags: those flags intentionally disable its updater controller. Use the
  app's real Check for Updates action; record the visible offered version,
  installation, relaunch and final version. Do not approve new host security
  access or substitute a fake update state.
- Quit the disposable app and restore each modified preference with its exact
  former type/value, deleting keys that were originally absent. Verify the
  restoration. Do not leave the test app pointed at a candidate feed.

This manual path has been verified from pinned source, not executed here.
It does not imply approval to touch the owner's account. A headless hosted
CLI receipt is never labeled human prompt proof.

References: https://sparkle-project.org/documentation/sparkle-cli/ and
https://github.com/sparkle-project/Sparkle/tree/066e75a8b3e99962685d6a90cdd5293ebffd9261/sparkle-cli
