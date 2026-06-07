# Agent Onboarding

This repo already has multiple layers of documentation. The main improvement
needed for coding agents is consistency: know which docs are current, which are
historical, and which local doc to read before editing a subsystem.

## Read Order

1. `AGENT_START.md`
2. `README.md`
3. `AGENTS.md`
4. `docs/repo-layout.md`
5. `docs/agent-onboarding.md`
6. `CLAUDE.md`
7. `Sources/CLAUDE.md`
8. the nearest local `CLAUDE.md`
9. `Sources/Accessibility/CLAUDE.md` when touching focused-editor AX metadata, overlay placement, or paste-back context
10. `Sources/Beta/CLAUDE.md` when touching beta-build configuration
11. `Sources/Dictation/CLAUDE.md` when touching dictation persistence
12. `Sources/Meeting/CLAUDE.md` when touching meeting capture, imported-audio transcription, or meeting UI
13. `Sources/TranscriptedCore/CLAUDE.md` when touching the reusable meeting library or public core seam
14. `Sources/Speech/CLAUDE.md` when touching STT, audio recovery, or device handling
15. `Sources/Support/CLAUDE.md` when touching shared preferences, paths, permissions, or install flows
16. `Sources/UI/CLAUDE.md` when touching overlay, menubar, onboarding, settings, or agent-connect UI
17. `Sources/Capture/CLAUDE.md` when touching hotkeys or physical dictation trigger routing
18. `Tests/README.md` when touching verification or package seams
19. `docs/storage-paths.md` when touching persisted output or path resolution
20. `Sources/Reliability/CLAUDE.md` when touching wake / sleep recovery or hotkey recovery
21. `Sources/Observability/CLAUDE.md` when touching crash reporting, analytics, or Sparkle plumbing
22. `docs/release-packaging.md` and `docs/sparkle-updates.md` when touching packaging, notarization, releases, or in-app updates
23. `Tools/*/CLAUDE.md` when touching standalone CLI, MCP, or QA tools
24. `scripts/README.md` when touching the shell entrypoints or release helpers
25. `docs/activation-lane.md` when touching saved artifacts, agent handoff, onboarding, first-value, or return-use work
26. `docs/agent-closeout.md` when a delegated worker, automation run, or coordinator thread needs a compact handoff
27. source comments

For the active directory map and command surface, prefer `docs/repo-layout.md`.

## Current Documentation Layers

- `README.md`
  Product intent and repo truth.
- `AGENT_START.md`
  Shortest safe start path for coding agents.
- `AGENTS.md`
  Codex-oriented workflow rules and build/test guardrails.
- `CLAUDE.md`
  Claude-oriented repo overview and runtime truth.
- `Sources/CLAUDE.md`
  App bootstrap and initialization order.
- `Sources/*/CLAUDE.md`
  Local subsystem docs.
- `Tools/*/CLAUDE.md`
  Standalone tool package docs where present.
- `scripts/README.md`
  Canonical map for thin root wrappers vs script implementations.
- `Tests/README.md`
  Verification surfaces and fast-test runner rules.
- `.agents/test-matrix.yml`
  Machine-readable path-to-verification map for agents.
- `.agents/qa-gates.yml`
  Machine-readable map from product risk and QA lane to proof gate.
- `.github/`
  GitHub issue templates, PR checklist, and workflow automation.
- `docs/storage-paths.md`
  Canonical app, tool, and fallback storage layout.
- `docs/test-automation-strategy.md`
  Agent-first QA coverage map, gate strategy, and automation roadmap.
- `docs/activation-lane.md`
  Current activation routing: saved Markdown, agent payoff, and return-use loop.
- `docs/agent-closeout.md`
  Coordinator-ready handoff format, including `COORD_DONE`.
- `docs/docs.md`
  Documentation tone, drift checks, and follow-up PR rules.
- `docs/release-packaging.md` + `docs/sparkle-updates.md`
  Release, notarization, Sparkle, and Homebrew contract.
- `docs/archive/`
  Historical merge/todo docs and other archived planning notes.

