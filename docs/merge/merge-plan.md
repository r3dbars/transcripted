# Draft + Transcripted Merge Plan (Phase 0 Deliverable)

**Authors:** draft-mapper (owner), transcripted-mapper (contributor)
**Status:** v2 for human review — end of Phase 0. Phase 2 execution starts only after human sign-off.
**Inputs:** [draft-inventory.md](draft-inventory.md), [transcripted-inventory.md](transcripted-inventory.md)
**Worktree:** `/Users/redbars/redbars/code/Draft/.claude/worktrees/transcripted-merge` on `feat/transcripted-merge`

**v2 changes (since v1 / commit `95b0bde`):**

- **§2.2, §2.3 corrected** — Draft's SPM sidecar lives in `build-deps.sh` as a regenerated heredoc (`.deps-build/Package.swift` is recreated on every run). The TranscriptedCore dependency must be added to the heredoc inside `build-deps.sh`, not to a standalone file. v1 described editing the generated file directly; those edits would be wiped on the next `build-deps.sh --force`.
- **§3.2 STT seam corrected** — v1 implied `STTRouter` already exposes a pure-samples transcription entry point. Fact-check: `STTRouter.swift` (47 lines) forwards 5 `@Published` props from `ParakeetEngine` and exposes `startRecording()/stopRecording()/transcribe()/cancel()` — all tied to the recording lifecycle. There is NO `transcribeSegment(samples:source:)` method today. v2 fix: Phase 2 core-extractor lane adds a new `ParakeetEngine.transcribeSamples(_:source:) async throws -> String` that bypasses recording, and `SpeechToTextEngine` is satisfied by a thin adapter — not by `STTRouter` conformance.
- **§4.1 + §6.2 FluidAudio version resolved** — Transcripted's committed `libFluidAudioAll.a` is unversioned (no `Package.resolved`, no commit trail). It is not a version mismatch with Draft's 0.7.9 — it is unknown provenance. v2 recommendation: rebuild Transcripted from SPM `FluidAudio 0.7.9` as a Phase 2 prerequisite and delete the committed 54 MB binary + modules. This removes §6.2 as a blocker.
- **§4.5 model bundling expanded** — Added PyAnnote speaker-diarization CoreML models to the bundling plan alongside Parakeet TDT V3 and EOU. Transcripted downloads these via `ModelDownloadService` on first launch (~700 MB total for all diarization + speaker-embedding models); Draft's `build.sh` needs to either bundle them (like Parakeet today) or reuse `ModelDownloadService`.
- **§5 lane reordering** — Added a new **Phase 2.0 prerequisite: FluidAudio rebuild** (fold into Lane D build-plumbing, must complete before Lane A core-extractor starts). This removes the unversioned-binary uncertainty before extraction touches any Core file.
- **§6.1 macOS 26 audit** — Partial resolution noted: transcripted-mapper confirmed the pipeline heavy-lifting code is `nonisolated`, so the `@MainActor` scatter is less load-bearing than the 81 `@available(macOS 26.0, *)` gates. macOS 26 remains the biggest single blocker.
- **§6.4 Protocols wiring** — Explicitly called out as **unresolved, owned by Phase 2 core-extractor lane**. AppServices has a TODO for wiring the 6 Services/Protocols/ protocols; core-extractor is ~100–150 LOC of mechanical glue and must happen before Lane B draft-integrator can use the Core library.
- **§0 zero LLM overlap confirmed** — transcripted-mapper confirmed Transcripted has zero LLM calls in the entire codebase. Draft's Gemini 3 Flash REST/SSE and MLX (Qwen 3.5-4B-4bit) paths are therefore purely additive with no drafting overlap to resolve.
- **§0 side benefit** — Merge also removes a 54 MB unversioned binary from the Transcripted git history (FluidAudio rebuild lane).

All paths below are absolute unless otherwise noted. File path format: `<repo-root>/<relative>` where repo roots are `~/redbars/code/Draft/` and `~/redbars/code/Transcripted/`.

---

## 0. Executive Summary

**Goal:** give Draft access to Transcripted's meeting-transcription pipeline (dual-stream capture, Parakeet STT on long audio, PyAnnote speaker diarization, persistent speaker DB, markdown/YAML transcript output) without duplicating ~13.5k LOC and without breaking Transcripted's shipping app.

**Shape of the merge:**

1. **Extract `Sources/TranscriptedCore/` inside the Transcripted repo** as a new SPM library target alongside the existing Xcode app target. Transcripted's app delegate keeps using it via `@testable` style imports; nothing ships-breaking for Transcripted.
2. **Draft adopts `Package.swift`** (a first for Draft — see §2) and depends on TranscriptedCore via **local path** pointing at `~/redbars/code/Transcripted/`. Draft's existing `swiftc`-driven `build.sh` remains, but calls `swift build` as a pre-step to produce the Core artifact and its module.
3. **FluidAudio is consolidated** onto Draft's existing `deps-libs/libDraftDeps.a` unified static library. Transcripted's committed `libFluidAudioAll.a` + `fluidaudio-modules/` are retired in favor of Draft's `build-fluidaudio.sh` output (assuming version alignment per Open Question §6.2).
4. **Draft's `Sources/Speech/` stays** — its ParakeetEngine is optimized for short dictation (≤30s) and fast overlay streaming, which is a different use case from Transcripted's long-audio `ParakeetService`. Both can coexist in the same binary linking one FluidAudio.
5. **Transcripted's audio capture stack is the authoritative source** for Draft's new meeting mode. Draft has no dual-stream capture today.
6. **Four execution lanes** (§5) split the Phase 2 work so two pairs of agents can run in parallel without file-level collisions: `core-extractor`, `draft-integrator`, `meeting-ui`, and `build-plumbing`.

**Single biggest risk:** the macOS deployment-target mismatch. Draft ships `arm64-apple-macos14.0` (per `build.sh:105` and `Info.plist:18`); Transcripted's Core candidate files carry 81 `@available(macOS 26.0, *)` gates across 58 files. Phase 2's first milestone is the macOS-26 audit; §6.1 is the gating Open Question for the human.

---

## 1. TranscriptedCore Extraction Strategy

### 1.1 Target shape

Create a new SPM library target `TranscriptedCore` inside `~/redbars/code/Transcripted/`, coexisting with the existing `Transcripted.xcodeproj`:

```
~/redbars/code/Transcripted/
├── Transcripted.xcodeproj/          # existing app target — unchanged
├── Transcripted/                    # existing app sources — most files stay
├── Package.swift                    # NEW — declares TranscriptedCore library
├── Sources/
│   └── TranscriptedCore/            # NEW — symlinks or moves of extracted files
├── Tests/
│   └── TranscriptedCoreTests/       # NEW — Core-level tests migrated from TranscriptedTests/
└── fluidaudio-libs/, fluidaudio-modules/   # existing — see Build system §4
```

`Package.swift` targets (see §4.2 for full declaration):
- `TranscriptedCore` (library, `@available(macOS 14.2, *)` after the availability audit — see §6.1)
- `TranscriptedCoreTests` (test target)

**Two mechanical choices for "where do the files live physically":**

- **Option A — move**: relocate files from `Transcripted/Core/` and `Transcripted/Services/` into `Sources/TranscriptedCore/`. Update the Xcode pbxproj to reference the new paths.
- **Option B — symlink**: keep files where they are, create `Sources/TranscriptedCore/` with symlinks into the existing `Transcripted/Core/` + `Transcripted/Services/` trees. SPM follows symlinks. pbxproj untouched.

**Recommendation: Option A (move).** Symlinks work but confuse git blame, grep, and any downstream tools. The mechanical cost of updating pbxproj is a one-time checkbox in Xcode or a one-pass `pbxproj` edit. See lane `core-extractor` in §5.

### 1.2 File list — what moves into `Sources/TranscriptedCore/`

Derived directly from transcripted-inventory.md §3 tiers. Paths on the left are current locations inside `~/redbars/code/Transcripted/Transcripted/`; paths on the right are the final `Sources/TranscriptedCore/<subdir>/<file>` destinations.

#### 1.2.1 Tier A — zero-surgery moves (24 files)

No changes to these files other than (a) adding `public` to types/methods Draft calls and (b) dropping any `Bundle.main` / hard-coded paths if reached by Tier B dependencies.

| Current path | Final path |
|---|---|
| `Core/TranscriptionTypes.swift` | `Sources/TranscriptedCore/Models/TranscriptionTypes.swift` |
| `Core/DisplayStatus.swift` | `Sources/TranscriptedCore/Models/DisplayStatus.swift` |
| `Core/TranscriptMetadataBuilder.swift` | `Sources/TranscriptedCore/Models/TranscriptMetadataBuilder.swift` |
| `Core/FailedTranscription.swift` | `Sources/TranscriptedCore/Models/FailedTranscription.swift` |
| `Core/FilePermissions.swift` | `Sources/TranscriptedCore/Utilities/FilePermissions.swift` |
| `Core/DateFormattingHelper.swift` | `Sources/TranscriptedCore/Utilities/DateFormattingHelper.swift` |
| `Core/DateParser.swift` | `Sources/TranscriptedCore/Utilities/DateParser.swift` |
| `Core/TranscriptUtils.swift` | `Sources/TranscriptedCore/Utilities/TranscriptUtils.swift` |
| `Core/Logging/AppLogger.swift` | `Sources/TranscriptedCore/Logging/AppLogger.swift` |
| `Core/Logging/FileLogger.swift` | `Sources/TranscriptedCore/Logging/FileLogger.swift` |
| `Services/ModelDownloadService.swift` | `Sources/TranscriptedCore/Services/ModelDownloadService.swift` |
| `Services/RecordingValidator.swift` | `Sources/TranscriptedCore/Services/RecordingValidator.swift` |
| `Core/SpeakerProfile.swift` | `Sources/TranscriptedCore/Speaker/SpeakerProfile.swift` |
| `Services/AudioResampler.swift` | `Sources/TranscriptedCore/Audio/AudioResampler.swift` |
| `Services/EmbeddingClusterer.swift` | `Sources/TranscriptedCore/Speaker/EmbeddingClusterer.swift` |
| `Services/SpeakerClipExtractor.swift` | `Sources/TranscriptedCore/Speaker/SpeakerClipExtractor.swift` |
| `Services/SpeakerEmbeddingMatcher.swift` | `Sources/TranscriptedCore/Speaker/SpeakerEmbeddingMatcher.swift` |
| `Services/SpeakerProfileMerger.swift` | `Sources/TranscriptedCore/Speaker/SpeakerProfileMerger.swift` |
| `Services/Protocols/SpeechToTextEngine.swift` | `Sources/TranscriptedCore/Protocols/SpeechToTextEngine.swift` |
| `Services/Protocols/DiarizationEngine.swift` | `Sources/TranscriptedCore/Protocols/DiarizationEngine.swift` |
| `Services/Protocols/SpeakerStore.swift` | `Sources/TranscriptedCore/Protocols/SpeakerStore.swift` |
| `Services/Protocols/StatsStore.swift` | `Sources/TranscriptedCore/Protocols/StatsStore.swift` |
| `Services/Protocols/TranscriptStorage.swift` | `Sources/TranscriptedCore/Protocols/TranscriptStorage.swift` |
| `Services/Protocols/AudioCaptureEngine.swift` | `Sources/TranscriptedCore/Protocols/AudioCaptureEngine.swift` |

