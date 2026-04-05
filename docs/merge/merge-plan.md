# Draft + Transcripted Merge Plan (Phase 0 Deliverable)

**Authors:** draft-mapper (owner), transcripted-mapper (contributor)
**Status:** v1 for human review — end of Phase 0. Phase 2 execution starts only after human sign-off.
**Inputs:** [draft-inventory.md](draft-inventory.md), [transcripted-inventory.md](transcripted-inventory.md)
**Worktree:** `<draft-root>/.claude/worktrees/transcripted-merge` on `feat/transcripted-merge`

All paths below are absolute unless otherwise noted. File path format: `<repo-root>/<relative>` where repo roots are `<draft-root>/` and `<transcripted-root>/`.

---

## 0. Executive Summary

**Goal:** give Draft access to Transcripted's meeting-transcription pipeline (dual-stream capture, Parakeet STT on long audio, PyAnnote speaker diarization, persistent speaker DB, markdown/YAML transcript output) without duplicating ~13.5k LOC and without breaking Transcripted's shipping app.

**Shape of the merge:**

1. **Extract `Sources/TranscriptedCore/` inside the Transcripted repo** as a new SPM library target alongside the existing Xcode app target. Transcripted's app delegate keeps using it via `@testable` style imports; nothing ships-breaking for Transcripted.
2. **Draft adopts `Package.swift`** (a first for Draft — see §2) and depends on TranscriptedCore via **local path** pointing at `<transcripted-root>/`. Draft's existing `swiftc`-driven `build.sh` remains, but calls `swift build` as a pre-step to produce the Core artifact and its module.
3. **FluidAudio is consolidated** onto Draft's existing `deps-libs/libDraftDeps.a` unified static library. Transcripted's committed `libFluidAudioAll.a` + `fluidaudio-modules/` are retired in favor of Draft's `build-fluidaudio.sh` output (assuming version alignment per Open Question §6.2).
4. **Draft's `Sources/Speech/` stays** — its ParakeetEngine is optimized for short dictation (≤30s) and fast overlay streaming, which is a different use case from Transcripted's long-audio `ParakeetService`. Both can coexist in the same binary linking one FluidAudio.
5. **Transcripted's audio capture stack is the authoritative source** for Draft's new meeting mode. Draft has no dual-stream capture today.
6. **Four execution lanes** (§5) split the Phase 2 work so two pairs of agents can run in parallel without file-level collisions: `core-extractor`, `draft-integrator`, `meeting-ui`, and `build-plumbing`.

**Single biggest risk:** the macOS deployment-target mismatch. Draft ships `arm64-apple-macos14.0` (per `build.sh:105` and `Info.plist:18`); Transcripted's Core candidate files carry 81 `@available(macOS 26.0, *)` gates across 58 files. Phase 2's first milestone is the macOS-26 audit; §6.1 is the gating Open Question for the human.

---

## 1. TranscriptedCore Extraction Strategy

### 1.1 Target shape

Create a new SPM library target `TranscriptedCore` inside `<transcripted-root>/`, coexisting with the existing `Transcripted.xcodeproj`:

```
<transcripted-root>/
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

Derived directly from transcripted-inventory.md §3 tiers. Paths on the left are current locations inside `<transcripted-root>/Transcripted/`; paths on the right are the final `Sources/TranscriptedCore/<subdir>/<file>` destinations.

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

### 2.2 Recommended: Shape Y — sidecar `Package.swift` pattern

Draft's existing `.deps-build/Package.swift` already handles exactly this pattern for mlx-swift-lm and FluidAudio. We extend that pattern with a third dependency.

**New file: `<draft-root>/.deps-build/Package.swift` (edits to existing)**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DraftDepsBuild",
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

- ✅ **`.package(path: "../../Transcripted")`** (local path, resolved against the `.deps-build/` dir → `<transcripted-root>/`).
  - **Why:** Both repos live side-by-side in `~/redbars/code/`. Local path means instant iteration — edit a Core file in Transcripted, rebuild Draft, done. No push/pull loop while Phase 2 lanes are in flight.
  - **Why not git URL pinned to `feat/extract-core`:** would force every Core tweak through a push-and-resolve cycle. Hurts velocity during Phase 2. Also risks partially-merged work being inaccessible to one side or the other.
- 🔁 **Promote to git URL later** — once the merge stabilizes (Phase 3+), switch to `.package(url: "https://github.com/r3dbars/Transcripted.git", branch: "main")` so CI builds of Draft can run without a co-checked-out Transcripted repo. That's a 1-line future change.

### 2.3 `build.sh` changes

Add these steps to `<draft-root>/build.sh` before the current `# Compile` section (see `build.sh:84`):