## What To Trust Most

When docs disagree, split the decision:

- workflow contracts: `AGENTS.md`, `.agents/test-matrix.yml`, `.agents/qa-gates.yml`, then `scripts/dev/agent-preflight.sh`
- runtime behavior and file existence: current source files
- subsystem intent: current local `CLAUDE.md` files whose file lists match the tree
- historical context: `docs/archive/` only

## Validation Layers

This repo has multiple verification surfaces. Treat them as distinct, and use
`Tests/README.md`, `.agents/test-matrix.yml`, and `.agents/qa-gates.yml` as the
full current map:

- `bash build.sh`
  The authoritative app build. Use `bash build.sh --no-open` for agent verification.
- `bash run-tests.sh`
  Curated fast tests for app-facing logic.
- `bash run-integration-smoke.sh`
  App/Core integration smoke.
- `bash run-e2e-smoke.sh`
  Deterministic release-critical artifact smoke.
- `swift test`
  SPM tests for `TranscriptedCore`.
- `bash run-live-capture-smoke.sh`
  Local hardware/TCC smoke for app launch plus production mic and system-audio capture.
- `bash scripts/ops/transcripted-qa-bench.sh --mode quick`
  Orchestrated QA bench for broader local validation.
- `bash scripts/ops/transcripted-qa-bench.sh --mode full`
  Broad automated QA gate with deep checks, release-health fixture proof, and
  local Gemma summary planning when eligible transcripts exist.
- `bash scripts/ops/transcripted-qa-bench.sh --mode ui`
  Accessibility-driven smoke for menu bar, Home, Settings, buttons, and basic
  navigation. TCC blockers are `INCOMPLETE`, not green.

Rule of thumb:

- run `scripts/dev/agent-preflight.sh` when starting or handing off a branch
- follow the union of checks from `.agents/test-matrix.yml`
- before merging a meaningful code PR, run `codex-review` against the real PR
  base and keep the review result with the PR evidence
