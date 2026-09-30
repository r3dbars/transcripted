# Transcripted Tools, scripts, smoke, and CI test audit

Baseline: `85bbcc09380f6de16e73119efb672e5e6a628f72` (2026-09-30). Read-only lane; no repository source, tests, workflow, settings, credentials, or user data changed. The only created files were inert `/tmp` checker fixtures, automatically removed, and this report outside the checkout.

Method: [OpenClaw test-audit](https://github.com/openclaw/openclaw/blob/main/.agents/skills/test-audit/SKILL.md), applied as read-only discovery under Transcripted's own `AGENTS.md`, `Tests/README.md`, package `CLAUDE.md` files and actual verification routing. Tests need an observable promise, credible failing regression, primary owner, and distinct risk when another boundary repeats the scenario. Slow or static checks remain valuable when they enforce independent storage, platform, package, privacy, or release contracts. No deletion quota or proposed weakening of existing checks.

## Coverage and limits

Complete file inventory and structural scan of all Tools package test files, BuildDependencies scripts, Integration/E2E sources, named script suites, seven workflows, `check.sh`, Linux checks, test matrix, and QA/benchmark entrypoints. Targeted complete reads of all four BuildDependencies tests, all package guidance, MCP lock/read and summary-index regression sections, frontmatter corpus tests, executable startup tests, CLI build-mode tests, QA imported-artifact and isolation tests, Lab kit tests, known-traps checker, and smoke/CI entrypoints. Relevant owner implementations and history were inspected for the findings below. This is not an assertion-by-assertion semantic review of every one of the 549 Swift test functions or 330 Python methods, nor a full dependency-backed review of every ML harness. The large MCP owner was read at the locking, schema, reconcile, and caller boundaries rather than all ~1,800 lines. There are no deletion-ready candidates here.

Counts are declarations/files, not executed cases. Some are compile-gated or opt-in; XCTest/Swift Testing cases and parameterized checks do not share one counting unit.

| Surface | Files | Test function declarations | Standard routing |
| --- | ---: | ---: | --- |
| TranscriptedCaptureKit | 6 | 75 | Swift CI SPM job, `check.sh full`, consumer matrix |
| TranscriptedCLI | 13 | 159 | Swift CI retrieval plus audio/meeting/retrieval transitions; some real executable ML tests skip without explicit inputs |
| TranscriptedMCP | 16 | 215 | Swift CI SPM; includes one support file in the file count |
| TranscriptedQA | 11 | 92 | Swift CI SPM; command fixtures are distinct from actual native UI launches |
| TranscriptedLab | 1 | 8 | Path-filtered separate Lab workflow on macOS 15 |
| SpeakerEvalHarness | 0 conventional test files | 0 XCTest methods | Explicitly exempted from hosted CI; production-owned `AutoResearchSelfTests.swift` has `autoeval-self-test` and five named subsidiary tests plus inline assertions |
| BuildDependencies | 4 shell tests | shell cases | All four on every PR: Archive/Manifest/Packaging in Swift CI, Sparkle in Repo Hygiene |
| Integration | 6 Swift files | executors/scaffolds | App/Core, wake recovery and Parakeet via integration smoke; Home reservation executor currently manual |
| E2E | 2 Swift files | artifact and pasteback scenarios | Artifact on every PR; slow pasteback local or optional hardware dispatch |
| Standalone Python `test*.py` | 17 | 330 `test_` methods | 7 suites plus matrix self-test on every PR; 6 hillclimb suites local path-mapped; 3 voiceprint suites not in standard CI |

Linux runner currently lists **60 checks** on this baseline and host: 15 explicit Python self-test scripts, 7 explicit Python suites (133 methods), checker self-tests/actual contracts, syntax, release/privacy checks, and deterministic fixtures. Ruby is mandatory under CI `--strict-tools`; non-CI can report it skipped. No Ruby suite is presently registered in `RB_TEST_SUITES`, though the dictation-recovery fixture checker runs explicitly. The nine Python suites not in the seven-suite CI list contain 197 methods (164 hillclimb + 33 voiceprint). Syntax compilation is not behavior proof.

## Priority findings and evidence

### P1 follow-up: unique real-Core deletion reservation proof is not routed into CI

- Exact boundary: `Tests/Integration/HomeMeetingDeletion/ReservationSmoke.swift:151-250`, run by `scripts/dev/test-home-deletion-reservation.sh:36-58`.
- Observable promise: an active real Core transcript-replacement reservation prevents Home delete/Trash, including a precomputed deletion plan; releasing it permits deletion and byte-preserving Undo.
- Owner/callers: `Sources/UI/Shared/HomeMeetingDeletion.swift` executes Home deletion/Trash and calls real `TranscriptSaver` reservation registry; `CaptureUndo`, archive resolver, renamer/recovery components are exercised together. Production replacement reservations live in Core transcript rewrite/save paths.
- Overlap: root `HomeMeetingDeletionTests` covers injected/default app behavior, and artifact E2E covers canonical removal/retained unrelated data. Neither substitutes for this real app/Core reservation boundary. This smoke deliberately links the debug Core library.
- Routing evidence: no invocation of `test-home-deletion-reservation.sh` in workflows, `check.sh`, `run-tests.sh`, `run-integration-smoke.sh`, or matrix. Generic `Tests/Integration/**` routing suggests integration smoke, whose explicit steps omit this executor. Whole-repo `rg` finds only its own script as a caller.
- History: `fccb28c2` (2026-09-21), “Fix playback, deletion, and capture lifecycle regressions,” added this smoke and documented its safety purpose.
- Change shape: retain the smoke; wire a narrowly scoped check after Core `swift test` artifacts exist, or give it an explicit matrix/CI lane. No production seam deletion or production-code fix is called for.
- Risk: linkage/mtime checks require fresh `.build/debug` Core artifacts; route ordering matters. No user Trash/audio/private corpus involved.
- Focused proof: `bash scripts/dev/test-home-deletion-reservation.sh` after `bash build-deps.sh` and `swift test`. Not run in this read-only lane.

### P2: Tools CI-routing checker accepts a comment as executable test coverage

- Exact owner/test: `scripts/dev/check-known-traps.py:43-65`, `self_test():95-111`.
- Promise: every non-exempt `Tools/*` package actually runs in a workflow and has mapped verification.
- Credible regression: remove a package's executable test step but leave its path in a comment; an author assumes checker coverage still protects the package.
- Reproduction, executed on inert `/tmp` fixture: an Alpha package, exempt SpeakerEvalHarness fixture, matrix with both package paths and `echo no test`, and workflow with only `# Tools/Alpha is not run` plus `run: echo no test` produced `check_tools_ci(root) == []`. Baseline has a demonstrated false negative. Actual existing package workflows are correctly routed; this is guard robustness, not evidence that current package tests disappeared.
- Non-test callers: Linux checks and test-matrix invoke the checker; Repo Hygiene executes Linux checks on every PR.
- Existing proof: self-test only tests absent path, present actual command, and absent matrix mention. It never supplies a comment-only or disabled step. Other build/package tests prove their own packages when reached; they cannot enforce reachability of a newly added package.
- History: `9610d033` introduced the testing foundation/checker, explicitly to prevent omitted Tools CI.
- Change shape: add owner-boundary negative controls and make checker distinguish runnable commands from mere path mentions. This is test tooling work; no app behavior should change. Do not replace it with another substring inventory test.
- Focused proof: `PYTHONDONTWRITEBYTECODE=1 python3 scripts/dev/check-known-traps.py --self-test` and checker against real repository. Only the baseline inert-fixture negative control was executed here.

### P2: mandatory SQLite test-query failure becomes a skipped storage regression

- Exact helper: `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/SummaryItemIndexTests.swift:418-428`, `rowCount(_:)`.
- Users: `testConcurrentReconcilesFromTwoProcessesIndexEachMeetingOnce` (method around lines 354-390) and `testReconcileReplacesLeftoverSummaryDocumentForUnindexedMeeting` (393-415).
- Actual detection: public results plus independent SQL row count ensure shared reconciliation has one summary document per artifact and interrupted work heals.
- Defect: `sqlite3_open` or `sqlite3_prepare_v2` failures throw `XCTSkip`. SQLite is a mandatory linked package dependency and the tests just created the local index, so required test infrastructure/schema/query failures should fail. Skipping erases the independent row-count assertion. A total table removal may also be caught by earlier reconcile assertions; do not overclaim that all schema failures evade the entire suite.
- Owner/callers: `TranscriptIndex.init/reconcile/indexMeeting`, schema in `TranscriptIndex+Schema.swift:217-263`; production `Main.swift` startup and file watchers invoke reconcile. Public queries/tool handlers consume results.
- Overlap/history: real concurrent MCP executable startup proof covers cold start/transport, not summary row cardinality; `7ad44a18`/#1835 added idempotent reconcile after observed `UNIQUE constraint failed: meeting_summary_documents.filename` failures. Keep these tests.
- Change shape: fail or throw a real test error for mandatory SQL/query setup failures; keep assertions and cleanup. No production-code simplification, export, or seam deletion needed.
- Risk/proof: synthetic isolated SQLite only. `swift test --package-path Tools/TranscriptedMCP --filter SummaryItemIndexTests`; add a controlled nonexistent-table/query negative control to ensure the assertion helper fails rather than skips. No Swift run or mutation here.

### P2: strict-concurrency ratchet is local “full” proof but missing from CI

- Exact routing: `scripts/entrypoints/check.sh:116-132` includes `bash scripts/dev/concurrency-census.sh --check`; `.agents/test-matrix.yml:218-227` maps it for all Swift sources.
- Actual CI: `.github/workflows/swift-ci.yml` builds in its ordinary mode; no census call. `scripts/dev/linux-checks.sh:196` only runs `concurrency-census.py --self-test`, which tests parser/checker logic, not the app's warnings. No workflow calls the strict typecheck.
- Independent contract: a per-folder Swift 6 warning backlog may not grow while shipping app stays in Swift 5 mode. Ordinary successful builds do not enforce this invariant.
- Owner: `concurrency-census.sh` shares real app compiler argument builder and typechecks production app sources with `-strict-concurrency=complete`; Python compares `.agents/concurrency-baseline.json`.
- History: `9610d033` introduced the ratchet; `edc8cb49` fixed Today concurrency warnings rather than deleting the gate.
- Change shape: preserve gate and add it after built deps in the appropriate Swift CI job, or make documented local/CI difference explicit. No baseline loosening.
- Risk/proof: extra typecheck cost; dependency availability matters. `bash scripts/dev/concurrency-census.sh --check` against final fresh deps. Not run here.

### P2 retained follow-up: MCP lock-progress test uses guessed scheduler readiness

- Exact test: `TranscriptIndexTests.swift:477-528`, `testReadToolsKeepAnsweringWhileReconcileWaitsOnAnotherProcess`.
- Promise: another process holding `mcp_index.reconcile.lock` cannot make reads wait behind this instance's reconcile.
- Existing test holds a real independent flock, dispatches reconcile, sleeps 0.3 seconds, then requires a read to complete within 2 seconds. The sleep is not evidence reconcile reached the lock. If the background worker is delayed until after the read, the old queue-before-flock behavior can pass. Two seconds is a liveness deadline, not a product latency measurement; simply widening it does not prove contention.
- Owner/callers: `TranscriptIndex.swift:48-68,195-215` obtains file lock outside serial queue; production watcher/startup calls reconcile; tool handlers perform reads on that queue.
- Overlap: concurrent index/cold-start tests protect insert uniqueness/transport, distinct risks. Keep this lock/read regression.
- History: `2c57ec2d`/#1841 fixed lock placement; `1b02cf75`/#1844 added this exact test to protect it.
- Follow-up: seek observable contention synchronization at a real boundary, with mutation proof restoring queue-before-lock; no test-only production flag/export. This lane did not mutate or execute it, so scheduler false-negative risk is a code-based inference, not a reproduced flake.
- Focused proof: `swift test --package-path Tools/TranscriptedMCP --filter TranscriptIndexTests.testReadToolsKeepAnsweringWhileReconcileWaitsOnAnotherProcess` plus a deliberate old-order mutation in an isolated checkout.

## Valuable checks retained; coverage that must be described accurately

- All four BuildDependencies tests remain. ArchiveInputs executes the production archive/module helpers against fake object/module layouts, with independent `_main` exclusion, nm errors, ambiguity, layout and copying assertions. CLIManifest evaluates the actual manifest, failing closed for missing required modules/archives while retrieval stays independent. CLIPackaging executes real bundling with inert executables and rejects incomplete capabilities, invalid JSON, failing `build-info`, and checkout rpaths; its final signing-order source inspection is fragile to refactors but currently the cheapest independent wiring guard, not a deletion candidate without stronger two-entrypoint proof. Sparkle runs the real appcast script and checks output XML/manifest/history and failure-before-write; private signing key must travel on stdin. `5c0e21e3` fixed its no-delta assertion to inspect only the new item. The separate CI audit's version-prep failures are legitimate release cross-file integrity failures, not grounds for removing checks.
- Frontmatter corpus fixtures are shared independent artifact/format goldens. CaptureKit, Core and MCP have distinct parser/boundary behavior, including documented divergences and EOF crash regression. Shared fixtures are useful cross-consumer consistency proof; do not call this blanket duplicate coverage.
- MCP process tests exercise a real executable MCP initialize round trip, including concurrent cold index startup. They protect transport/startup risks helper tests cannot reach. Path validation, mandatory SQLite storage and privacy tests remain.
- CLI BuildMode compares independent runtime requested/expected mode with compiled capabilities, protecting cached-manifest/build transition mistakes. Capability JSON key set is an independent packaging protocol. The opt-in real executable E2E tests protect failure/cleanup, signals, no-overwrite and read-only speaker DB/input audio, but need `TRANSCRIPTED_CLI_E2E_BINARY`, `TRANSCRIPTED_CLI_E2E_AUDIO`, `TRANSCRIPTED_CLI_E2E_MODELS`, and `TRANSCRIPTED_CLI_E2E_DIARIZATION`. Their presence/compilation does not mean those ML cases ran in normal CI.
- QA `ImportedAudioSmokeRunner` writes its own Markdown and copies generated WAV, then exercises real parsing, location discovery and validator. This proves artifact consumer contract, not actual app import/transcription/publication. The package test accurately says it passes and writes evidence. Native import and CLI executable lanes supply separate producer proof.
- Isolation, permissions, signing, dSYM, DMG, Sparkle-key and log-privacy evaluators are independent safety/release contracts. Shared synthetic evaluators do not prove a real launch or update install; native smoke requires separate account/hosted guard and reports blockers as incomplete.
- `SummaryItemIndexTests.testFiveHundredMeetingSummaryBackfillBudget:291-320` genuinely enforces a 500-meeting performance contract (60s plus indexed/searchable output). Keep it; consider benchmark ownership/noisy-host treatment separately. Performance limits must not be removed merely for using time.
- `performance-budget.rb` is an independent gate: app/resources size, resource/model presence, launch smoke and optional latency/stat populations; hosted CI explicitly uses 220/80MiB thin-build caps, 3000ms launch catastrophe ceiling, Home 750ms average/100ms cancel defaults, and allows missing Parakeet model. Product warm launch target is a separate stronger local measurement. The CI-audit-reported real Home cancel failure should remain actionable.
- `bench-all.sh` and repeated launch sampler are measurements rather than green build gates. Private real-usage logs and corpora are never accessed in this audit. `bench-all` intentionally records failed/skipped sections while reporting data; its exit status must not be treated as a blocking test result.
- Monthly mutation runs six selected policies, report-only, conditional on owner Mac heartbeat; a survivor is a gap, not PR failure. No mutation campaign occurred here.

## Workflow and smoke routing

| Workflow | Trigger / runner | Proof / limit |
| --- | --- | --- |
| `swift-ci.yml` | Every PR, main push, manual; macOS 26 | Pick runner; checks (source list, Archive/CLIManifest/CLIPackaging, fast tests with timing cases skipped, artifact E2E); SPM (deps, Core/Writing, integration incl Parakeet lifecycle, four Tools, CLI mode transitions); hosted app build + performance budget; always-running Ubuntu umbrella requires all four upstream results success. Optional dispatched hardware smokes separate from umbrella. |
| `repo-hygiene.yml` | Every PR/manual; Ubuntu | Linux checks strict tools, plus some intentional repeated inline contracts/syntax, VM guards, runner guards, Sparkle deltas, critical appcast marker. No app Swift compile. |
| `transcripted-lab.yml` | Lab/docs/workflow path-filtered PR/main; macOS 15 | 8 kit tests, CLI/app builds, verify bundle. Separate job name avoids satisfying Swift umbrella accidentally. |
| `mutation-monthly.yml` | Monthly/manual owner runner | Six fast decision-file mutation probes; report-only and conditional heartbeat. |
| `mac-runner-sweep.yml` | Half-hourly/manual Ubuntu | Re-route runs stuck behind unavailable owner Mac; operational, not product proof. |
| `release-candidate.yml` | Manual hosted macOS | Signed/notarized candidate; signing/stapler/model manifests, appcast/cask preparation, actual packaged UI/reliability smoke/privacy/post-DMG audit. Does not replace full PR suite. Not executed or modified. |
| `publish-mcp-registry.yml` | Published release/manual macOS | Packages published helper, codesign verifies it, validates MCP bundle manifest; publication flow, not ordinary PR tests. Not executed or modified. |

`run-integration-smoke.sh` validates dependency freshness, links production Core constructors/archive, runs wake executor, Parakeet lifecycle fake-model executor and targeted Core merger tests. It does not run Home reservation smoke. `run-e2e-smoke.sh` compiles consumer source set plus CaptureKit and real dictation persistence/failed-manager/deletion owners, writes synthetic meeting artifacts and validates Home/MCP discovery/privacy/deletion. It does not launch app, capture audio, or run native ML. Slow pasteback smoke uses named synthetic pasteboards and real paster; it has stale-control negatives, but timer/window scenarios are intentionally excluded from ordinary hosted PR proof, including timing-sensitive fast cases. No claim of actual mic/AirPods/system-audio/pasteback-focus coverage.

QA bench: quick = build + fast + artifact E2E + slow pasteback; deep adds integration/Core/QA tests, validator corruption round trip, stress fixture, imported artifact, synthetic audio and current-artifact validation; full adds release-health/PostHog fixtures. `full` does not imply every Tools package or native UI mode. UI, native import, fake Sparkle UI and packaged modes are separate; live adds permission-state before actual capture. Current-artifact validation defaults to real selected library; this audit intentionally did not execute it. Incomplete/warnings/skips are not green native proof.

## Commands actually executed

- Read/search/count commands (`rg`, Python AST/static inventory, `git log/show`, no checkout mutation).
- `bash scripts/dev/linux-checks.sh --list` twice for route/count inventory: listed 60 checks, did not run them.
- Two inert `/tmp` executions of the real `check_tools_ci` function. First fixture had an unrelated missing exempt package and was corrected; final fully formed fixture confirmed comment-only routing accepted. Both directories removed automatically, Python bytecode disabled.

No Swift package build/test, fast suite, full/release/QA run, live capture, native launch, private audio, corpus, user logs, deployment, publishing, Git mutation or settings change in this lane. The coordinating lane owns final focused/full proof and exact-head CI verification.

## Complete file appendices

### SpeakerEvalHarness
- `Tools/SpeakerEvalHarness/Sources/speaker-eval-harness/AutoResearchSelfTests.swift` — in-source command self-test

### TranscriptedCLI
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/BuildModeTests.swift` — 2 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/CLIModelPathsTests.swift` — 6 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/ConfigLoaderTests.swift` — 7 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/ContextDirectoriesTests.swift` — 11 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/ContextStoreTests.swift` — 41 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/ImportAudioCommandTests.swift` — 5 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/ImportAudioExecutableE2ETests.swift` — 7 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/MeetingImportPublisherTests.swift` — 19 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/MeetingImportSpeakerMappingTests.swift` — 12 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/MeetingImportWorkflowTests.swift` — 9 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/SpeakerDatabaseSnapshotTests.swift` — 7 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/TranscribeOutputTests.swift` — 21 test function declarations
- `Tools/TranscriptedCLI/Tests/TranscriptedCLITests/WritingContextTests.swift` — 12 test function declarations

### TranscriptedCaptureKit
- `Tools/TranscriptedCaptureKit/Tests/TranscriptedCaptureKitTests/CaptureLibraryResolverTests.swift` — 9 test function declarations
- `Tools/TranscriptedCaptureKit/Tests/TranscriptedCaptureKitTests/CaptureLibraryWritingResolverTests.swift` — 12 test function declarations
- `Tools/TranscriptedCaptureKit/Tests/TranscriptedCaptureKitTests/CaptureMarkdownParserTests.swift` — 28 test function declarations
- `Tools/TranscriptedCaptureKit/Tests/TranscriptedCaptureKitTests/CaptureSummaryParserTests.swift` — 14 test function declarations
- `Tools/TranscriptedCaptureKit/Tests/TranscriptedCaptureKitTests/FrontmatterCorpusParityTests.swift` — 4 test function declarations
- `Tools/TranscriptedCaptureKit/Tests/TranscriptedCaptureKitTests/WritingDayParserTests.swift` — 8 test function declarations

### TranscriptedLab
- `Tools/TranscriptedLab/Tests/TranscriptedLabKitTests/TranscriptedLabKitTests.swift` — 8 test function declarations

### TranscriptedMCP
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/AgentCaptureQueryTelemetryTests.swift` — 14 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/AudioDirectoryNamingTests.swift` — 1 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/DataDirectoriesTests.swift` — 12 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/FrontmatterCorpusParityTests.swift` — 5 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/LoggingTests.swift` — 6 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/NameVariantsTests.swift` — 10 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/ProcessStartupTests.swift` — 2 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/RecentMeetingsWidgetTests.swift` — 11 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/SemanticSearchTests.swift` — 20 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/SummaryItemIndexTests.swift` — 17 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/SummaryRollupTests.swift` — 13 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/TestHelpers.swift` — 0 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/ToolHandlersTests.swift` — 40 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/TranscriptIndexTests.swift` — 33 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/TranscriptLoaderTests.swift` — 16 test function declarations
- `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/WritingToolTests.swift` — 15 test function declarations

### TranscriptedQA
- `Tools/TranscriptedQA/Tests/TranscriptedQATests/ImportedAudioNativeSmokeTests.swift` — 2 test function declarations
- `Tools/TranscriptedQA/Tests/TranscriptedQATests/ImportedAudioSmokeTests.swift` — 1 test function declarations
- `Tools/TranscriptedQA/Tests/TranscriptedQATests/LegacyCaptureDirectoriesContractTests.swift` — 2 test function declarations
- `Tools/TranscriptedQA/Tests/TranscriptedQATests/NativeSmokeIsolationTests.swift` — 4 test function declarations
- `Tools/TranscriptedQA/Tests/TranscriptedQATests/PackagedAppSmokeTests.swift` — 21 test function declarations
- `Tools/TranscriptedQA/Tests/TranscriptedQATests/PermissionStateProbeTests.swift` — 11 test function declarations
- `Tools/TranscriptedQA/Tests/TranscriptedQATests/PermissionStateRuntimeGateTests.swift` — 5 test function declarations
- `Tools/TranscriptedQA/Tests/TranscriptedQATests/SparkleUpdateSmokeTests.swift` — 3 test function declarations
- `Tools/TranscriptedQA/Tests/TranscriptedQATests/SpeakerStatsTests.swift` — 9 test function declarations
- `Tools/TranscriptedQA/Tests/TranscriptedQATests/ValidatorTests.swift` — 25 test function declarations
- `Tools/TranscriptedQA/Tests/TranscriptedQATests/WritingValidatorTests.swift` — 9 test function declarations

### Standalone script suites
- `scripts/dev/test-matrix-checks.py` — 0 test methods (matrix selector uses inline assertions instead)
- `scripts/hillclimb/benches/test_dictation_stop.py` — 23 test methods
- `scripts/hillclimb/benches/test_meeting_import.py` — 23 test methods
- `scripts/hillclimb/benches/test_speaker_autoeval.py` — 24 test methods
- `scripts/hillclimb/benches/test_speaker_lab.py` — 31 test methods
- `scripts/hillclimb/test_hc_proc.py` — 8 test methods
- `scripts/hillclimb/test_hillclimb.py` — 51 test methods
- `scripts/hillclimb/test_lab_control.py` — 35 test methods
- `scripts/ops/test-native-smoke-isolation.py` — 4 test methods
- `scripts/ops/test-nightly-security-check.py` — 6 test methods
- `scripts/ops/test-score-boards.py` — 23 test methods
- `scripts/test_score_speaker_lab.py` — 29 test methods
- `scripts/test_speaker_autoresearch.py` — 9 test methods
- `scripts/test_stt_fluidaudio_ab.py` — 31 test methods
- `scripts/voiceprint/test_naming_sim.py` — 10 test methods
- `scripts/voiceprint/test_score_lineup.py` — 4 test methods
- `scripts/voiceprint/test_score_verify.py` — 19 test methods

### BuildDependencies, E2E and Integration
- `Tests/BuildDependencies/ArchiveInputsTests.sh`
- `Tests/BuildDependencies/CLIManifestTests.sh`
- `Tests/BuildDependencies/CLIPackagingTests.sh`
- `Tests/BuildDependencies/SparkleAppcastDeltaTests.sh`
- `Tests/E2E/SlowPastebackSmoke.swift`
- `Tests/E2E/TranscriptedE2ESmoke.swift`
- `Tests/Integration/AppCoreIntegrationSmoke.swift`
- `Tests/Integration/HomeMeetingDeletion/ReservationSmoke.swift`
- `Tests/Integration/ParakeetLifecycle/EngineScaffold.swift`
- `Tests/Integration/ParakeetLifecycle/ExecutorSmoke.swift`
- `Tests/Integration/ParakeetLifecycle/FakeFluidAudio.swift`
- `Tests/Integration/WakeRecoveryIntegrationSmoke.swift`

### Explicit Linux ops/release self-test scripts
- `scripts/ops/check-crash-free-rate.py`
- `scripts/ops/generate-nightly-digest.py`
- `scripts/ops/packaged-app-smoke.py`
- `scripts/ops/posthog-activation-funnel.py`
- `scripts/ops/posthog-dashboard-queries.py`
- `scripts/ops/posthog-product-context-pack.py`
- `scripts/ops/posthog-product-dashboard-summary.py`
- `scripts/ops/release-gate-report.py`
- `scripts/ops/release-health-card.py`
- `scripts/ops/release-watch.py`
- `scripts/ops/retention-cohort-report.py`
- `scripts/release/bump-release-version.py`
- `scripts/release/post-dmg-release-audit.py`
- `scripts/release/sentry-release-dry-run.py`
- `scripts/dev/mutation-probe.py`

### Other script self-test entrypoints and dispatchers

The preceding explicit list contains 15 of the 40 script self-test entrypoints found by marker/dispatch inspection. The remaining 25 are listed below. Hillclimb adapters/dispatcher re-run the standalone suite files above; they are not additional methods. Four files containing only self-test references (`linux-checks.sh`, QA bench, STT shootout `run.sh`, VM `transcripted-vm.sh`) are wrappers, not counted again.

- `scripts/ci/mac-runner.sh`
- `scripts/ci/pick-ci-runner.py`
- `scripts/dev/agent-check.py`
- `scripts/dev/agent-context.py`
- `scripts/dev/check-doc-paths.py`
- `scripts/dev/check-duplicate-declarations.py`
- `scripts/dev/check-known-traps.py`
- `scripts/dev/check-source-pins.py`
- `scripts/dev/check-superseded.py`
- `scripts/dev/check-telemetry-keys.py`
- `scripts/dev/check-test-shape.py`
- `scripts/dev/concurrency-census.py`
- `scripts/dev/explain-missing-sources.py`
- `scripts/dev/test-matrix-checks.py`
- `scripts/hillclimb/benches/dictation_stop.py`
- `scripts/hillclimb/benches/meeting_import.py`
- `scripts/hillclimb/benches/speaker_autoeval.py`
- `scripts/hillclimb/benches/speaker_lab.py`
- `scripts/hillclimb/hillclimb.py`
- `scripts/hillclimb/lab_control.py`
- `scripts/release/mark-appcast-critical.py`
- `scripts/stt-shootout/hillclimb_bench.py`
- `scripts/stt-shootout/shootout.py`
- `scripts/vm/supervise.py`
- `scripts/vm/vnc.py`