```bash
# Step X: Build TranscriptedCore via sidecar SPM workspace (uses .deps-build/)
if [ ! -f ".deps-build/.build/release/libTranscriptedCore.a" ] || [ "$1" = "--force" ]; then
    echo "Building TranscriptedCore..."
    (cd .deps-build && swift build -c release --product TranscriptedCore)
fi

# Step Y: Expose TranscriptedCore module + archive to the swiftc invocation
TC_BUILD_DIR="$(pwd)/.deps-build/.build/release"
CORE_FLAGS="-I $TC_BUILD_DIR -L $TC_BUILD_DIR -lTranscriptedCore"
```

Then the existing `swiftc` invocation adds `$CORE_FLAGS` to the link line (alongside `$DEPS_FLAGS`).

Draft source files that want Core do `import TranscriptedCore` at the top. The existing Sources/ tree does not use SPM modules today, so this import is a new convention — but mechanically identical to importing any system framework since `swiftc` sees it via `-I`.

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

- **Decision: KEEP BOTH.** These serve different use cases:
  - Draft's `ParakeetEngine` is tuned for short, live dictation in the overlay — <30s buffers, low latency, live-display streaming via FluidAudio's EOU (end-of-utterance) 120M model. Streaming, interactive. Integrated with Draft's `STTRouter` and Apple Speech fallback.
  - Transcripted's `ParakeetService` is tuned for long, batch transcription after recording completes — multi-minute meeting audio, full Parakeet TDT v3, no live display.
  - The two share the underlying FluidAudio library but different managers (`AsrManager` in streaming mode vs batch mode).
- **Justification:** unifying them would blur two genuinely different use cases. Draft's dictation path should NOT pay the latency cost of batch-mode Parakeet; Transcripted's long-audio path should NOT stream token-by-token.
- **Owner:** no owner — both files live as-is in their respective locations. The `meeting-ui` lane can optionally create `Sources/Speech/ParakeetLongEngine.swift` as a thin wrapper around `TranscriptedCore.ParakeetService` for meeting-mode use, but that's an internal Draft convenience, not a merge decision.

#### `Sources/Speech/STTRouter.swift` vs Transcripted's audio pipeline

- **Decision: KEEP Draft's.** STTRouter is Draft-specific logic (route between Parakeet vs Apple Speech based on microphone type, BEACN workaround, etc.). Transcripted has no equivalent. No overlap.

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

**Current state (per inventories):**
- **Draft** builds FluidAudio from source via `<draft-root>/build-fluidaudio.sh` → `deps-libs/libDraftDeps.a` (unified static lib containing FluidAudio + mlx-swift-lm + deps). FluidAudio version: **0.7.9** (from `.deps-build/Package.swift`). Metallib + .swiftmodules go into `deps-libs/` / `deps-modules/`.
- **Transcripted** ships a **committed** `fluidaudio-libs/libFluidAudioAll.a` (~54 MB) + `fluidaudio-modules/` with 18 prebuilt `.swiftmodule` bundles. FluidAudio version: **unconfirmed** — Open Question §6.2.

**Four strategy options** (from transcripted-inventory.md §11.7):

1. **Consolidate on Draft's `build-fluidaudio.sh` output, Transcripted's Xcode project links Draft's `deps-libs/`.** Transcripted removes its committed binaries, adds a build phase that runs `../Draft/build-fluidaudio.sh`, adjusts `LIBRARY_SEARCH_PATHS` and `SWIFT_INCLUDE_PATHS` to point at `../Draft/deps-libs/` and `../Draft/deps-modules/`. **One source of truth, ~54 MB deleted from Transcripted git.**
2. **Binary XCFramework.** Repackage the prebuilt into a `.xcframework`, reference via `.binaryTarget` in `Package.swift`. SPM-native, no unsafe flags. Requires a one-time packaging script and the xcframework committed (or hosted).
3. **Upstream SPM source dependency.** Both repos switch to `.package(url: "FluidInference/FluidAudio", from: "0.7.9")`. Gives up Draft's custom Swift 6.3 prebuild. Rebuild time jumps (FluidAudio is heavy).
4. **Keep separate.** Each repo has its own copy. Transcripted's artifact is committed; Draft's is generated. No consolidation. **Rejected** — duplicates ~54 MB of binaries and risks version drift.