- after Swift edits, run `bash build.sh --no-open` and `bash run-tests.sh`
- if you touch `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run
  `bash run-integration-smoke.sh`
- if you touch `Package.swift`, `Sources/TranscriptedCore/`, or the public
  core package seam, also run `swift test`

## Choose The Lane

When the issue is vague, classify it before editing:

- Activation, saved artifacts, agent setup, first prompt, or return-use:
  `docs/activation-lane.md`, `Sources/UI/CLAUDE.md`, and `docs/agent-connect.md`
- Dictation start/stop, no-speech, Bluetooth/AirPods, or model readiness:
  `Sources/Speech/CLAUDE.md`, `Sources/UI/Overlay`, and `docs/audio-reliability-daily-check.md`
- Pasteback, clipboard restore, Auto Enter, or focused app targeting:
  `Sources/Support/CLAUDE.md`, `Sources/Accessibility/CLAUDE.md`, and `Sources/Dictation/CLAUDE.md`
- Meeting capture, retained audio, retry, speaker review, or Zoom/Meet prompts:
  `Sources/Meeting/CLAUDE.md`, `Sources/TranscriptedCore/CLAUDE.md`, and `docs/qa-issue-500-meeting-audio.md`
- Release, updates, Homebrew, Sentry release metadata, dSYMs, or public download
  truth: `docs/release-packaging.md`, `docs/sparkle-updates.md`, and `docs/ops-credentials.md`
- GitHub automation, issue runner, templates, or review packets:
  `WORKFLOW.md`, `docs/agent-issue-orchestration.md`, `.github/`, and `docs/agent-closeout.md`

## Highest-Value Local Docs

- `docs/activation-lane.md`
  Saved Markdown -> useful agent answer -> return-use routing.
- `docs/agent-closeout.md`
  `COORD_DONE` and PR/issue handoff shape.
- `Sources/CLAUDE.md`
  App boot order and shared state wiring.
- `Sources/Accessibility/CLAUDE.md`
  Focused-editor AX metadata, overlay placement, and paste-back context.
- `Sources/Beta/CLAUDE.md`
  Current `BETA_BUILD` shell, removed proxy-token path, and archived beta-worker handoff.
- `Sources/Dictation/CLAUDE.md`
  Dictation persistence, daily Markdown files, and timeout helpers.
- `Sources/Meeting/CLAUDE.md`
  App/Core bridge, meeting storage, runtime lifecycle.
- `Sources/TranscriptedCore/CLAUDE.md`
  Library boundary, pipeline layout, embedder seams.
- `Sources/Speech/CLAUDE.md`
  Dictation STT ownership, recovery policy, and audio-device guardrails.
- `Sources/Support/CLAUDE.md`
  Shared preferences, permissions, app paths, and Claude Desktop install flow.
- `Sources/UI/CLAUDE.md`
  Overlay, menubar, onboarding, settings, and agent-connect ownership.
- `Sources/Capture/CLAUDE.md`
  Global trigger and hotkey routing behavior.
- `Tools/TranscriptedCLI/CLAUDE.md`
  Standalone local-context and offline diarization CLI.
- `Tools/TranscriptedMCP/CLAUDE.md`
  Read-only MCP server for saved meetings and dictations.
- `Tools/TranscriptedQA/CLAUDE.md`
  Standalone artifact validation and QA CLI.

## Historical Zones

Treat these as reference, not source of truth for runtime behavior on `main`:

- `docs/archive/*`
- `docs/archive/screenshots/*`
- `archive/backend-beta-worker/*`
- older cloud/API references in comments or outdated docs

## When To Update Docs

Update docs in the same change whenever you modify:

- build/test commands
- storage locations
- feature flags like `BETA_BUILD`
- cross-module ownership boundaries
- threading/actor-isolation assumptions
- output schemas consumed by tools or agents
- new directories that become real edit targets

## Good Local Doc Shape

The strongest docs in this repo do five things:

- say what the directory owns
- name the important files
- explain lifecycle or data flow
- call out non-obvious constraints
- give exact verification commands

If a doc does not help an unfamiliar agent answer "what owns this, what can I
change safely, and how do I verify it," it should be tightened.

## Large Swift Files

Some live Swift files are intentionally broad coordination surfaces. Do not
split them just because they are large. Prefer one small, tested extraction when
there is an obvious policy/helper seam.

Current high-ingestion files to treat carefully, ranked by agent pain:

1. `Sources/UI/Settings/TranscriptedSettingsView.swift` - Settings shell and page routing
2. `Sources/Speech/ParakeetEngine.swift` - local STT engine, CoreAudio recovery, recording, transcription, and cleanup
3. `Sources/Meeting/MeetingSessionController.swift` - app-level meeting state machine, queueing, failed meetings, and live sidecar coordination
4. `Sources/UI/Settings/HomeView.swift` - Settings home dashboard composition
5. `Sources/UI/Settings/PermissionsOnboardingView.swift` - first-run onboarding flow
6. `Sources/TranscriptedCore/Speaker/RetroactiveSpeakerUpdater.swift` - tested transcript/frontmatter rewrite logic
7. `Sources/UI/Overlay/DictationSessionController.swift` - dictation start/stop, paste, save, and telemetry orchestration
8. `Sources/UI/Overlay/MeetingOverlayController.swift` - meeting prompt/recording panel, views, and tokens
9. `Sources/UI/Settings/SpeakerPeopleSettingsSection.swift` - people settings view model and row composition
10. `Sources/Meeting/LiveMeetingCodexSession.swift` - live sidecar state, file writes, handoff text, and preview HTML
11. `Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift` - Core queueing, retries, task lifecycle, and metadata handoff
12. `Sources/TranscriptedCore/Audio/Audio.swift` - Core mic/system-audio start-stop state, recovery, and capture lifecycle

Safe decomposition usually looks like extracting a pure presentation policy,
formatter, or row helper with focused tests. Risky decomposition looks like
moving state-machine ownership, audio lifecycle code, or cross-module wiring
without a behavior bug to verify against.
