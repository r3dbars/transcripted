# Test Automation Strategy

This is the agent-first map for making Transcripted QA output more useful over
time. Use it with `.agents/test-matrix.yml` and `.agents/qa-gates.yml`.

`test-matrix.yml` answers: "I changed these files. What do I run?"

`qa-gates.yml` answers: "This risk matters. What proof counts?"

## Current Inventory

As of 2026-06-06, the repo has these automated layers:

- `bash run-tests.sh`: manifest-driven fast runner for app-facing logic. The
  root `Tests/` set has 105 Swift test files and must stay aligned with
  `Tests/FastTests.manifest`.
- `bash build.sh --no-open`: authoritative menubar app build.
- `swift test`: Swift Package tests for `TranscriptedCore`; currently 33 core
  test files under `Tests/TranscriptedCoreTests/`.
- `bash run-integration-smoke.sh`: app/core linkage, wake recovery, and selected
  core smoke coverage from `Tests/Integration/`.
- `bash run-e2e-smoke.sh`: deterministic artifact smoke for release-critical
  dictation, meeting, MCP, retained-audio, and diagnostics contracts.
- `bash run-live-capture-smoke.sh`: local mic plus system-audio smoke. This is a
  local hardware/TCC gate, not default CI.
- `swift run --package-path Tools/TranscriptedQA transcripted-qa permission-state`:
  no-prompt Codex/computer-use permission preflight for Accessibility, event
  posting, input monitoring, screen capture, Automation, microphone state, and
  Transcripted app identity.
- `bash scripts/ops/transcripted-qa-bench.sh --mode ...`: orchestrated QA
  reports for `quick`, `deep`, `ui`, `artifact`, `audio-synthetic`, `corpus`,
  `corpus-compare`, and `live`.
- `.github/workflows/repo-hygiene.yml`: PR/workflow-dispatch hygiene that runs
  preflight plus shell, Ruby, and Python syntax checks.
- BET-88 GitHub workflows: historical label-gated fixtures for the closed QA
  gate, not the general product gate.

## Main Gaps

- UI: there are good policy tests, plus `--mode ui` now drives the built app
  through Accessibility for menu bar, Home, Settings, and General navigation.
  Codex/computer-use also needs permission-state proof before click results
  count. Deeper sheets, media controls, and sanitized screenshots still need
  coverage.
- Audio: synthetic fixtures now cover shared mic, missing system audio, quiet
  mic, output ducking, route churn, stop timeout, and stop/save outcomes. Real
  Zoom/WebRTC/Bluetooth perceived-volume proof is still manual.
- Storage: current/default paths are covered, but relocated libraries,
  retention/compression invariants, and legacy fallback paths need broader
  automated fixtures.
- Release: release docs and scripts exist, but agents need one release-health
  report that compares source truth with GitHub release, appcast, cask, live
  download, crawler text, and Sentry metadata.
- Privacy: sanitizer tests exist, but QA bench reports, generated PR text, local
  logs, and release notes need a single leakage sweep.
- Summaries: summary preferences and local summarizer behavior have tests, but
  quality fixtures and the opt-in beta guard need a clearer recurring check.
- Support bugs: issue-specific docs exist, but there is no bug seed registry
  mapping support bug -> reproducer -> automated guard -> manual proof still
  required.

## Recommended Gates

Pre-merge should stay path-based:

- Run `scripts/dev/agent-preflight.sh`.
- Run the union from `.agents/test-matrix.yml`.
- Add `bash scripts/ops/transcripted-qa-bench.sh --mode quick` when the diff is
  broad, cross-module, or user-visible.
- Add `bash scripts/ops/transcripted-qa-bench.sh --mode ui` when the diff
  changes menu bar, Home, Settings, or navigation and Accessibility permission
  is available locally.
- Do not mark green if a required check was skipped without a blocker reason.

Nightly should produce a report, not just raw logs:

- Run repo hygiene or the local equivalent.
- Run QA bench `quick`.
- Run `python3 scripts/ops/nightly-security-check.py --write-report build/nightly-security-report.json`.
- Rotate deeper lanes: `deep`, `audio-synthetic`, `corpus`, and
  `corpus-compare`.
- Always name the first human action if something needs manual proof.

Release-candidate should prove the shipped path:

- Run `bash build-deps.sh --force`.
- Run `bash build.sh --no-open`.
- Run `bash run-tests.sh`.
- Run `bash run-integration-smoke.sh`.
- Run `bash run-e2e-smoke.sh`.
- Run `swift test`.
- Run `bash scripts/ops/transcripted-qa-bench.sh --mode deep --strict-artifacts`.
- Run `bash scripts/ops/transcripted-qa-bench.sh --mode ui` when Accessibility
  permission is available and the release confidence call needs visible UI
  proof.
- Run `SKIP_NOTARIZATION=1 bash build-beta.sh '' <user-name>` for packaging
  smoke, or the full notarized path for a real release.
- If users should receive the build, also verify Sparkle, Homebrew, live
  download, and Sentry release metadata.

Manual proof is still required for:

- real meeting-app volume behavior
- microphone and System Audio Recording permission behavior
- fresh TCC grant/deny/revoke behavior for Codex and Transcripted
- Bluetooth or input-device switching
- sleep/wake during capture
- pasteback feel in real apps
- speaker review and manual rename feel
- update install behavior on existing installs

## Agent Output Contract

Every QA lane should say:

- GREEN, YELLOW, or RED
- exact commands run
- exact checks skipped and why
- local report paths
- what is automated proof vs manual proof
- whether private logs, corpus, audio, or transcripts were involved
- the smallest next action

Keep private data local. Do not paste transcript text, audio, meeting titles,
speaker names, emails, tokens, absolute paths, private URLs, or raw device names
into PRs, issues, or agent reports.

## Next High-Value Automations

1. Add UI automation surface IDs, permission-state gating, and a sanitized UI
   snapshot gate for first value, meeting, dictation, speaker review, and agent
   connect.
2. Add a real-app route trend report for Justin's Mac: Chrome/Safari/Firefox
   Meet, Zoom, Bluetooth/AirPods, perceived volume, and saved-transcript proof.
3. Add a release-health report that compares source, GitHub, appcast, cask,
   live download, crawler text, and Sentry metadata.
4. Add storage invariants for relocated capture libraries, retained-audio
   cleanup, compression, and fallback paths.
5. Add a support bug seed registry so future agents know which bugs have an
   automated guard and which still need manual proof.