**Our recommendation: Option 1 (Consolidate on Draft's build).** Justification:

- Draft already has the build pipeline working and documented (`build-fluidaudio.sh` + `build-deps.sh`).
- Draft's deps-libs is a *unified* lib (FluidAudio + mlx-swift-lm) — Transcripted doesn't need MLX, but a superset is fine because the linker only pulls in what's referenced. The ~54 MB overhead is already in Draft.
- Transcripted's committed binaries are a git-history smell (per its own `0908d05 chore: rebuild FluidAudio binaries for Swift 6.3 toolchain` commit — the team already rebuilds them periodically).
- One source of truth means version alignment is free.
- **Fallback if this doesn't work:** Option 2 (xcframework) — larger effort but still merge-compatible.

**Blocker:** requires that both repos agree on FluidAudio version (0.7.9 is Draft's; Transcripted's needs confirmation — see §6.2).

### 4.2 `Package.swift` for TranscriptedCore (to be created inside the Transcripted repo)

```swift
// swift-tools-version:5.9
// <transcripted-root>/Package.swift   (NEW — alongside the existing Xcode project)
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

Draft's `<draft-root>/build-deps.sh` (not shown in §1.6 of draft-inventory but assumed standard) builds `deps-libs/libDraftDeps.a` from the sidecar SPM workspace. We add TranscriptedCore to that workspace's dependency list (already shown in §2.2). **No new script required** — TranscriptedCore piggybacks on the existing Shim → release build pattern.

### 4.4 Info.plist and entitlements changes in Draft

Meeting capture requires additional permissions and strings. Edits to `<draft-root>/Info.plist`:

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

Edits to `<draft-root>/build.sh` entitlements heredoc (lines 45–58):

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

Draft's `build.sh` already bundles Parakeet TDT v3 CoreML models into `Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/` (see `build.sh:16–23`) and the EOU streaming model (`build.sh:25–39`). **Those are the same models Transcripted's `ParakeetService` expects** when `bundleProvider` resolves to `Bundle.main.resourcePath`. **Zero new model downloads required.**

**New model bundle needed for diarization:** Transcripted's `DiarizationService` uses PyAnnote offline models. Draft does not currently ship these. New `build.sh` step:

```bash
# Bundle PyAnnote diarization models (used by meeting mode)
PYANNOTE_SRC="$HOME/Library/Application Support/FluidAudio/Models/pyannote-segmentation-3.0"
if [ -d "$PYANNOTE_SRC" ]; then
    echo "Bundling PyAnnote diarization model..."
    mkdir -p "$APP_BUNDLE/Contents/Resources/pyannote-models"
    cp -R "$PYANNOTE_SRC" "$APP_BUNDLE/Contents/Resources/pyannote-models/"
else
    echo "PyAnnote model not found — meeting diarization will attempt runtime download"
fi
```

**Model size impact:** Parakeet (already bundled): ~600 MB. PyAnnote: ~17 MB. WeSpeaker embedding (for speaker DB): ~100 MB. **New bundle overhead ≈ 120 MB.** Not trivial, but acceptable.

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

**Directory boundary:** everything inside `<transcripted-root>/` EXCEPT `Transcripted/UI/`, `Transcripted/Design/`, `Transcripted/Onboarding/`, `TranscriptedTests/UI/`, and Tools/ packages (those stay untouched).

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

**Directory boundary:** `<draft-root>/.deps-build/Package.swift`, `<draft-root>/build.sh`, `<draft-root>/build-deps.sh`, `<draft-root>/Info.plist`, `<draft-root>/Sources/Meeting/` (new), `<draft-root>/Sources/Speech/AudioResampler.swift` (delete — replaced by Core's), `<draft-root>/Sources/DraftPaths.swift` (extend with `meetingSupportDir`).

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

**Directory boundary:** `<draft-root>/Sources/UI/MeetingOverlayController.swift` (new), `<draft-root>/Sources/UI/SpeakerNamingSheet.swift` (new), `<draft-root>/Sources/UI/MenuBarPanel.swift` (edit — add meetings section), `<draft-root>/Sources/HotkeyPreferences.swift` (edit — add meeting hotkey default), `<draft-root>/Sources/Capture/ContextCaptureEngine.swift` (edit — register third hotkey ID for meeting mode).

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

**Directory boundary:** `<draft-root>/build-fluidaudio.sh` (edit if needed), `<transcripted-root>/fluidaudio-libs/` (delete), `<transcripted-root>/fluidaudio-modules/` (delete), `<transcripted-root>/Transcripted.xcodeproj/project.pbxproj` (edit — repoint `LIBRARY_SEARCH_PATHS` + `SWIFT_INCLUDE_PATHS`), any new `build-transcripted.sh` helper at Transcripted root.

**Work items:**

1. Verify FluidAudio version alignment (§6.2). If versions differ, align on one before proceeding. If same, continue.
2. Build Draft's `deps-libs/libDraftDeps.a` via `build-fluidaudio.sh` + `build-deps.sh`.
3. Update Transcripted's `project.pbxproj` to:
   - Set `LIBRARY_SEARCH_PATHS` to `$(SRCROOT)/../Draft/deps-libs`.
   - Set `SWIFT_INCLUDE_PATHS` to include `$(SRCROOT)/../Draft/deps-modules` and its subdirs.
   - Change `OTHER_LDFLAGS` from `-lFluidAudioAll` to `-lDraftDeps`.
4. Verify Transcripted's Xcode build still produces a working app.
5. `git rm -r Transcripted/fluidaudio-libs/ Transcripted/fluidaudio-modules/`. Commit: `build: consolidate FluidAudio on Draft's deps-libs`.
6. Document the cross-repo dependency in `Transcripted/README.md` and/or `Transcripted/CLAUDE.md`.

**Dependencies:** independent of Lanes A, B, C in terms of file locks. Sequencing: Lane D can start anytime but must merge **after** Lane A (Lane A adds Core which will be built against Draft's deps) to avoid a broken intermediate state in Transcripted.

**Effort order of magnitude:** small if version alignment is clean, medium if it isn't. Biggest risk is Xcode caching — `DerivedData` can hold onto stale paths. Mitigation: clean-build verification in the acceptance criteria.

**Acceptance criteria:** Transcripted's Xcode app still builds and runs. `git ls-files Transcripted/ | grep fluidaudio` returns zero files. The new relative path works from both a fresh clone and inside an existing checkout.

### 5.5 Lane sequencing diagram

```
Milestone 0        Lane A                   Lane B                    Lane C                    Lane D
    │              core-extractor           draft-integrator          meeting-ui                build-plumbing
    │              │                         │                         │                         │
    ▼              ▼                         │                         │                         │
 macOS 26         Create TranscriptedCore    │                         │                         │
 availability     ┌─ step 1–5 (mod builds)   │                         │                         │
 audit            │                          │                         │                         │
 (1 day?)         ▼ step 5 complete ────────►│                         │                         │
                  ├─ step 6–7 (surgery)      ▼                         │                         │
                  │                          Update Package.swift      │                         │
                  │                          + build.sh                │                         │
                  │                          + Sources/Meeting/        │                         │
                  │                          └─ step 4 complete ──────►│                         │
                  ▼ step 9 (regression)      ▼                         ▼                         │
                  Transcripted app           Integration smoke         UI additions              │
                  still builds               passes                    + hotkey wiring           │
                  ▼                          ▼                         ▼                         │
                  step 10 tag ───────────────┼─────────────────────────┼─────────────────────────►│
                                                                                                  Consolidate
                                                                                                  FluidAudio,
                                                                                                  delete Transcripted
                                                                                                  fluidaudio-libs
                                                                                                  ▼
                                                                                                  Both apps build,
                                                                                                  end-to-end smoke
```

### 5.6 Cross-lane interface contracts

- **Core-extractor → draft-integrator:** delivered artifact is a compilable `Sources/TranscriptedCore/` module with public symbol signatures matching §1.4. Specifically: `CoreStoragePaths`, `ModelBundleProvider`, `TranscriptNotifier`, `Transcription`, `TranscriptionTaskManager`, `SpeakerDatabase`, `ParakeetService`, `DiarizationService` — all public, all initializable with `CoreStoragePaths` + `ModelBundleProvider` injection.
- **Draft-integrator → meeting-ui:** delivered artifact is a working `MeetingSessionController` with `@Published` state. Meeting-ui binds to its properties without needing to touch Core types directly (though it may still `import TranscriptedCore` for models like `DisplayStatus`, `SpeakerProfile`).
- **Build-plumbing → everyone:** deliverable is a green Transcripted build using Draft's deps-libs. Cross-lane dependency is minimal because the lanes operate on disjoint files.

---

## 6. Open Questions for Human Review

Judgment calls the human should confirm or resolve before Phase 2 starts.

### 6.1 macOS deployment target — the single biggest decision

**The constraint:** Draft ships `LSMinimumSystemVersion 14.0` and `-target arm64-apple-macos14.0`. Transcripted has 81 `@available(macOS 26.0, *)` gates across 58 files.

**The question:** Phase 2 Milestone 0 is an availability audit to determine how many of those 26-gates are actually load-bearing (i.e., API genuinely requires 26) vs conservative (chosen for UX/tooling reasons). Our strong expectation is that most Core candidate files will drop to 14.2 cleanly because:
- `ParakeetService` / `DiarizationService` / `SpeakerDatabase` already gate at `@available(macOS 14.0, *)` per inventory.
- Audio capture (Tier C) will need 14.2+ anyway because CoreAudio process taps are 14.2+.
- UI/Design/Onboarding files (which Draft doesn't consume) can keep their 26-gates.

**Human: do you accept this plan assuming the audit confirms most Core gates drop to 14.2?** If the audit surfaces a load-bearing 26-only API (e.g., Swift 6 concurrency strictness change or a new AV/CoreAudio API) in a Tier A/B file Draft needs, the merge scope shrinks to "everything except that file" OR Draft's deployment target rises (out of scope in our read).

### 6.2 FluidAudio version alignment

**The constraint:** Draft uses FluidAudio **0.7.9** (confirmed in `.deps-build/Package.swift`). Transcripted's committed `libFluidAudioAll.a` has an unknown version — transcripted-mapper is checking.

**The question:** if versions differ, which version wins? Our recommendation: align on **whichever version Transcripted's pipeline tests pass against**, since Transcripted has the more complex FluidAudio surface area (batch mode, offline diarization, WeSpeaker embeddings, OfflineDiarizerManager). Draft uses only streaming/EOU, which tends to be more stable across versions.

### 6.3 Does Draft reuse Transcripted's audio capture stack (Tier C) or keep its own?

**The constraint:** Draft has no dual-stream (mic + system audio) capture today. Transcripted's stack (~2,000 LOC, 8 files) is production-grade with sleep/wake handling, device recovery, energy VAD, watchdog, CoreAudio process taps. But it's AppKit-coupled and may carry `macOS 26.0` gates.

**Our recommendation:** Yes, Draft reuses Tier C. Rebuilding dual-stream capture from scratch in Draft would duplicate ~2,000 LOC for zero benefit. The AppKit coupling is fine (Draft is AppKit). The audit (§6.1) will tell us if the 26-gates block this.

**Human: confirm?**

### 6.4 Protocols/ wiring — pre-work or Phase 2 work?

**The constraint:** Transcripted's `Services/Protocols/` has 6 protocols defined but no concrete type formally conforms. `AppServices.swift` has a TODO to switch. If this wiring happens **before** Phase 2 (owned by the Transcripted team outside this merge effort), Draft can inject alternate implementations cleanly. If it happens **inside** Phase 2's `core-extractor` lane, the lane takes longer and the regression surface on Transcripted's app grows.

**Human: is the Transcripted team already planning to complete this TODO, or is it Phase 2 work?** Asked of transcripted-mapper via SendMessage while drafting this plan. Answer integrated in v2 if it arrives before commit.

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
- **Retiring Draft's Gemini-based drafting path in favor of MLX.** Draft currently drafts via Gemini 3 Flash cloud API per draft-inventory — the CLAUDE.md still describes the older MLX-only path. Reconciling the two is Draft-internal work, not merge work.
- **Swift 6 strict-concurrency adoption in Draft.** Draft compiles Swift 5 today; Core is Swift 6. Interop works. Upgrading Draft's source tree is separate.

---

## 7. Appendix — Quick Reference

### 7.1 File count summary

| Bucket | Count | LOC (approx) |
|---|---:|---:|
| Tier A (no surgery) | 24 | ~3,500 |
| Tier B (minor surgery) | 20 | ~7,000 |
| Tier C (audio capture, conditional) | 8 | ~2,000 |
| **TranscriptedCore total (A+B+C)** | **52** | **~12,500** |
| Stays in Transcripted app target | ~90 | ~18,000 |
| New files in Draft (Sources/Meeting/ + UI/) | ~10 | ~1,000 |

### 7.2 Cross-reference map

- Draft inventory: [draft-inventory.md](draft-inventory.md) — all 13 Draft Sources/ subdirs, entry points, hotkey system, paste mechanism, audio capture, STT, dependency management, CLI check, verdict per subsystem.
- Transcripted inventory: [transcripted-inventory.md](transcripted-inventory.md) — all 48 Core + 16 Services + 36 UI + 21 Design + 9 Onboarding files, speaker DB schema, YAML frontmatter, Tools packages, extraction blockers §11.1–11.12.
- This file: merge-plan.md — contract for Phase 2 execution.

### 7.3 Commit attribution

All commits on `feat/transcripted-merge` are authored as `r3dbars <r3dbars@users.noreply.github.com>` with a `Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>` trailer. Set via `git -c user.name=r3dbars -c user.email=...` on each commit — Phase 0 agents do not modify repo git config.
