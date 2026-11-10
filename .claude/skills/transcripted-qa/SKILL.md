---
name: transcripted-qa
description: Choose and run the current Transcripted QA checks, investigate failures, and report exact proof and remaining gaps.
---

# Transcripted QA

Use the repository's current runners and owner guides to choose and explain
the QA checks.

## Scope and sources

1. Read `AGENTS.md` and identify the requested scope. Fetch `origin/main` before
   comparing a PR; include staged, unstaged, and untracked changes when working
   locally. Local `main` may be stale.
2. Run `python3 scripts/dev/agent-context.py <changed paths>` before planning,
   then read the nearest `AGENTS.md` for the affected area. For a symptom without
   known paths, use the context tool's `--symptom` option.
3. Use `.agents/test-matrix.yml` for mapped checks, `Tests/README.md` for test
   rules, and `docs/repo-layout.md` for the command map. Preserve the product
   flows and privacy requirements in `AGENTS.md`.

## Run the checks that apply

- Start with `bash check.sh`. It selects checks for the diff and writes
  `build/agent-proof.json`. Run build and test commands sequentially because
  they share build output. Keep the source unchanged while a check runs.
- `bash check.sh quick` is the Linux-safe tier; it does not prove Swift builds
  or app behavior. Select the full and hardware tiers when `AGENTS.md` or the test matrix
  requires them.
- For app behavior, use the `verify` skill at
  `.claude/skills/verify/SKILL.md`. Preview with
  `bash scripts/dev/verify-change.sh --list`, then run the applicable checks.
  Its summary is `.build/verify/summary.md`; docs-only changes need no app run.
- Meaningful code needs an independent full-diff review against the real base.
  Broad or release-impacting work also needs
  `bash scripts/ops/transcripted-qa-bench.sh --mode full`, as required by
  `AGENTS.md`. Read `docs/qa-test-bench.md` for bench modes and their limits.
- For artifact validators and native UI/import/package smoke commands, read
  `Tools/TranscriptedQA/AGENTS.md` and the selected command's help. Do not run
  the CLI's default artifact validation against the owner's library merely to
  establish baseline counts. Use explicit owned fixtures for automated tests.

## State, privacy, and native checks

Automated harnesses never write to the real capture library or preferences.
Use owned fixture roots, check ownership before deleting, and set
`TRANSCRIPTED_DISABLE_FILE_LOGGER=1` when running binaries directly. Storage
locations and relocation rules live in `docs/storage-paths.md`.

Native app-launch checks require a separate OS account or verified CI
isolation; a temporary `HOME` does not isolate preferences or TCC. Respect the
existing isolation guards and running-app checks. Never override a running
app's rebuild guard or quit the owner's app to make a check run. Real mic,
Bluetooth, system audio, and paste-back proof remain separate from synthetic
results; follow the live-check handoff in `AGENTS.md` and the `verify` skill.

Keep raw transcripts, writing, audio references, private log content, and other
sensitive values out of shared reports and off-device telemetry. Report fixed
failure identifiers and redacted diagnostics instead of quoting user content.

## Investigate and report

Trace a failure through the test inputs and actual owning code, fix its cause,
and rerun the affected check. Follow `Tests/README.md`: no retry-until-green,
source-text assertions, or assertions on wall-clock time. Do not weaken a check to
make it pass. Apply the subsystem's existing rules to fixes, including the
real-time audio and AirPods guidance.

Report the exact head and base, commands and exit status, review verdict,
receipt locations, failures, skipped or blocked checks, and remaining manual
work. SKIP or BLOCKED is incomplete proof. Do not equate a build, fixture pass,
or published feed with native capture, installed-app upgrade, or live behavior.
