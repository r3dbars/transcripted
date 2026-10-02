# Transcripted test audit — 2026-09-30

Baseline: remote `main` at `85bbcc09380f6de16e73119efb672e5e6a628f72`.
Method: [OpenClaw test-audit](https://github.com/openclaw/openclaw/blob/main/.agents/skills/test-audit/SKILL.md), adapted to Transcripted's Swift/XCTest/Swift Testing, custom assertion runner, scripts, and CI. Discovery used four independent lanes before the bounded edit batch. No Node/Vitest commands or new test dependencies were introduced.

## Outcome

This PR improves deadline and cancellation proof without changing production code:

- `TranscriptedConstantsTests`: a held continuation stays held after cancellation. The detached deadline must return before release, then the operation must observe cancellation and unwind. An independent escape reports failure if work never starts. Structured deadlines assert the exact cancellation error and cooperative unwind. Both helpers now preserve a distinctive operation error.
- `AudioInitializationTests.testStartIfNotCancelledCancelDuringStartDoesNotBlock`: cancellation must return while the old capture start remains held, and a successor must start before release. Removed the 250 ms speed assertion and the fake's timed self-release; retained cancelled-start and teardown assertions.
- Writing personal lookup: an unresolved real race must produce timeout diagnostics without a provider answer. A timed-out waiter must leave a later answer available; subsequent resolves must preserve the first answer, including nil. Removed the five-second fake and 2.5-second elapsed assertion, then shrank the shape exemption.

No test files, recording/data safety checks, privacy/security checks, storage checks, release-integrity checks, or production seams were deleted. No production behavior, branch protection, credentials, releases, or other workers' branches changed. Draft PR #1941's idle-hang work is outside this batch.

## Complete inventory and review depth

| Surface | Baseline inventory | Execution / full details |
| --- | --- | --- |
| Fast app utilities and policies | 243 root files; 2,461 lexical suite calls; 9,767 lexical assertions | `bash run-tests.sh`; [inventory and findings](fast.md) |
| Core audio/pipeline/speaker/storage/utilities | 135 Swift files, including two helpers; 1,637 XCTest methods in five targets | `swift test`; [inventory and findings](core.md) |
| Writing Core and runtime/keyboard | 95 Swift files, including one fixture-only file; 944 Swift Testing declarations | `swift test`; [inventory and findings](writing.md) |
| CaptureKit/CLI/MCP/QA/Lab | 47 Swift files, including one helper; 549 test function declarations | Separate package runners; [inventory and findings](tools-ci.md) |
| Scripts, integration, E2E, packaging, concurrency, CI | 17 standalone Python suites / 330 methods; 40 script self-test entries; four BuildDependencies shell suites; six Integration Swift files; two E2E Swift files; seven workflows | [Exact files, routing, retained checks and limits](tools-ci.md) |

These are different counting units. Parameterized tests, loops, compile guards, optional models, hardware gates, and skips change executed totals. The audit inventoried the complete test surface and screened routing and cross-cutting patterns. Deep semantic review covered the prioritized candidates and their owners, callers, overlaps, and history. It does **not** certify every assertion in the repository or measure line coverage. Full per-file inventories accompany the findings; raw suite-label extraction is supplementary local audit evidence.

The baseline shape guard records 494 source-text read uses in 57 files and seven clock assertions in five files. The edited tree removes one recorded clock assertion; the Core elapsed assertion was not detected by that heuristic. The pin checker resolves 1,272 source pins over 91 targets, with 25 unresolved assertions and 49 slice-negatives it cannot check. Passing that scanner proves matching fragments, not runtime behavior.

## Prioritized follow-ups

Each linked lane report records exact tests/locations, actual detectable failure, non-test callers, stronger or missing boundary proof, history, risk, and focused commands. These remain intact in this PR.

| Priority | Finding / consequence | Next coherent batch |
| --- | --- | --- |
| P1 addressed | Cancellation collapses the old ignored-sleep fake; CI reported intermittent timeout-test failures. Personal lookup and capture cancellation measure scheduler speed. | Held-work and event-order proof in this PR. |
| P1 | `testDictationStoppedAudioRecoveryRetryRegistry` is never called by filename discovery. Its repeated getter does not exercise failed retry. | Route it through the canonical entry; test independent IDs, overwrite/removal, and actual registry ownership. [Evidence](fast.md#f1--p1-a-stopped-audio-registry-test-is-defined-but-never-runs) |
| P1 | Observer-rebind and stopped-audio finalizer fakes implement the actions they claim to prove. Real controller wiring could break while counters pass. | Move proof to a real executor/notification/delivery boundary; retain token and safety checks until replaced. [Evidence](fast.md) |
| P1 | The real-Core Home deletion-reservation smoke is manual and absent from integration/CI routing. | Wire existing byte-preserving delete/Undo reservation proof after Core build. [Evidence](tools-ci.md) |
| P2 | Mandatory synthetic SQLite query/open failures can become skips; a present-but-broken optional model load can also skip. | Fail required fixture/schema setup and present-model failures; retain legitimate absent-model skips. [Core](core.md), [MCP](tools-ci.md) |
| P2 | Remaining polling, sleeps, elapsed guards and MCP contention readiness assumptions leave scheduler races or false greens. | Await real completion/contended-boundary signals; preserve ownership, cancellation, clipboard and read responsiveness outcomes. [Fast](fast.md), [Core](core.md), [MCP](tools-ci.md) |
| P2 | Tools-routing checker accepts a comment as CI proof; strict concurrency census is in local full checks but absent from CI. | Add runnable-command negative controls and route the existing ratchet; do not loosen baselines. [Evidence](tools-ci.md) |
| P2 | Writing stream-cut reference output is derived using the same production helpers. | Independent literal output fixtures at the engine boundary in a separate batch. [Evidence](writing.md) |

Retained apparent false positives include synced path-safety copies, protocol/config/prompt bytes, real packaging artifact contracts, off-device sanitizer allowlists, migration/collision/retention safety, real lock ordering, and release cross-file integrity. Nine historical release-prep failures reflect legitimate integrity checks conflicting with an intentional candidate sequence; this audit does not remove them. Prior corrected wording, phrase-merging, and appcast fixture failures are historical evidence, not new deletion targets. The unexplained SpeakerClipPlayback failure remains a follow-up requiring reproduction.

## Authoring gates and failure controls

The owner boundary, credible regression, distinct coverage, and absence of new production seams are established in the lane reports and [independent review](review.md). Shared timeout helpers serve meeting readiness/transcription and persistent-input startup; the capture attempt owns cancellation versus blocked backend startup; the Writing race has distinct terminal and streaming waiters.

Controlled source mutations are temporary and restored before final proof. Constants controls compile the actual changed test file and real owner with the existing assertion/gate helpers in a focused adapter; package controls run the actual XCTest/Swift Testing filter.

| Control | Original tests | Improved tests |
| --- | --- | --- |
| Omit cancellation of detached operation | Passed | Fails observed cancellation |
| Replace operation errors with `CancellationError` | Passed | Fails error preservation |
| Make detached timeout join held operation | Not used as baseline proof | Fails return-before-release |
| Throw cancellation without invoking operation | Not used as baseline proof | Fails escape/cancellation, finishes instead of hanging |
| Overwrite first personal answer | Missing contract | Fails value and nil first-answer cases |
| Persist timeout as shared provider result | Missing contract | Fails later answer delivery |
| Hold capture lifecycle lock across backend start | Existing speed check was coupled | Fails cancellation-before-release and cancelled-start result |

The CI audit supplied actual flaky-test evidence on unchanged product code (main run `36654516592`, mixed failure run `36638218723`, personal lookup `36287238036`, `36263512902`, `36238817239`). The initial local unmodified constants suite passed 41 assertions; these changes repair unreliable proof and add mutation-sensitive contracts, not a claim of a newly fixed production bug.

## Validation and limits

Coordinator validation commands: focused constants and package filters; `bash check.sh quick`; `bash check.sh full --keep-going`; `bash check.sh`; `bash scripts/ops/transcripted-qa-bench.sh --mode full` with an isolated empty capture container; `git diff --check`; independent final diff review. Actual outcomes and exact-head CI are recorded in the draft PR and task closeout, not inferred from inventory or a historical green run.

The personal lookup test proves timeout outcome and provider independence, not the configured 250 ms wall-clock budget. The capture fake proves the real attempt's lock/ordering contract, not native ScreenCaptureKit/CoreAudio/Bluetooth behavior. First-answer tests prove serialized result retention, not every concurrent multiwaiter interleaving. Artifact smoke checks parser/validator output; synthetic reliability checks do not prove actual transcription accuracy. Opt-in live mic, system audio, paste-back/AX/IMKit, native screen capture, model-backed evaluations, private corpus, packaged signing/notarization, and real update delivery remain separate proof. No live audio or private recordings were used.