#### 1.2.2 Tier B — minor surgery (20 files)

Each needs one of four fixes: (i) visibility, (ii) `Bundle.main` parameterization (§11.1), (iii) `UserNotifications` protocol split (§11.2), (iv) storage path parameterization (§11.3). The surgery is catalogued in §1.4.

| Current path | Final path | Surgery |
|---|---|---|
| `Services/AppServices.swift` | `Sources/TranscriptedCore/Services/AppServices.swift` | switch stored props to `any Protocol` types (per file's own TODO) |
| `Core/Transcription.swift` | `Sources/TranscriptedCore/Pipeline/Transcription.swift` | public init, `CoreStoragePaths` injection |
| `Core/TranscriptionPipeline.swift` | `Sources/TranscriptedCore/Pipeline/TranscriptionPipeline.swift` | public entry points |
| `Core/TranscriptionPipelineRunner.swift` | `Sources/TranscriptedCore/Pipeline/TranscriptionPipelineRunner.swift` | drop unused `UserNotifications` import |
| `Core/TranscriptionTaskManager.swift` | `Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift` | `TranscriptNotifier` protocol replaces direct UN calls |
| `Core/SpeakerNamingCoordinator.swift` | `Sources/TranscriptedCore/Speaker/SpeakerNamingCoordinator.swift` | public types |
| `Core/SpeakerMatchingService.swift` | `Sources/TranscriptedCore/Speaker/SpeakerMatchingService.swift` | public types |
| `Core/RetroactiveSpeakerUpdater.swift` | `Sources/TranscriptedCore/Speaker/RetroactiveSpeakerUpdater.swift` | `CoreStoragePaths` injection (scans save dir) |
| `Core/TranscriptSaver.swift` | `Sources/TranscriptedCore/Storage/TranscriptSaver.swift` | `TranscriptNotifier` protocol + `CoreStoragePaths` |
| `Core/TranscriptFormatter.swift` | `Sources/TranscriptedCore/Storage/TranscriptFormatter.swift` | public formatting methods |
| `Core/TranscriptScanner.swift` | `Sources/TranscriptedCore/Storage/TranscriptScanner.swift` | `CoreStoragePaths` injection |
| `Core/AgentOutput.swift` | `Sources/TranscriptedCore/Storage/AgentOutput.swift` | public static methods |
| `Core/StatsDatabase.swift` | `Sources/TranscriptedCore/Stats/StatsDatabase.swift` | `CoreStoragePaths` injection, `public init(path:)` |
| `Core/StatsDatabaseModels.swift` | `Sources/TranscriptedCore/Stats/StatsDatabaseModels.swift` | public types |
| `Core/StatsDatabaseQueries.swift` | `Sources/TranscriptedCore/Stats/StatsDatabaseQueries.swift` | public queries |
| `Services/StatsService.swift` | `Sources/TranscriptedCore/Stats/StatsService.swift` | public `.shared`, keep `@MainActor` |
| `Services/FailedTranscriptionManager.swift` | `Sources/TranscriptedCore/Services/FailedTranscriptionManager.swift` | `CoreStoragePaths` injection |
| `Services/ParakeetService.swift` | `Sources/TranscriptedCore/Services/ParakeetService.swift` | **`Bundle.main.resourcePath` → `bundleProvider` closure injection (§11.1)** |
| `Services/DiarizationService.swift` | `Sources/TranscriptedCore/Services/DiarizationService.swift` | **same `bundleProvider` fix** |
| `Services/SpeakerDatabase.swift` | `Sources/TranscriptedCore/Speaker/SpeakerDatabase.swift` | `CoreStoragePaths` injection, public `init(path:)` |

#### 1.2.3 Tier C — audio capture stack (8 files, ~2,000 LOC)

Moves conditionally based on §6.3 decision (whether Draft reuses Transcripted's capture). All 8 files import `AppKit` (for sleep/wake notifications + `NSSound`), so they stay macOS-only. **None are `@MainActor`**, which is good for Draft's audio thread design.

| Current path | Final path |
|---|---|
| `Core/Audio.swift` (618 LOC) | `Sources/TranscriptedCore/Audio/Audio.swift` |
| `Core/AudioFileManager.swift` | `Sources/TranscriptedCore/Audio/AudioFileManager.swift` |
| `Core/AudioDeviceRecovery.swift` | `Sources/TranscriptedCore/Audio/AudioDeviceRecovery.swift` |
| `Core/AudioLevelMonitor.swift` | `Sources/TranscriptedCore/Audio/AudioLevelMonitor.swift` |
| `Core/SystemAudioCapture.swift` | `Sources/TranscriptedCore/Audio/SystemAudioCapture.swift` |
| `Core/SystemAudioProcessTap.swift` | `Sources/TranscriptedCore/Audio/SystemAudioProcessTap.swift` |
| `Core/SystemAudioBufferWriter.swift` | `Sources/TranscriptedCore/Audio/SystemAudioBufferWriter.swift` |
| `Core/CoreAudioUtils.swift` | `Sources/TranscriptedCore/Audio/CoreAudioUtils.swift` |

### 1.3 Files that MUST stay in the Transcripted app target

**Do NOT move these into Core.** They are UI-coupled or AppDelegate-coupled. The Transcripted app continues to own them; they import `TranscriptedCore` just like Draft will.

- All of `Transcripted/UI/` (36 files) — SwiftUI views, `@StateObject`, `@EnvironmentObject` wiring.
- All of `Transcripted/Design/` (21 files) — design system.
- All of `Transcripted/Onboarding/` (9 files) — onboarding flow.
- `Transcripted/Core/MeetingDetector.swift` — Tier D per inventory; application-mode logic, not reusable.
- `Transcripted/Core/TranscriptStore.swift` + `TranscriptExporter.swift` — Tier D; app-local file navigation.
- `Transcripted/Core/Clipboard.swift` + `SystemSettingsHelper.swift` + `DiagnosticExporter.swift` — Tier D; app-level UX.
- All AppDelegate extensions (`NotificationCoordinator.swift`, window-controller glue, etc.).
- `TranscriptedTests/UI/` — XCTest UI tests stay with the app target.

### 1.4 Visibility changes (internal → public) — complete list

Per transcripted-inventory.md §10. All types below are currently `internal` (Transcripted has zero `public` declarations today, confirmed by inventory grep). Each becomes `public` in the extracted Core target.

**Pipeline (14 types)** — `Transcription`, `TranscriptionTaskManager`, `TranscriptionUtterance`, `TranscriptionResult`, `TranscriptionMetadata`, `PipelineError`, `SpeakerConfidence`, `IdentifiedSpeaker`, `SpeakerNamingRequest`, `SpeakerNamingEntry`, `SpeakerNameUpdate` (+ nested `NamingAction`), `SpeakerMapping`, `DisplayStatus`, `TranscriptionTask`, `RecordingHealthInfo` (+ `CaptureQuality` enum), `FailedTranscription`.

**Speaker (7 types)** — `SpeakerSegment`, `SpeakerProfile`, `SpeakerMatchResult`, `NameSource`, `SpeakerDatabase` (+ `.shared`, `init(path:)`), all 12 `SpeakerStore`-protocol methods, `EmbeddingClusterer.postProcess(...)`.

**Services (10 types)** — `ParakeetService` (+ all methods + `ParakeetModelState`), `DiarizationService` (+ all methods + `DiarizationModelState`), `AudioResampler` static methods, `ModelDownloadService` static methods, `DownloadErrorKind`, `ModelDownloadError`.

**Storage (6 types)** — `TranscriptSaver` (+ all static methods), `TranscriptFormatter.formatTranscriptMarkdown(...)`, `AgentOutput` static methods, `StatsDatabase`, `StatsService` (+ `.shared` + `@Published`), `FailedTranscriptionManager`, `RecordingMetadata`, `DailyActivity`.

**Protocols (6 files)** — all of `Services/Protocols/*.swift`. **Blocked on the Protocols wiring question — see Open Question §6.4.** If Transcripted pre-wires concrete conformances (which `AppServices.swift` TODO promises), Draft can inject alternate implementations cleanly. If not, Phase 2 core-extractor lane does the wiring.

**Logging** — `AppLogger` + `SubsystemLogger`.

**DI container** — `AppServices` + `.makeDefault()` + stored props (switched to `any <Protocol>` types per the file's own TODO).

**Count: ~44 top-level types + dozens of methods.** Mechanical pass, one per file. Estimated ~2–3 hours of rote surgery for one agent.

### 1.5 Surgery needed beyond visibility (the parts that will slow Phase 1 down)

Ordered by blast radius; complete detail in transcripted-inventory.md §11.

1. **`Bundle.main.resourcePath` lookups** (`ParakeetService.swift:71`, `DiarizationService.swift:145`). Introduce `public typealias ModelBundleProvider = () -> URL?`; pass at init. Default to `{ Bundle.main.resourcePath.map(URL.init(fileURLWithPath:)) }`. ~30 LOC per file. **This is the single most important API-shape decision — it leaks into Draft's initialization path.**

2. **`UserNotifications` framework coupling** (`TranscriptionTaskManager.swift`, `TranscriptSaver.swift`). Define `public protocol TranscriptNotifier { func notifySaved(fileURL: URL); func notifyFailure(message: String); func requestPermission() async -> Bool }`. Core types hold `TranscriptNotifier?` (default nil → no-op). Draft supplies a UN-backed adapter if it wants notifications, or passes nil. **~50 LOC total.** Drops the `import UserNotifications` from Core entirely — important for future cross-platform reuse.

3. **Hard-coded `~/Documents/Transcripted/` paths.** Define `public struct CoreStoragePaths { let transcripts: URL; let speakerDB: URL; let statsDB: URL; let failedQueue: URL; let speakerClips: URL; let logs: URL; public static let `default`: CoreStoragePaths = ... }`. Every service takes a `CoreStoragePaths` at init. **~15 touch points.** Draft passes a `CoreStoragePaths` rooted at `~/Library/Application Support/Draft/meetings/` instead of `~/Documents/Transcripted/`.

4. **`@available(macOS 26.0, *)` audit — the blocker.** 81 occurrences across 58 files. Draft's deployment target is macOS 14.0. **Phase 2 milestone 0 is: for each Core candidate file, determine which `macOS 26.0` gates are load-bearing (API actually requires 26) vs conservative (chosen for UX reasons).** Expected outcome: the Services tier (ParakeetService, DiarizationService, SpeakerDatabase, most storage) is already gated at `@available(macOS 14.0, *)`, so the load-bearing 26-gates are concentrated in the audio capture stack (Tier C) where CoreAudio process tap APIs are macOS 14.2+ and some concurrency APIs may have been tightened at 26. See Open Question §6.1 — **this is the single most important answer the human needs to give before Phase 2 starts.**

5. **FluidAudio unsafe-flags linking.** Covered in §4 — this is the single biggest build-system decision.

6. **`@MainActor` + `ObservableObject` on Core classes.** `Transcription`, `TranscriptionTaskManager`, `ParakeetService`, `DiarizationService`, `FailedTranscriptionManager`, `StatsService` are all `@MainActor ObservableObject`. Draft is also macOS + Combine, so **leave as-is for v1**. If we later want headless/CLI reuse we can add parallel `AsyncStream` APIs.

### 1.6 Breaking-change risks to the Transcripted app

- **pbxproj path updates (Option A in §1.1)** — the moved files need their Xcode group references updated. Any uncommitted local work referencing old paths in Xcode groups breaks. Mitigation: core-extractor lane does the move as a single atomic commit with a verification `xcodebuild -list` pass.
- **Visibility cascades** — when `SpeakerDatabase` becomes `public`, its internal helper types (e.g., `SpeakerMatchResult`, `NameSource`, even `struct SpeakerDatabase.Column`) must also become `public` or the public API won't compile. Each public declaration triggers an audit of its signature. Catalogued in §1.4 but the long tail may add ~10 more types.
- **`AppServices` switch to protocol types** — already a TODO in the file, so the Transcripted team wants this. But it's still a cross-file change: every `AppServices.parakeet` call site becomes `AppServices.parakeet` of type `any SpeechToTextEngine`, which means call sites either cast or use only protocol methods. If call sites rely on `ParakeetService`-specific APIs (e.g., `@Published` properties bound in SwiftUI), those stay on the concrete type and the protocol wrapper doesn't help. **Risk: we discover Transcripted UI reaches into concrete types, and protocol wiring isn't as clean as the TODO implies.** Mitigation: §6.4 open question + a spike at the start of Phase 2.
- **Xcode test host coupling** — `TranscriptedTests/` uses `@testable import Transcripted`. After extraction, Core-level tests should switch to `@testable import TranscriptedCore` and drop the host-app dependency. UI tests stay on the host. Mitigation: `core-extractor` lane moves ~40 of the 47 test files; `meeting-ui` lane leaves the rest in place. Neither is a blocker.
- **Singletons race with Draft** — `SpeakerDatabase.shared`, `StatsService.shared`, `AppLogger.shared`. If Draft's Core instances and Transcripted app's own Core instances ever run in the same process (impossible today — they're separate binaries), they'd race on SQLite files. They don't run in the same process, so this is fine. But on the same **machine**, both apps writing to `~/Documents/Transcripted/...` would silently share state. The `CoreStoragePaths` fix (§1.5.3) gives Draft its own location; human decides in §6.5 whether to unify or isolate.

---

## 2. Draft `Package.swift` Integration

**Context:** Draft has no `Package.swift` today. It's built with raw `swiftc` against `$(find Sources -name '*.swift')` in `build.sh:103`. Dependencies (FluidAudio + mlx-swift-lm + MLX) are baked into `deps-libs/libDraftDeps.a` via a throw-away SPM workspace in `.deps-build/Package.swift`. **Introducing a `Package.swift` at the Draft root is itself a non-trivial restructure**, which is why we keep `build.sh` as the authoritative build driver and treat SPM as a dependency-fetch mechanism only.

### 2.1 Two candidate integration shapes

- **Shape X — Add root `Package.swift`, migrate `build.sh` to `swift build`.** The "correct" SPM approach. Requires reworking Draft's entire build pipeline, resource-bundling logic, entitlements signing, and the `deps-libs` pattern into SPM idioms (`.binaryTarget`, `.copy`, etc.). **Estimated: 2–3 days of pure build work with no feature payoff.** We reject this for Phase 2 scope.

- **Shape Y — Minimal `Package.swift` at Draft root, `build.sh` stays authoritative.** `Package.swift` declares a single library target that just lists Draft's Sources + a dependency on TranscriptedCore. We never `swift build` Draft's app — `build.sh` keeps doing `swiftc` compilation. BUT `build.sh` gains one new step: before the `swiftc` invocation, it runs `swift build -c release --target TranscriptedCore` (triggered from a sidecar `Package.swift` inside `.deps-build/` — same pattern as `build-deps.sh`), then links the resulting `.a` and `.swiftmodule` into the final `swiftc` command via additional `-I` / `-L` flags. **This is the minimum-viable integration.** We recommend Shape Y.

### 2.2 Recommended: Shape Y — sidecar `Package.swift` pattern (regenerated from `build-deps.sh` heredoc)

**Important v2 correction:** Draft's `.deps-build/Package.swift` is **not a standalone file** — it is regenerated via heredoc by `build-deps.sh` on every run (`rm -rf "$DEPS_BUILD"` on line 27, followed by a `cat > "$DEPS_BUILD/Package.swift" <<'EOF' ... EOF` block). Manual edits to `.deps-build/Package.swift` are wiped on the next `bash build-deps.sh --force`. The correct intervention point is the heredoc **inside `build-deps.sh`**.

**Edit: `~/redbars/code/Draft/build-deps.sh` — modify the heredoc that generates `.deps-build/Package.swift`**

Inside the existing `cat > "$DEPS_BUILD/Package.swift" <<'EOF' ... EOF` block, add the TranscriptedCore dependency and product:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DraftDeps",
    platforms: [.macOS(.v14)],                       // MUST match Draft's floor
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "25b00d4"),
        .package(path: "../../Transcripted"),        // NEW: local path to the Transcripted repo root
    ],
    targets: [
        .target(
            name: "Shim",
            dependencies: [
                .product(name: "FluidAudio",       package: "FluidAudio"),
                .product(name: "MLXLLM",           package: "mlx-swift-lm"),
                .product(name: "TranscriptedCore", package: "Transcripted"),  // NEW
            ],
            path: "Sources"
        )
    ]
)
```

**Local path vs git URL — our choice and rationale:**

- ✅ **`.package(path: "../../Transcripted")`** (local path, resolved against the `.deps-build/` dir → `~/redbars/code/Transcripted/`).
  - **Why:** Both repos live side-by-side in `~/redbars/code/`. Local path means instant iteration — edit a Core file in Transcripted, rebuild Draft, done. No push/pull loop while Phase 2 lanes are in flight.
  - **Why not git URL pinned to `feat/extract-core`:** would force every Core tweak through a push-and-resolve cycle. Hurts velocity during Phase 2. Also risks partially-merged work being inaccessible to one side or the other.
- 🔁 **Promote to git URL later** — once the merge stabilizes (Phase 3+), switch to `.package(url: "https://github.com/r3dbars/Transcripted.git", branch: "main")` so CI builds of Draft can run without a co-checked-out Transcripted repo. That's a 1-line future change.

**Why this matters for Phase 2:** Lane D (`build-plumbing`) must edit `build-deps.sh` itself, NOT touch `.deps-build/Package.swift` directly. Any reviewer who opens `.deps-build/Package.swift` will see the regenerated file and must trace upward to the heredoc in `build-deps.sh`. Document this in the lane brief.

### 2.3 `build.sh` changes

`build-deps.sh` already builds the unified static library `deps-libs/libDraftDeps.a` by compiling the `Shim` target — after adding TranscriptedCore as a dependency of that target, the single `libDraftDeps.a` will transitively embed TranscriptedCore's compiled code, and `deps-modules/` will contain the TranscriptedCore `.swiftmodule` for `import TranscriptedCore` to resolve via `-I deps-modules`.

**Net change to `build.sh` (the app build):** **zero code changes** — the existing `$DEPS_FLAGS` that already point at `deps-libs/libDraftDeps.a` and `deps-modules/` will cover TranscriptedCore after `build-deps.sh` regenerates them. The only operational change is: `bash build-deps.sh --force` must be run once after the v2 heredoc edit to rebuild `libDraftDeps.a` with the Core target included.

Draft source files that want Core do `import TranscriptedCore` at the top. The existing Sources/ tree does not use SPM modules today, so this import is a new convention — but mechanically identical to importing any system framework since `swiftc` sees it via `-I deps-modules`.

### 2.4 New targets required in Draft

**None in a `Package.swift` sense.** Draft remains a single binary. The new capabilities live in new files inside existing subdirectories:

- `Sources/Meeting/` — NEW directory, Phase 2 lane `meeting-ui`. Contains the bridge between Draft's existing hotkey/session controllers and `TranscriptedCore`'s `TranscriptionTaskManager`. Owner: `meeting-ui` lane (see §5.3).
- `Sources/Speech/ParakeetLongEngine.swift` — optional wrapper around `TranscriptedCore.ParakeetService` if Draft wants a long-audio transcription path alongside its existing short-dictation `ParakeetEngine`. See §3.3 for the coexistence decision.

### 2.5 Swift version / macOS deployment target

- **Swift tools version:** 5.9 in the sidecar `Package.swift` (matches Draft's existing `.deps-build/Package.swift` and Transcripted's Tools packages). Both repos compile with the same Xcode 15 / Swift 5.9+ toolchain today.
- **Deployment target:** `platforms: [.macOS(.v14)]` in the sidecar. **This must match Draft's `-target arm64-apple-macos14.0` in `build.sh:105`.** If TranscriptedCore declares `.macOS(.v14.2)` — which is the likely outcome of the §6.1 availability audit — SPM still accepts it from a package that declares `.macOS(.v14)`; the Core target's own `@available(macOS 14.2, *)` gates constrain callers at the language level. **Draft's app still ships with `LSMinimumSystemVersion 14.0`** (`Info.plist:18`) and meeting features refuse to initialize on 14.0–14.1 via `if #available(macOS 14.2, *)` guards in Draft's `Meeting/` bridge. Users on macOS 14.0 see the app run fine but without the meeting hotkey.

### 2.6 Swift 6 strict concurrency

Draft compiles under Swift 5 concurrency today (release builds, `-O`, no `-strict-concurrency=complete`). Transcripted is Swift 6 / strict concurrency per transcripted-inventory.md. TranscriptedCore imported into Draft's build will Just Work because Swift 6 modules are forward-compatible with Swift 5 consumers; any `Sendable` warnings stay inside Core. **No change to Draft's source files required.**

---

## 3. Directory Merge Map

### 3.1 File-by-file mapping table

Complete mapping — Transcripted source → final TranscriptedCore path → Draft consumer (`import TranscriptedCore` + usage site).

| Transcripted file | TranscriptedCore path | Draft consumer (import site) |
|---|---|---|
| `Core/Transcription.swift` | `Pipeline/Transcription.swift` | `Sources/Meeting/MeetingSessionController.swift` (NEW) |
| `Core/TranscriptionTaskManager.swift` | `Pipeline/TranscriptionTaskManager.swift` | `Sources/Meeting/MeetingSessionController.swift` |
| `Core/TranscriptionPipeline.swift` | `Pipeline/TranscriptionPipeline.swift` | (internal to Core, Draft doesn't import directly) |
| `Core/TranscriptionPipelineRunner.swift` | `Pipeline/TranscriptionPipelineRunner.swift` | (internal to Core) |
| `Core/TranscriptionTypes.swift` | `Models/TranscriptionTypes.swift` | `Sources/Meeting/*`, `Sources/UI/MeetingOverlayController.swift` (NEW) |
| `Core/DisplayStatus.swift` | `Models/DisplayStatus.swift` | `Sources/UI/MeetingOverlayController.swift` |
| `Core/FailedTranscription.swift` | `Models/FailedTranscription.swift` | `Sources/Meeting/FailedMeetingQueue.swift` (NEW, optional) |
| `Core/TranscriptMetadataBuilder.swift` | `Models/TranscriptMetadataBuilder.swift` | `Sources/Meeting/MeetingSessionController.swift` |
| `Core/Audio.swift` | `Audio/Audio.swift` | `Sources/Meeting/MeetingCaptureBridge.swift` (NEW) |
| `Core/SystemAudioCapture.swift` | `Audio/SystemAudioCapture.swift` | `Sources/Meeting/MeetingCaptureBridge.swift` |
| `Core/SystemAudioProcessTap.swift` | `Audio/SystemAudioProcessTap.swift` | (internal) |
| `Core/SystemAudioBufferWriter.swift` | `Audio/SystemAudioBufferWriter.swift` | (internal) |
| `Core/AudioFileManager.swift` | `Audio/AudioFileManager.swift` | (internal) |
| `Core/AudioDeviceRecovery.swift` | `Audio/AudioDeviceRecovery.swift` | (internal) |
| `Core/AudioLevelMonitor.swift` | `Audio/AudioLevelMonitor.swift` | `Sources/UI/MeetingOverlayController.swift` (levels viz) |
| `Core/CoreAudioUtils.swift` | `Audio/CoreAudioUtils.swift` | (internal) |
| `Services/AudioResampler.swift` | `Audio/AudioResampler.swift` | **collides with Draft's `Sources/Speech/AudioResampler.swift` — see §3.2** |
| `Services/ParakeetService.swift` | `Services/ParakeetService.swift` | `Sources/Meeting/MeetingSessionController.swift` |
| `Services/DiarizationService.swift` | `Services/DiarizationService.swift` | `Sources/Meeting/MeetingSessionController.swift` |
| `Services/ModelDownloadService.swift` | `Services/ModelDownloadService.swift` | `Sources/Meeting/MeetingModelDownloader.swift` (NEW) |
| `Services/RecordingValidator.swift` | `Services/RecordingValidator.swift` | (internal, used by TranscriptSaver) |
| `Services/FailedTranscriptionManager.swift` | `Services/FailedTranscriptionManager.swift` | `Sources/Meeting/MeetingSessionController.swift` |
| `Services/AppServices.swift` | `Services/AppServices.swift` | Draft does NOT use AppServices; it instantiates Core services directly with its own `CoreStoragePaths`. AppServices stays for Transcripted app's convenience. |
| `Services/StatsService.swift` | `Stats/StatsService.swift` | `Sources/Meeting/MeetingStats.swift` (NEW, optional — shows meeting usage in menubar) |
| `Core/StatsDatabase.swift` | `Stats/StatsDatabase.swift` | (internal to StatsService) |
| `Core/StatsDatabaseModels.swift` | `Stats/StatsDatabaseModels.swift` | (internal) |
| `Core/StatsDatabaseQueries.swift` | `Stats/StatsDatabaseQueries.swift` | (internal) |
| `Core/SpeakerProfile.swift` | `Speaker/SpeakerProfile.swift` | `Sources/Meeting/MeetingSessionController.swift`, potentially `Sources/UI/MenuBarPanel.swift` for speaker review UI |
| `Services/SpeakerDatabase.swift` | `Speaker/SpeakerDatabase.swift` | `Sources/Meeting/MeetingSessionController.swift` (injects Draft's path) |
| `Services/SpeakerEmbeddingMatcher.swift` | `Speaker/SpeakerEmbeddingMatcher.swift` | (internal to Core) |
| `Services/SpeakerProfileMerger.swift` | `Speaker/SpeakerProfileMerger.swift` | (internal) |
| `Services/SpeakerClipExtractor.swift` | `Speaker/SpeakerClipExtractor.swift` | (internal) |
| `Services/EmbeddingClusterer.swift` | `Speaker/EmbeddingClusterer.swift` | (internal) |
| `Core/SpeakerMatchingService.swift` | `Speaker/SpeakerMatchingService.swift` | (internal) |
| `Core/SpeakerNamingCoordinator.swift` | `Speaker/SpeakerNamingCoordinator.swift` | `Sources/UI/SpeakerNamingSheet.swift` (NEW) |
| `Core/RetroactiveSpeakerUpdater.swift` | `Speaker/RetroactiveSpeakerUpdater.swift` | `Sources/UI/SpeakerNamingSheet.swift` (on name confirm) |
| `Core/TranscriptSaver.swift` | `Storage/TranscriptSaver.swift` | `Sources/Meeting/MeetingSessionController.swift` |
| `Core/TranscriptFormatter.swift` | `Storage/TranscriptFormatter.swift` | (internal to TranscriptSaver) |
| `Core/TranscriptScanner.swift` | `Storage/TranscriptScanner.swift` | `Sources/Meeting/MeetingHistoryList.swift` (NEW, optional) |
| `Core/AgentOutput.swift` | `Storage/AgentOutput.swift` | (internal to TranscriptSaver) |
| `Core/DateFormattingHelper.swift` | `Utilities/DateFormattingHelper.swift` | (internal) |
| `Core/DateParser.swift` | `Utilities/DateParser.swift` | (internal) |
| `Core/TranscriptUtils.swift` | `Utilities/TranscriptUtils.swift` | (internal) |
| `Core/FilePermissions.swift` | `Utilities/FilePermissions.swift` | (internal) |
| `Core/Logging/AppLogger.swift` | `Logging/AppLogger.swift` | (Draft keeps its own `Sources/Observability/AppLogger.swift` — see §3.2) |
| `Core/Logging/FileLogger.swift` | `Logging/FileLogger.swift` | (internal) |
| `Services/Protocols/*.swift` (6 files) | `Protocols/*.swift` | `Sources/Meeting/*` (may or may not adopt — see §6.4) |

### 3.2 Overlap conflict resolution — file-by-file

These are the Draft files that overlap Transcripted in functionality or naming. Per-file decision + justification.

#### `Sources/Speech/AudioResampler.swift` vs `TranscriptedCore/Audio/AudioResampler.swift`

- **Decision: KEEP BOTH; rename Draft's to `Sources/Speech/DraftAudioResampler.swift` or fold into Core's.**
- **Preferred: delete Draft's, use Core's.** Draft's resampler is tiny (~80 LOC), converts arbitrary input to 16 kHz mono for Parakeet dictation. Transcripted's is more sophisticated (`Services/AudioResampler.swift`, full `loadAndResample(url:targetRate:)` + `extractSlice(from:sampleRate:startTime:endTime:)`). Draft can adopt the Core version with zero loss of functionality.
- **Owner:** `draft-integrator` lane. Trivial — delete Draft's file, replace import in `Sources/Speech/ParakeetEngine.swift`, add `import TranscriptedCore` if needed.

#### `Sources/Speech/ParakeetEngine.swift` vs `TranscriptedCore/Services/ParakeetService.swift`

**v2 decision: DELETE `ParakeetService.swift` from TranscriptedCore. Add a new method `ParakeetEngine.transcribeSamples(_:source:) async throws -> String` and satisfy Core's `SpeechToTextEngine` protocol with a thin adapter that wraps Draft's `ParakeetEngine`.**

**Why this is different from v1:**

v1 said "keep both" on the assumption that streaming dictation and batch long-audio transcription are two different use cases served by two different `AsrManager` configurations. That's still partly true — but the split goes *inside* one FluidAudio `AsrManager` instance, not across two Swift wrapper types. `ParakeetService.swift` (117 LOC per transcripted-mapper) is a thin, batch-only wrapper around `AsrManager.transcribe(_:source:)`. Draft's `ParakeetEngine` already holds an `AsrManager` instance and can expose the same batch entry point with no duplication.

**Fact-check on the "STTRouter is a strict superset" claim (from transcripted-mapper's reply):**

transcripted-mapper suggested conforming `STTRouter` directly to Core's `SpeechToTextEngine` protocol. I fact-checked by reading `Sources/Speech/STTRouter.swift` (47 lines) and `Sources/Speech/ParakeetEngine.swift` — and **STTRouter does NOT have a pure-samples transcription entry point**. Its public API is:

```swift
// Sources/Speech/STTRouter.swift
func startRecording() -> Bool          // gated on isModelLoaded, starts mic + tap
func stopRecording()                   // stops mic + tap
func transcribe() async -> String?     // batch-transcribes accumulated audio from STTRouter's own buffer
func cancel()
```

All four methods are tied to STTRouter's internal recording lifecycle. There is no `transcribeSegment(samples: [Float], source: AudioSource) async throws -> String` method to match Core's `SpeechToTextEngine.transcribeSegment(samples:source:)` signature (per transcripted-inventory.md §5). STTRouter owns the mic; Core's pipeline owns its own audio capture and only hands Core an already-recorded `[Float]` buffer. Those are incompatible ownership models — conforming STTRouter to the protocol would either re-record audio that Core already captured, or ignore the `samples` parameter and transcribe STTRouter's own buffer instead.

**v2 correct seam:** add a new nonisolated method on `ParakeetEngine` that takes raw samples and bypasses the recording lifecycle:

```swift
// Sources/Speech/ParakeetEngine.swift — NEW method, added by Phase 2 Lane B
extension ParakeetEngine {
    nonisolated func transcribeSamples(_ samples: [Float], source: AudioSource) async throws -> String {
        guard let manager = asrManager else { throw STTError.modelNotLoaded }
        // samples assumed 16kHz mono; caller resamples if needed.
        return try await manager.transcribe(samples, source: source)
    }
}
```

Then a trivial adapter in `Sources/Meeting/MeetingSTTAdapter.swift` (new, Lane B) conforms to `TranscriptedCore.SpeechToTextEngine`:

```swift
struct MeetingSTTAdapter: SpeechToTextEngine {
    let engine: ParakeetEngine
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        try await engine.transcribeSamples(samples, source: source)
    }
}
```

**Effect on the merge:**

- `TranscriptedCore/Services/ParakeetService.swift` is **deleted from Tier A** — one fewer file to extract, one fewer place FluidAudio is touched. Removes from §1.2.1 (Tier A) count (23 files instead of 24). Core's `Services/AppServices.swift` passes a `MeetingSTTAdapter` wherever it previously instantiated `ParakeetService`.
- Draft's `ParakeetEngine` gains a ~10-line method. No impact on the existing short-dictation path since the new method doesn't touch `sampleBuffer`, `pendingSamples`, or `audioEngine`. EOU live-display logic is untouched.
- **Owner:** Lane B (`draft-integrator`) owns the new method on `ParakeetEngine` + the adapter; Lane A (`core-extractor`) owns deleting `ParakeetService.swift` and rewiring `AppServices`.
- **Risk mitigation:** the two callers never run concurrently in Phase 2 — meeting mode and dictation mode share the same `ParakeetEngine` instance but not at the same time (meeting mode is a new hotkey, dictation is existing). FluidAudio `AsrManager` is thread-safe for batch calls per its README; no additional locking needed.

#### `Sources/Speech/STTRouter.swift` vs Transcripted's audio pipeline

- **Decision: KEEP Draft's, and do NOT conform it to `SpeechToTextEngine`.** See the ParakeetEngine entry above for the reasoning — STTRouter owns the recording lifecycle, Core's `SpeechToTextEngine` expects to be given raw samples. The adapter lives in `Sources/Meeting/MeetingSTTAdapter.swift` and wraps `ParakeetEngine` directly, not STTRouter. STTRouter remains Draft-specific (dictation + overlay wiring) and untouched by the merge.

#### `Sources/Capture/ContextCaptureEngine.swift` vs Transcripted audio capture

- **Decision: KEEP Draft's. NO conflict.** Draft's `ContextCaptureEngine` is hotkey + screenshot orchestration, not audio capture. The file name is misleading — it lives in `Sources/Capture/` but captures screenshots + vision context for drafting, not audio. Transcripted's audio capture stack is orthogonal.
- **Follow-up rename suggestion (non-blocking):** consider renaming `Sources/Capture/` → `Sources/Hotkey/` or `Sources/ScreenContext/` post-merge to reduce confusion. Not in Phase 2 scope.

#### `Sources/Capture/ScreenCapture.swift` vs Transcripted

- **Decision: KEEP Draft's.** No Transcripted equivalent.

#### `Sources/Observability/AppLogger.swift` vs `TranscriptedCore/Logging/AppLogger.swift`

- **Decision: KEEP Draft's for Draft features; Core uses its own AppLogger internally.** Both are internal singletons with local file output. They will write to different files (Draft → `~/draft-debug.log`, Core → `~/Library/Logs/Transcripted/app.jsonl` unless we rewire it). Rewiring Core's AppLogger to route through Draft's is possible but out of scope — the Core tests assume its own format. **Compromise: Core's AppLogger log file path is configurable via `CoreStoragePaths.logs` (§1.5.3). Draft passes a path inside its own app support dir so all Draft-related logs live in one place.**
- **Owner:** `core-extractor` lane (path parameterization); `draft-integrator` lane (passing the Draft path).

#### `Sources/Observability/EventReporter.swift` + `EventTracker.swift` + `JSONLWriter.swift`

- **Decision: KEEP Draft's.** No Transcripted equivalent (Transcripted uses AppLogger subsystems; Draft uses structured events). Merging them is tempting but scope-creep.

#### `Sources/Feedback/`, `Sources/Analysis/`, `Sources/Draft/`, `Sources/Style/`, `Sources/Local/`, `Sources/Prompts/`

- **Decision: KEEP Draft's. NO overlap.** These are Draft-specific: drafting pipeline, style learning, MLX wrapper, prompt store, feedback logging, native analysis. Transcripted has zero equivalents.

#### `Sources/Accessibility/AccessibilityBridge.swift`

- **Decision: KEEP Draft's. NO overlap.** AX queries for text-field positioning; Transcripted has no accessibility code.

#### `Sources/UI/`

- **Decision: KEEP Draft's. NEW files added by `meeting-ui` lane.** No files overwrite each other. The new files:
  - `Sources/UI/MeetingOverlayController.swift` — shows meeting status (recording / transcribing / ready) in the floating overlay or a separate panel.
  - `Sources/UI/SpeakerNamingSheet.swift` — modal to name new speakers surfaced via `TranscriptionTaskManager.speakerNamingRequest`.
  - `Sources/UI/MenuBarPanel.swift` — **edit, not create.** Add a "Recent Meetings" section fed by `TranscriptedCore.TranscriptScanner`.

### 3.3 Import statement cheatsheet (Draft-side)

Every new Draft file that touches Core adds:

```swift
import TranscriptedCore
```

Specific call patterns:

**Starting a meeting recording (Draft's hotkey → Core):**

```swift
// Sources/Meeting/MeetingSessionController.swift
import TranscriptedCore

@MainActor
final class MeetingSessionController: ObservableObject {
    private let taskManager: TranscriptionTaskManager

    init() {
        let paths = CoreStoragePaths(
            transcripts: URL.draftAppSupportDir.appendingPathComponent("meetings"),
            speakerDB: URL.draftAppSupportDir.appendingPathComponent("meetings/speakers.sqlite"),
            statsDB: URL.draftAppSupportDir.appendingPathComponent("meetings/stats.sqlite"),
            failedQueue: URL.draftAppSupportDir.appendingPathComponent("meetings/failed.json"),
            speakerClips: URL.draftAppSupportDir.appendingPathComponent("meetings/speaker_clips"),
            logs: URL.draftAppSupportDir.appendingPathComponent("meetings/logs")
        )
        let modelBundle: ModelBundleProvider = { Bundle.main.resourcePath.map(URL.init(fileURLWithPath:)) }
        let parakeet = ParakeetService(bundleProvider: modelBundle)
        let diarization = DiarizationService(bundleProvider: modelBundle)
        let speakerDB = SpeakerDatabase(path: paths.speakerDB)
        let transcription = Transcription(
            parakeet: parakeet,
            diarization: diarization,
            speakerDB: speakerDB,
            storagePaths: paths
        )
        self.taskManager = TranscriptionTaskManager(
            transcription: transcription,
            failedManager: FailedTranscriptionManager(queuePath: paths.failedQueue),
            notifier: nil  // Draft uses EventReporter, not UN
        )
    }
}
```

**Using the audio capture stack (Tier C):**

```swift
// Sources/Meeting/MeetingCaptureBridge.swift
import TranscriptedCore

@MainActor
final class MeetingCaptureBridge {
    private let audio = Audio()  // assumes Core exposes a factory or public init
    // … bind audio.micLevels / audio.systemLevels to Draft's overlay
}
```

**Reading a saved transcript (minimal usage):**

```swift
import TranscriptedCore

let scanner = TranscriptScanner(directory: CoreStoragePaths.default.transcripts)
let recent = scanner.listTranscripts().prefix(5)
```

**Speaker DB lookups (Draft's menubar "Recent Speakers" panel):**

```swift
import TranscriptedCore

let db = SpeakerDatabase(path: Draft.meetingSpeakerDBPath)
let profiles = db.allSpeakers().sorted { $0.lastSeen > $1.lastSeen }
```

---

## 4. Build System Coordination

### 4.1 FluidAudio consolidation — the single biggest build decision

**Current state (per inventories + transcripted-mapper follow-up):**
- **Draft** builds FluidAudio from source via `~/redbars/code/Draft/build-fluidaudio.sh` (legacy) and `build-deps.sh` (current) → `deps-libs/libDraftDeps.a` (unified static lib containing FluidAudio + mlx-swift-lm + deps). FluidAudio version: **0.7.9** (from the heredoc inside `build-deps.sh`). Metallib + .swiftmodules go into `deps-libs/` / `deps-modules/`.
- **Transcripted** ships a **committed, unversioned** `fluidaudio-libs/libFluidAudioAll.a` (~54 MB) + `fluidaudio-modules/` with 18 prebuilt `.swiftmodule` bundles. **There is no `Package.resolved`, no commit message pinning the upstream revision, and no record of which FluidAudio tag produced the binary.** (Confirmed by transcripted-mapper after reviewing the Transcripted repo directly.) Separately, `TranscriptedCLI/` links against a different artifact (`-lFluidAudioCLI`) which is ALSO unversioned. This is not a version mismatch with Draft — it is unknown provenance.

**Four strategy options** (from transcripted-inventory.md §11.7):

1. **Consolidate on Draft's `build-fluidaudio.sh` output, Transcripted's Xcode project links Draft's `deps-libs/`.** Transcripted removes its committed binaries, adds a build phase that runs `../Draft/build-fluidaudio.sh`, adjusts `LIBRARY_SEARCH_PATHS` and `SWIFT_INCLUDE_PATHS` to point at `../Draft/deps-libs/` and `../Draft/deps-modules/`. **One source of truth, ~54 MB deleted from Transcripted git.**
2. **Binary XCFramework.** Repackage the prebuilt into a `.xcframework`, reference via `.binaryTarget` in `Package.swift`. SPM-native, no unsafe flags. Requires a one-time packaging script and the xcframework committed (or hosted).
3. **Upstream SPM source dependency.** Both repos switch to `.package(url: "FluidInference/FluidAudio", from: "0.7.9")`. Gives up Draft's custom Swift 6.3 prebuild. Rebuild time jumps (FluidAudio is heavy).
4. **Keep separate.** Each repo has its own copy. Transcripted's artifact is committed; Draft's is generated. No consolidation. **Rejected** — duplicates ~54 MB of binaries and risks version drift.

**Our recommendation: Option 1 (Consolidate on Draft's build).** Justification:

- Draft already has the build pipeline working and documented (`build-deps.sh`, current — supersedes the legacy `build-fluidaudio.sh`).
- Draft's deps-libs is a *unified* lib (FluidAudio + mlx-swift-lm) — Transcripted doesn't need MLX, but a superset is fine because the linker only pulls in what's referenced. The ~54 MB overhead is already in Draft.
- Transcripted's committed binaries are a git-history smell (per its own `0908d05 chore: rebuild FluidAudio binaries for Swift 6.3 toolchain` commit — the team already rebuilds them periodically) AND have unknown upstream provenance.
- One source of truth means version alignment is free — and "alignment" is moot because Transcripted currently has no version to align to.
- **Side benefit:** deletes ~54 MB of committed binaries + ~18 `.swiftmodule` bundles from the Transcripted repo. Also removes the `TranscriptedCLI/`-specific `-lFluidAudioCLI` binary, since the CLI will relink against Draft's `deps-libs/libDraftDeps.a`.
- **Fallback if this doesn't work:** Option 2 (xcframework) — larger effort but still merge-compatible.

**v2 — §6.2 resolution and Phase 2 prerequisite:**

The "FluidAudio version alignment" uncertainty that was Open Question §6.2 in v1 is **resolved**: Transcripted's binary is unversioned, so there is nothing to align to — the correct action is to rebuild from a known upstream. Phase 2 introduces a new **prerequisite step (Phase 2.0)** owned by Lane D (`build-plumbing`): *Rebuild `fluidaudio-libs/` and `fluidaudio-modules/` in the Transcripted repo from `FluidAudio 0.7.9` via `build-deps.sh`, verify the existing Transcripted Xcode app still builds and its test suite still passes against the rebuilt binary, then delete the old committed binaries in the same commit.* This must complete before Lane A (`core-extractor`) starts moving files, because (a) the rebuild may surface API drift between the unknown committed version and 0.7.9 that Lane A would otherwise inherit mid-extraction, and (b) it unblocks the §4.1 Option 1 consolidation before any Draft-side integration touches the new Core module.

### 4.2 `Package.swift` for TranscriptedCore (to be created inside the Transcripted repo)

```swift
// swift-tools-version:5.9
// ~/redbars/code/Transcripted/Package.swift   (NEW — alongside the existing Xcode project)
import PackageDescription

let package = Package(
    name: "Transcripted",
    platforms: [.macOS(.v14)],                // MUST match Draft
    products: [
        .library(name: "TranscriptedCore", targets: ["TranscriptedCore"])
    ],
    dependencies: [
        // No upstream SPM deps — FluidAudio is linked via unsafeFlags below
    ],
    targets: [
        .target(
            name: "TranscriptedCore",
            path: "Sources/TranscriptedCore",
            linkerSettings: [
                .unsafeFlags([
                    // Points at Draft's deps-libs via a relative path
                    "-L", "../Draft/deps-libs",
                    "-lDraftDeps",
                    "-lc++"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AppKit")     // needed for NSWorkspace sleep/wake + NSSound
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-I", "../Draft/deps-modules",
                    "-I", "../Draft/deps-modules/FastClusterWrapper",
                    "-I", "../Draft/deps-modules/MachTaskSelfWrapper",
                    "-I", "../Draft/deps-modules/yyjson"
                ])
            ]
        ),
        .testTarget(
            name: "TranscriptedCoreTests",
            dependencies: ["TranscriptedCore"],
            path: "Tests/TranscriptedCoreTests"
        )
    ]
)
```

**Unsafe-flags caveat:** SPM `unsafeFlags` propagates to consumers. Draft's sidecar `.deps-build/Package.swift` imports this package, and SPM will compile Draft's Shim with those flags. That's OK because Draft's sidecar already uses `build-deps.sh`-style patterns — but it means **no other SPM package can consume TranscriptedCore** without also co-hosting Draft's deps dirs. For Phase 2 this is fine (only Draft consumes Core). Post-merge we can wrap FluidAudio in a proper `.binaryTarget` xcframework and drop the unsafe flags.

### 4.3 `build-deps.sh` changes

Draft's `~/redbars/code/Draft/build-deps.sh` (not shown in §1.6 of draft-inventory but assumed standard) builds `deps-libs/libDraftDeps.a` from the sidecar SPM workspace. We add TranscriptedCore to that workspace's dependency list (already shown in §2.2). **No new script required** — TranscriptedCore piggybacks on the existing Shim → release build pattern.

### 4.4 Info.plist and entitlements changes in Draft

Meeting capture requires additional permissions and strings. Edits to `~/redbars/code/Draft/Info.plist`:

```diff
   <key>NSMicrophoneUsageDescription</key>
-  <string>Draft needs microphone access to transcribe your voice into text.</string>
+  <string>Draft needs microphone access to transcribe your voice and record meetings.</string>

+  <key>NSAudioCaptureUsageDescription</key>
+  <string>Draft captures system audio during meetings to transcribe all participants.</string>

   <key>NSScreenCaptureUsageDescription</key>
   <string>Draft captures your screen to extract conversation context for smarter message drafting.</string>
```

**No `NSSystemAdministrationUsageDescription` is needed** — CoreAudio process tap API (macOS 14.2+) only requires `NSAudioCaptureUsageDescription`.

Edits to `~/redbars/code/Draft/build.sh` entitlements heredoc (lines 45–58):

```diff
     <key>com.apple.security.device.audio-input</key>
     <true/>
     <key>com.apple.security.speech.recognition</key>
     <true/>
+    <key>com.apple.security.device.audio-capture</key>
+    <true/>
```

**No change to `com.apple.security.app-sandbox = false`** — already correct.

### 4.5 Resource changes in Draft

Draft's `build.sh` already bundles Parakeet TDT v3 CoreML models into `Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/` (see `build.sh:16–23`) and the EOU streaming model (`build.sh:25–39`). **Those are the same models Transcripted's former `ParakeetService` (now deleted per §3.2) expects** when `bundleProvider` resolves to `Bundle.main.resourcePath`. Since Draft's `ParakeetEngine` owns the same models, **zero new model downloads required for Parakeet.**

**New model bundles needed for meeting mode** (per transcripted-inventory.md §7 + transcripted-mapper follow-up on `ModelDownloadService`):

Transcripted's meeting pipeline depends on three additional CoreML model families that Draft does not currently ship:

1. **PyAnnote speaker-diarization-coreml** (`DiarizationService` primary path) — multi-file CoreML bundle: `speaker-diarization-3.1-coreml`, ~17 MB. Used for offline whole-audio diarization after meeting ends.
2. **Sortformer streaming diarizer** (`StreamingDiarizerManager`) — optional, used if streaming diarization is enabled. ~200 MB. Large enough to defer to runtime download unless explicitly opted in.
3. **WeSpeaker 256-dim embeddings** (`SpeakerEmbedder` → `SpeakerDatabase`) — CoreML model producing per-segment embeddings for `matchSpeaker()` with adaptive thresholds. ~100 MB.

**Two strategies (decide during Lane D):**

- **Strategy A — Bundle at build time** (mirrors Draft's existing Parakeet approach). New `build.sh` steps:
  ```bash
  # Bundle PyAnnote + WeSpeaker + speaker-diarization-coreml for meeting mode
  DIARIZE_SRC="$HOME/Library/Application Support/FluidAudio/Models"
  for MODEL in speaker-diarization-3.1-coreml wespeaker-voxceleb-resnet34-LM; do
      if [ -d "$DIARIZE_SRC/$MODEL" ]; then
          echo "Bundling $MODEL..."
          mkdir -p "$APP_BUNDLE/Contents/Resources/diarize-models"
          cp -R "$DIARIZE_SRC/$MODEL" "$APP_BUNDLE/Contents/Resources/diarize-models/"
      else
          echo "$MODEL not found at $DIARIZE_SRC — meeting diarization will attempt runtime download"
      fi
  done
  # Sortformer (streaming diarizer) — optional, ~200 MB. Bundle only if explicitly requested.
  ```
  Pros: offline-capable, matches Draft's Parakeet bundling pattern, no first-launch download stall.
  Cons: pushes app bundle size to ~720 MB+ (from current ~600 MB) and requires every dev machine to have the models pre-downloaded at `$HOME/Library/Application Support/FluidAudio/Models/`.

- **Strategy B — Extract Transcripted's `ModelDownloadService` into TranscriptedCore and use it for all non-Parakeet models at first-launch.** Per transcripted-mapper: Transcripted already has a progress-reporting model downloader that handles resumable HuggingFace downloads. If extracted as part of Tier B (§1.2.2), Draft can wire it behind a one-time "First-time meeting setup" flow in the menubar panel — user clicks "Set up meetings" → downloader shows progress → meeting hotkey unlocks when complete. Draft already uses `ParakeetModelState` (`parakeet/CLAUDE.md:38`) to gate its hotkey on model load; extending that pattern to meeting models is low-risk.
  Pros: keeps Draft's bundle size small, matches Transcripted's existing UX, no dev machine dependency.
  Cons: first-meeting-ever on a fresh install requires network access and ~320 MB of downloads.

**Our recommendation:** **Strategy B** for PyAnnote and WeSpeaker (required for meeting mode), **Strategy A** as a future optimization once bundle-size budget allows. Sortformer stays download-only regardless (too large to bundle unconditionally). This keeps Phase 2's scope bounded — Lane D wires `ModelDownloadService` and gates the meeting hotkey on its state; it does not need to solve bundle size.

**Model size summary (no bundling impact under Strategy B):**

| Model | Size | Purpose | Strategy |
|---|---|---|---|
| Parakeet TDT v3 | ~600 MB | Transcription (batch) | **Bundled** (existing Draft flow) |
| Parakeet EOU 120M | ~120 MB | Live-display streaming | **Bundled** (existing Draft flow) |
| speaker-diarization-3.1-coreml (PyAnnote) | ~17 MB | Offline whole-audio diarization | **Downloaded on first meeting** |
| WeSpeaker-256 | ~100 MB | Per-segment speaker embeddings | **Downloaded on first meeting** |
| Sortformer (optional) | ~200 MB | Streaming diarization | **Downloaded on user opt-in only** |

Under Strategy B, Draft's bundle size stays at ~720 MB (unchanged from today), and first-meeting cold start adds a one-time ~117 MB download.

### 4.6 build.sh final framework link line additions

On top of the existing 16 framework flags (`build.sh:87–100`), the meeting path needs only one new framework:

```diff
   -framework Metal \
   -framework MetalKit \
   -framework Accelerate \
+  -framework CoreAudioTypes \
```

`CoreAudio` is already linked via `$DEPS_FLAGS` (`build.sh:75`). `AppKit`, `AVFoundation`, `Metal`, `MetalKit`, `Accelerate`, `CoreML`, `Combine`, `SwiftUI` are all already linked.

---

## 5. Phase 2 Execution Lanes

Four ownership lanes. Each lane owns a disjoint set of directories + files. **No two lanes modify the same file.** Cross-lane hand-offs are defined by the interface contracts below.

### 5.1 Lane A — `core-extractor` (owns Transcripted repo changes)

**Directory boundary:** everything inside `~/redbars/code/Transcripted/` EXCEPT `Transcripted/UI/`, `Transcripted/Design/`, `Transcripted/Onboarding/`, `TranscriptedTests/UI/`, and Tools/ packages (those stay untouched).

**Work items (in order):**

1. **Milestone 0 — `@available(macOS 26.0, *)` audit.** For each of the 81 gates across the 44+8 Core candidate files (Tiers A, B, C), determine: load-bearing or conservative? Output: a delta file listing which gates drop to 14.2 and which stay. **Blocks everything else.** Owner consults transcripted-mapper (still the subject-matter expert) if ambiguous.
2. Create `Package.swift` at Transcripted repo root per §4.2.
3. Create `Sources/TranscriptedCore/` directory tree with the subdirs from §1.2.
4. Move 52 files from `Transcripted/Core/` + `Transcripted/Services/` into `Sources/TranscriptedCore/<subdir>/` per §1.2 tables. Update pbxproj references in the same commit.
5. Apply visibility changes: `internal` → `public` per §1.4. ~44 types + methods.
6. Apply Tier B surgery per §1.5:
   - Introduce `CoreStoragePaths` struct.
   - Introduce `ModelBundleProvider` closure type; rewrite `ParakeetService.bundledModelsPath` and `DiarizationService.bundledModelsPath`.
   - Introduce `TranscriptNotifier` protocol; rewire `TranscriptionTaskManager` and `TranscriptSaver` notification calls.
7. Complete the `Services/Protocols/` wiring (the file's own TODO): make concrete types conform, switch `AppServices` stored properties to `any <Protocol>` types. **If transcripted-mapper's answer to Open Question §6.4 is "Transcripted team will do this pre-extraction", skip this step and wait for their delivery.**
8. Move Core-level tests from `TranscriptedTests/` to `Tests/TranscriptedCoreTests/`. UI tests stay in place.
9. Update Transcripted's Xcode app target to `import TranscriptedCore` from its own source files that previously had implicit access to Core types. Verify the app still builds and all existing Transcripted features work — **this is the regression surface.**
10. Tag the extraction commit: `extract: TranscriptedCore v1 — ready for Draft consumption`.

**Dependencies:** Lane A is the trunk. Lanes B, C, D all depend on Lane A reaching at least step 5 (the minimum viable module).

**Effort order of magnitude:** this is the largest lane. Step 1 (audit) is the biggest unknown. Steps 2–5 are mostly mechanical. Step 6 is the hard thinking. Step 9 is the highest risk for regressing Transcripted's shipping app.

**Acceptance criteria:** Transcripted's Xcode app target builds and all existing tests pass. `swift build -c release --product TranscriptedCore` succeeds from the Transcripted root. No files reference `Bundle.main` or `~/Documents/Transcripted/` inside `Sources/TranscriptedCore/`.

### 5.2 Lane B — `draft-integrator` (owns Draft Package.swift + build plumbing + `Sources/Meeting/` wiring)

**Directory boundary:** `~/redbars/code/Draft/.deps-build/Package.swift`, `~/redbars/code/Draft/build.sh`, `~/redbars/code/Draft/build-deps.sh`, `~/redbars/code/Draft/Info.plist`, `~/redbars/code/Draft/Sources/Meeting/` (new), `~/redbars/code/Draft/Sources/Speech/AudioResampler.swift` (delete — replaced by Core's), `~/redbars/code/Draft/Sources/DraftPaths.swift` (extend with `meetingSupportDir`).

**Work items:**

1. Add `TranscriptedCore` package dependency to `.deps-build/Package.swift` per §2.2.
2. Modify `build.sh` per §2.3 (pre-step that builds TranscriptedCore, adds `-I`/`-L`/`-l` flags, bundles PyAnnote models).
3. Modify `Info.plist` + entitlements per §4.4.
4. Create `Sources/Meeting/` with:
   - `MeetingSessionController.swift` (wraps `TranscriptionTaskManager`, exposes `@Published` state to Draft UI).
   - `MeetingCaptureBridge.swift` (thin bridge to Core's audio stack).
   - `MeetingStoragePaths.swift` (Draft's concrete `CoreStoragePaths` instance pointing at `~/Library/Application Support/Draft/meetings/`).
   - `MeetingModelDownloader.swift` (if models aren't bundled, call `ModelDownloadService.withRetry`).
5. Delete `Sources/Speech/AudioResampler.swift`, update `Sources/Speech/ParakeetEngine.swift` imports.
6. Add integration smoke test: `run-tests.sh` gets a new test that constructs `MeetingSessionController` and verifies all Core services initialize without throwing.

**Dependencies:** needs Lane A at minimum through step 5 (module builds, public API available). Can start in parallel with Lane A step 6 once initial visibility is done.

**Effort order of magnitude:** smaller than Lane A but high-precision work. Build-system changes are risky because Draft's `swiftc`-driven build is fragile to flag ordering.

**Acceptance criteria:** `bash build.sh` completes successfully. Running the app and pressing a new meeting hotkey (stub is fine) constructs all Core engines without crashing. `run-tests.sh` passes existing 147 tests plus the new integration smoke.

### 5.3 Lane C — `meeting-ui` (owns Draft's UI additions for meeting mode)

**Directory boundary:** `~/redbars/code/Draft/Sources/UI/MeetingOverlayController.swift` (new), `~/redbars/code/Draft/Sources/UI/SpeakerNamingSheet.swift` (new), `~/redbars/code/Draft/Sources/UI/MenuBarPanel.swift` (edit — add meetings section), `~/redbars/code/Draft/Sources/HotkeyPreferences.swift` (edit — add meeting hotkey default), `~/redbars/code/Draft/Sources/Capture/ContextCaptureEngine.swift` (edit — register third hotkey ID for meeting mode).

**Work items:**

1. Add a third Carbon hotkey ID (`id 3`, signature `'DRFT'`, default binding — human chooses in §6.6) to `ContextCaptureEngine.swift` for "toggle meeting recording".
2. Create `MeetingOverlayController.swift` — shows a small indicator panel during meeting recording ("⏺ Recording meeting 00:23 — Alice, Bob"), binds to `MeetingSessionController.@Published` state.
3. Create `SpeakerNamingSheet.swift` — modal prompted by `TranscriptionTaskManager.speakerNamingRequest`. User types names; sheet calls `RetroactiveSpeakerUpdater` to propagate.
4. Edit `MenuBarPanel.swift` to add a new "Recent Meetings" section fed by `TranscriptScanner`. Preserve existing structure (stats, style, agent sections).
5. Edit `HotkeyPreferences.swift` to persist the meeting hotkey binding.
6. Add UI tests (pure-function tests for state derivation, if any).

**Dependencies:** needs Lane A through step 5 AND Lane B through step 4 (so `MeetingSessionController` exists to bind to).

**Effort order of magnitude:** medium. AppKit UI authoring is straightforward in Draft's existing idiom (pure NSView, no NSHostingView). The biggest unknown is how the new overlay interacts with Draft's existing floating overlay — do we share the panel or create a second one? Recommend a second panel to avoid state-machine churn in `FloatingOverlayController.swift`.

**Acceptance criteria:** Pressing the meeting hotkey shows the overlay, starts recording via `MeetingSessionController`, stops on second press, surfaces a speaker-naming sheet when required, and the transcript appears in the menubar's Recent Meetings section.

### 5.4 Lane D — `build-plumbing` (owns FluidAudio consolidation + Transcripted's build-artifact retirement)

**Directory boundary:** `~/redbars/code/Draft/build-deps.sh` (edit the heredoc to add TranscriptedCore — see §2.2), `~/redbars/code/Transcripted/fluidaudio-libs/` (rebuild then delete), `~/redbars/code/Transcripted/fluidaudio-modules/` (rebuild then delete), `~/redbars/code/Transcripted/Transcripted.xcodeproj/project.pbxproj` (edit — repoint `LIBRARY_SEARCH_PATHS` + `SWIFT_INCLUDE_PATHS`), any new `build-transcripted.sh` helper at Transcripted root.

**Work items — Phase 2.0 (prerequisite, runs FIRST, blocks Lane A):**

1. **Rebuild Transcripted's FluidAudio binary from SPM `FluidAudio 0.7.9`** using Draft's `build-deps.sh` pattern. Produces a known-provenance `libDraftDeps.a` and `.swiftmodule` set. No merge of the two codebases yet — this is a clean rebuild verified against the existing Transcripted Xcode app.
2. Update Transcripted's `project.pbxproj` to point `LIBRARY_SEARCH_PATHS` at `$(SRCROOT)/../Draft/deps-libs` and `SWIFT_INCLUDE_PATHS` at `$(SRCROOT)/../Draft/deps-modules` (+ subdirs), and change `OTHER_LDFLAGS` from `-lFluidAudioAll` to `-lDraftDeps`.
3. Build Transcripted's Xcode app against the rebuilt binary. Run Transcripted's existing test suite. Verify meeting recording + transcription + diarization still work end-to-end against the rebuilt FluidAudio. Fix any API drift inside Transcripted's app sources (NOT yet inside Core — that's Lane A).
4. `git rm -r Transcripted/fluidaudio-libs/ Transcripted/fluidaudio-modules/` and any `-lFluidAudioCLI` artifacts used by `TranscriptedCLI/`. Commit: `build: rebuild FluidAudio from SPM 0.7.9, retire committed binaries`. **This commit deletes ~54 MB from the Transcripted repo.**
5. Green light Lane A (`core-extractor`) to start.

**Work items — Phase 2.3 (post-Lane-A consolidation):**

6. Add TranscriptedCore to Draft's `build-deps.sh` heredoc per §2.2. Run `bash build-deps.sh --force` on Draft. Verify `libDraftDeps.a` now contains TranscriptedCore symbols.
7. Update Transcripted's `project.pbxproj` to also surface the new `TranscriptedCore` SPM product inside the Xcode app (so the Transcripted app keeps using Core as a library, not via `@testable import`).
8. Document the cross-repo dependency in `Transcripted/README.md` and/or `Transcripted/CLAUDE.md`.

**Dependencies:** Phase 2.0 blocks Lane A. Phase 2.3 requires Lane A + Lane B complete.

**Effort order of magnitude:** medium — the rebuild itself is small, but validating the Transcripted app still works end-to-end against a potentially-newer FluidAudio surface area (diarization, speaker embeddings, OfflineDiarizerManager) is the real cost. Biggest risk is silent behavior drift between the unknown-version committed binary and 0.7.9 — Mitigation: run the full Transcripted test suite, plus a manual meeting end-to-end smoke, before proceeding to step 4.

**Acceptance criteria:** Phase 2.0 — Transcripted's Xcode app builds and runs against the rebuilt FluidAudio, full test suite passes, meeting end-to-end smoke passes, `git ls-files Transcripted/ | grep fluidaudio` returns zero files. Phase 2.3 — Draft's `libDraftDeps.a` contains TranscriptedCore symbols, `import TranscriptedCore` resolves in Draft's `Sources/Meeting/` files, both apps build from a fresh checkout.

### 5.5 Lane sequencing diagram (v2 — adds Phase 2.0 prerequisite)

```
Phase 2.0           Milestone 0       Lane A                  Lane B                  Lane C                  Lane D (cont.)
prerequisite        (blocks A)        core-extractor          draft-integrator        meeting-ui              build-plumbing
────────────        ──────────        ──────────────          ────────────────        ──────────              ──────────────
Lane D Phase 2.0    │                 │                       │                       │                       │
│                   │                 │                       │                       │                       │
▼                   ▼                 ▼                       │                       │                       │
Rebuild FluidAudio  macOS 26         Create TranscriptedCore  │                       │                       │
from SPM 0.7.9      availability     ┌─ step 1–5 (mod builds) │                       │                       │
in Transcripted     audit            │                        │                       │                       │
repo, delete        (1 day?)         ▼ step 5 complete ──────►│                       │                       │
committed binaries  │                ├─ step 6–7 (surgery)    ▼                       │                       │
▼                   │                │                        Add TranscriptedCore    │                       │
Transcripted app    │                │                        to build-deps.sh        │                       │
still builds +      │                │                        heredoc + Meeting/      │                       │
tests pass          │                │                        + Adapter + new         │                       │
▼                   │                │                        transcribeSamples       │                       │
Green-light         │                │                        └─ step 4 complete ────►│                       │
Lane A ─────────────┴───────────────►│                        ▼                       ▼                       │
                                     ▼ step 9 (regression)    Integration smoke       UI additions            │
                                     Transcripted app         passes                  + hotkey wiring         │
                                     still builds                                                             │
                                     (Core now a library)                                                     │
                                     ▼                        ▼                       ▼                       │
                                     step 10 tag ─────────────┴───────────────────────┴──────────────────────►│
                                                                                                               Phase 2.3:
                                                                                                               TranscriptedCore
                                                                                                               now consumed by
                                                                                                               both Draft (via
                                                                                                               deps-libs) AND
                                                                                                               Transcripted
                                                                                                               (via SPM product)
                                                                                                               ▼
                                                                                                               Both apps build,
                                                                                                               end-to-end smoke
```

**Critical v2 change:** Phase 2.0 (FluidAudio rebuild) MUST complete before Lane A starts. This removes the unknown-provenance binary from the Transcripted repo BEFORE any Core file moves, so Lane A is working against a known-version FluidAudio surface area throughout the extraction.

### 5.6 Cross-lane interface contracts

- **Core-extractor → draft-integrator:** delivered artifact is a compilable `Sources/TranscriptedCore/` module with public symbol signatures matching §1.4. Specifically: `CoreStoragePaths`, `ModelBundleProvider`, `TranscriptNotifier`, `Transcription`, `TranscriptionTaskManager`, `SpeakerDatabase`, `ParakeetService`, `DiarizationService` — all public, all initializable with `CoreStoragePaths` + `ModelBundleProvider` injection.
- **Draft-integrator → meeting-ui:** delivered artifact is a working `MeetingSessionController` with `@Published` state. Meeting-ui binds to its properties without needing to touch Core types directly (though it may still `import TranscriptedCore` for models like `DisplayStatus`, `SpeakerProfile`).
- **Build-plumbing → everyone:** deliverable is a green Transcripted build using Draft's deps-libs. Cross-lane dependency is minimal because the lanes operate on disjoint files.

---

## 6. Open Questions for Human Review

Judgment calls the human should confirm or resolve before Phase 2 starts.

### 6.1 macOS deployment target — the single biggest decision **(partial v2 resolution)**

**The constraint:** Draft ships `LSMinimumSystemVersion 14.0` and `-target arm64-apple-macos14.0`. Transcripted has 81 `@available(macOS 26.0, *)` gates across 58 files.

**v2 partial resolution from transcripted-mapper:** the pipeline heavy-lifting code (`TranscriptionPipeline`, `TranscriptionPipelineRunner`, `TranscriptionTaskManager`, `ParakeetService`, `DiarizationService`, `SpeakerDatabase`) is mostly `nonisolated` — the `@MainActor` scatter is surface-level (UI glue, `@Published` properties on top of the nonisolated workers). The 81 `@available(macOS 26.0, *)` gates remain the larger blocker than actor isolation. Many of them are likely conservative defaults applied repo-wide rather than genuine API requirements.

**The question:** Phase 2 Milestone 0 is an availability audit to determine how many of those 26-gates are actually load-bearing vs conservative. Our strong expectation (unchanged from v1) is that most Core candidate files will drop to 14.2 cleanly because:
- `ParakeetService` / `DiarizationService` / `SpeakerDatabase` already gate at `@available(macOS 14.0, *)` per inventory.
- Audio capture (Tier C) will need 14.2+ anyway because CoreAudio process taps are 14.2+.
- UI/Design/Onboarding files (which Draft doesn't consume) can keep their 26-gates — they're Tier 0, not moving.

**Human: do you accept this plan assuming the audit confirms most Core gates drop to 14.2?** If the audit surfaces a load-bearing 26-only API (e.g., a new AV/CoreAudio API) in a Tier A/B file Draft needs, the merge scope shrinks to "everything except that file" OR Draft's deployment target rises (out of scope in our read).

### 6.2 FluidAudio version alignment **(RESOLVED in v2 — no longer a blocker)**

**v1 stated:** Transcripted's committed `libFluidAudioAll.a` had an unknown version. v2 confirms there is no version to align to — Transcripted has no `Package.resolved`, no commit-message pinning, and no reproducible build of the committed binary (confirmed by transcripted-mapper after direct repo inspection). `TranscriptedCLI/`'s separate `-lFluidAudioCLI` is also unversioned.

**v2 decision:** this is not an alignment problem, it is a provenance problem. Resolution: Phase 2.0 prerequisite (Lane D) rebuilds Transcripted from SPM `FluidAudio 0.7.9` — the same version Draft already builds. This is documented in §4.1 and §5.4 above. **§6.2 is no longer an Open Question**; it is a work item in Phase 2.0. Listed here only for backward reference from the v1 open questions.

### 6.3 Does Draft reuse Transcripted's audio capture stack (Tier C) or keep its own?

**The constraint:** Draft has no dual-stream (mic + system audio) capture today. Transcripted's stack (~2,000 LOC, 8 files) is production-grade with sleep/wake handling, device recovery, energy VAD, watchdog, CoreAudio process taps. But it's AppKit-coupled and may carry `macOS 26.0` gates.

**Our recommendation:** Yes, Draft reuses Tier C. Rebuilding dual-stream capture from scratch in Draft would duplicate ~2,000 LOC for zero benefit. The AppKit coupling is fine (Draft is AppKit). The audit (§6.1) will tell us if the 26-gates block this.

**Human: confirm?**

### 6.4 Protocols/ wiring — pre-work or Phase 2 work? **(v2 — Phase 2 Lane A)**

**The constraint:** Transcripted's `Services/Protocols/` has 6 protocols defined but no concrete type formally conforms. `AppServices.swift` has a TODO to switch. If this wiring happens **before** Phase 2 (owned by the Transcripted team outside this merge effort), Draft can inject alternate implementations cleanly. If it happens **inside** Phase 2's `core-extractor` lane, the lane takes longer and the regression surface on Transcripted's app grows.

**v2 resolution (from transcripted-mapper + plan author alignment):** the Transcripted team has no pre-Phase-2 plan to complete the `AppServices` TODO, so Lane A (`core-extractor`) owns this work. Estimated size: ~100–150 LOC of mechanical conformance glue across the 6 protocols — each concrete service gets an `extension ParakeetService: SpeechToTextEngine { ... }`-style block, and `AppServices` is rewritten to hold protocol-typed properties instead of concrete types. This is added to Lane A work items between steps 5 (visibility changes) and 6 (Tier B surgery) because (a) it touches the same files Tier B surgery touches, and (b) Draft's adapter (`MeetingSTTAdapter` from §3.2) needs the protocol contracts to be stable before Lane B can write against them.

**Acceptance criterion for the Protocols wiring sub-step:** the 6 `Services/Protocols/` protocols each have at least one concrete conformer inside Core, `AppServices.swift` holds only protocol-typed properties, and Transcripted's existing app still builds and runs. Lane B's `MeetingSTTAdapter` is the second conformer of `SpeechToTextEngine`, validating the protocol shape from the Draft side.

**Remaining human judgment:** nothing — this is now a plan item, not a decision. Listed here for visibility.

### 6.5 Storage path unification — shared with Transcripted or isolated to Draft?

**The constraint:** Transcripted's `SpeakerDatabase`, `StatsDatabase`, `TranscriptSaver`, etc. default to `~/Documents/Transcripted/` and `~/Library/Logs/Transcripted/`. Our `CoreStoragePaths` fix (§1.5.3) lets Draft inject its own. **But should Draft do that?**

Two options:

- **Option A — shared** (`CoreStoragePaths.default`): Draft writes meeting transcripts and speaker DBs into `~/Documents/Transcripted/`, side-by-side with Transcripted's own output. User gets one unified speaker DB across both apps. If the user has both apps installed, naming a speaker in one app surfaces them in the other. Potentially surprising.
- **Option B — isolated** (`CoreStoragePaths(transcripts: ~/Library/Application Support/Draft/meetings/, ...)`): Draft has its own sandbox. Speaker DBs are separate. No interop. Clean mental model.

**Our recommendation: Option B (isolated) for Phase 2.** Draft owns its own speaker profiles. If the user later wants interop ("import my Transcripted speaker DB"), we add a one-time migration tool. Starting isolated is reversible; starting unified is not.

**Human: confirm?**

### 6.6 New meeting hotkey default

**The constraint:** Draft has two hotkeys today (⌥D draft, ⌥Space dictation). Meeting mode needs a third. Options: ⌥M (mnemonic "Meeting"), ⌥R (mnemonic "Record"), ⌥⇧D (extending the D namespace), or a long-press on an existing hotkey.

**Our recommendation:** ⌥M. Obvious mnemonic, not taken by any popular macOS app we're aware of, matches Draft's single-modifier pattern.

**Human: confirm?**

### 6.7 Phase 2 agent team composition

**The question:** each lane can be run by a separate agent pair (engineer + reviewer) or all four by one agent sequentially. Parallel is faster but risks merge conflicts at lane boundaries. Sequential is slower but safer.

**Our recommendation:** Lanes A and D run in parallel (Lane A on Transcripted repo sources, Lane D on Transcripted pbxproj + Draft deps), then Lanes B and C run in sequence after A reaches step 5 (B first, then C since C depends on B). That's 2 parallel agents for Phase 2.1, then 1 agent for Phase 2.2, then 1 agent for Phase 2.3.

**Human: approve this shape, or prefer fully sequential / fully parallel / different split?**

### 6.8 Phase 2 out-of-scope items (explicit non-goals)

Things NOT in Phase 2 that the human should be aware of:

- **Root `Package.swift` for Draft** (Shape X in §2.1). Deferred. Current `build.sh` remains authoritative.
- **Dropping Tools packages into Core.** `TranscriptedCLI`, `TranscriptedMCP`, `TranscriptedQA` stay as standalone Xcode+SPM packages in Transcripted. Draft doesn't touch them.
- **Draft CLI extension for headless meeting transcription.** Draft has no CLI target today (per draft-inventory §9). Adding one is a separate, optional post-merge lane.
- **Unifying Draft's `AppLogger` with Transcripted's `AppLogger`.** They keep separate log files (Draft → `~/draft-debug.log`, Core → `CoreStoragePaths.logs` path).
- **Migration tools for users with existing Transcripted installs.** If we go with Option B (isolated storage, §6.5), a "migrate from Transcripted" feature is a post-merge item.
- **Draft's `Sources/Capture/` rename** from "Capture" to something that reflects screenshot-only capture (suggested but not required).
- **Reconciling Draft's Gemini 3 Flash REST/SSE path vs the older MLX-only path described in CLAUDE.md.** Draft currently drafts via Gemini 3 Flash (confirmed in draft-inventory); the root CLAUDE.md still describes the MLX-only path. Transcripted has **zero LLM calls anywhere in the codebase** (confirmed by transcripted-mapper), so the Gemini/MLX path is a Draft-internal documentation cleanup, not a merge concern — the merge is purely additive to the drafting layer.
- **Swift 6 strict-concurrency adoption in Draft.** Draft compiles Swift 5 today; Core is Swift 6. Interop works. Upgrading Draft's source tree is separate.

---

## 7. Appendix — Quick Reference

### 7.1 File count summary

| Bucket | Count | LOC (approx) | v2 note |
|---|---:|---:|---|
| Tier A (no surgery) | 23 | ~3,400 | `ParakeetService.swift` deleted (§3.2) |
| Tier B (minor surgery) | 20 | ~7,000 | unchanged |
| Tier C (audio capture, conditional) | 8 | ~2,000 | unchanged |
| **TranscriptedCore total (A+B+C)** | **51** | **~12,400** | -1 file vs v1 |
| Stays in Transcripted app target | ~90 | ~18,000 | unchanged |
| New files in Draft (Sources/Meeting/ + UI/) | ~11 | ~1,050 | +1 for `MeetingSTTAdapter.swift` |
| Deleted from Transcripted repo (Phase 2.0) | — | — | ~54 MB committed FluidAudio binaries + .swiftmodule bundles |

### 7.2 Cross-reference map

- Draft inventory: [draft-inventory.md](draft-inventory.md) — all 13 Draft Sources/ subdirs, entry points, hotkey system, paste mechanism, audio capture, STT, dependency management, CLI check, verdict per subsystem.
- Transcripted inventory: [transcripted-inventory.md](transcripted-inventory.md) — all 48 Core + 16 Services + 36 UI + 21 Design + 9 Onboarding files, speaker DB schema, YAML frontmatter, Tools packages, extraction blockers §11.1–11.12.
- This file: merge-plan.md — contract for Phase 2 execution.

### 7.3 Commit attribution

All commits on `feat/transcripted-merge` are authored as `r3dbars <r3dbars@users.noreply.github.com>` with a `Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>` trailer. Set via `git -c user.name=r3dbars -c user.email=...` on each commit — Phase 0 agents do not modify repo git config.
