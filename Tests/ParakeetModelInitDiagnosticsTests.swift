import AVFoundation
import Foundation

private actor ParakeetModelDrainTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor ParakeetModelDrainTestTrace {
    var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

func testParakeetModelInitDiagnostics() async {
    await testParakeetTeardownWaiting()
    runSuite("Variant admission preserves active runtime and network-only prefetch") {
        for current in ParakeetModelVariant.allCases {
            for requested in ParakeetModelVariant.allCases {
                assertEqual(ParakeetModelSelectionPolicy.canSelect(
                    requested, current: current, hasActiveWork: true
                ), requested == current, "active work may join only its current variant")
                assertTrue(ParakeetModelSelectionPolicy.canSelect(
                    requested, current: current, hasActiveWork: false
                ))
            }
        }
        assertFalse(ParakeetModelSelectionPolicy.canPrefetch(hasManager: true, hasActiveWork: false),
            "even an idle loaded manager must not be unloaded by prefetch")
        assertFalse(ParakeetModelSelectionPolicy.canPrefetch(hasManager: false, hasActiveWork: true))
        assertFalse(ParakeetModelSelectionPolicy.canPrefetch(hasManager: true, hasActiveWork: true))
        assertTrue(ParakeetModelSelectionPolicy.canPrefetch(hasManager: false, hasActiveWork: false))
    }
    let started = ParakeetModelDrainTestGate()
    let release = ParakeetModelDrainTestGate()
    let trace = ParakeetModelDrainTestTrace()
    let oldLoad = Task {
        await started.open()
        // Like a native load, this continuation deliberately ignores cancellation.
        await release.wait()
        await trace.record("old manager cleaned")
    }
    await started.wait()
    oldLoad.cancel()
    let cleanup = Task { await trace.record("previous cleanup") }
    let drain = ParakeetModelTaskDrain.draining(oldLoad, after: cleanup)
    let successor = Task {
        await drain.value
        await trace.record("new load")
    }
    await cleanup.value
    let beforeRelease = await trace.events
    await release.open()
    await successor.value
    let afterRelease = await trace.events
    runSuite("Canceled native model work drains before successor initialization") {
        assertEqual(beforeRelease, ["previous cleanup"])
        assertEqual(afterRelease, ["previous cleanup", "old manager cleaned", "new load"])
        assertTrue(oldLoad.isCancelled, "the drain waits even when cancellation was already requested")
    }

    runSuite("Model work tokens reject stale success, failure and progress after switching back") {
        let oldV3 = ParakeetModelWorkToken(variant: .v3, generation: 1)
        let v2 = ParakeetModelWorkToken(variant: .v2, generation: 2)
        let newV3 = ParakeetModelWorkToken(variant: .v3, generation: 3)
        assertFalse(oldV3.isCurrent(variant: .v2, generation: 1))
        assertFalse(oldV3.isCurrent(variant: .v3, generation: 3))
        assertFalse(v2.isCurrent(variant: .v3, generation: 3))
        assertTrue(newV3.isCurrent(variant: .v3, generation: 3))
        assertFalse(newV3.isCurrent(variant: .v3, generation: 4), "cancellation/retry invalidates even the same model")
    }

    runSuite("Parakeet bundles must contain every required file of the requested version") {
        for variant in ParakeetModelVariant.allCases {
            let prefix = "/fixture/parakeet-models/\(variant.directoryName)/"
            let files = Set((variant.requiredModelDirectoryNames.map { "\($0)/coremldata.bin" }
                + variant.requiredFileNames).map { prefix + $0 })
            assertNotNil(ParakeetBundledModelLayoutPolicy.resolveBundledModelPath(
                resourcePath: "/fixture", variant: variant, fileExists: { files.contains($0) }
            ))
            let other: ParakeetModelVariant = variant == .v2 ? .v3 : .v2
            assertNil(ParakeetBundledModelLayoutPolicy.resolveBundledModelPath(
                resourcePath: "/fixture", variant: other, fileExists: { files.contains($0) }
            ))
            for missing in files {
                assertNil(ParakeetBundledModelLayoutPolicy.resolveBundledModelPath(
                    resourcePath: "/fixture", variant: variant,
                    fileExists: { $0 != missing && files.contains($0) }
                ))
            }
        }
    }

    runSuite("ParakeetModelInitDiagnostics.failureContext captures safe initialization details") {
        let context = ParakeetModelInitDiagnostics.failureContext(
            stage: .downloadModels,
            loadSource: .download,
            bundledModelPresent: false,
            microphoneStatus: .denied
        )

        assertEqual(context["failure_stage"], "download_models", "failure stage should explain where initialization stopped")
        assertEqual(context["load_source"], "download", "load source should distinguish bundle from runtime download")
        assertEqual(context["model_bundle_present"], "false", "bundle presence should be explicit for packaging/debugging issues")
        assertEqual(context["mic_status"], "denied", "microphone status should be preserved in a sanitized form")
    }

    runSuite("ParakeetModelDownloadProgressTracker maps component downloads monotonically") {
        let tracker = ParakeetModelDownloadProgressTracker(
            stageCount: 4,
            initialActivityUptime: 0
        )

        assertEqual(
            tracker.overallProgress(rawProgress: 0, beginsNewStage: true),
            0,
            "the first listing callback should start at zero"
        )
        assertEqual(
            tracker.overallProgress(rawProgress: 0.6, beginsNewStage: false),
            0.6 / 4.0,
            "the first component should occupy one fourth of overall progress"
        )
        assertEqual(
            tracker.overallProgress(rawProgress: 1, beginsNewStage: false),
            1.0 / 4.0,
            "completing the first component should publish one-fourth progress"
        )
        assertEqual(
            tracker.overallProgress(rawProgress: 0.5, beginsNewStage: false),
            0.375,
            "a reset after completion should begin the next FluidAudio component"
        )
        assertEqual(
            tracker.overallProgress(rawProgress: 1, beginsNewStage: false),
            0.5,
            "completing the second component should publish half progress"
        )
        assertEqual(
            tracker.overallProgress(rawProgress: 0.5, beginsNewStage: false),
            0.625,
            "the third component should advance without another listing callback"
        )
        assertEqual(
            tracker.overallProgress(rawProgress: 1, beginsNewStage: false),
            0.75,
            "completing the third component should publish three-fourths progress"
        )
        assertEqual(
            tracker.overallProgress(rawProgress: 0.5, beginsNewStage: false),
            0.875,
            "the fourth component should advance without another listing callback"
        )
        assertEqual(
            tracker.overallProgress(rawProgress: 1, beginsNewStage: false),
            1,
            "completing all four components should publish full progress"
        )
    }

    runSuite("ParakeetModelDownloadAttemptPolicy only times out the current active download") {
        assertTrue(
            ParakeetModelDownloadAttemptPolicy.shouldTimeOut(
                expectedGeneration: 4,
                currentGeneration: 4,
                hasActiveTask: true,
                taskCancelled: false
            ),
            "a current download with an active watchdog should fail after no progress"
        )
        assertFalse(
            ParakeetModelDownloadAttemptPolicy.shouldTimeOut(
                expectedGeneration: 3,
                currentGeneration: 4,
                hasActiveTask: true,
                taskCancelled: false
            ),
            "a stale watchdog must not fail a newer download"
        )
        assertFalse(
            ParakeetModelDownloadAttemptPolicy.shouldTimeOut(
                expectedGeneration: 4,
                currentGeneration: 4,
                hasActiveTask: false,
                taskCancelled: false
            ),
            "a download without an active task must not be failed"
        )
    }

    runSuite("ParakeetModelDownloadAttemptPolicy rejects late completion from a timed-out attempt") {
        assertFalse(
            ParakeetModelDownloadAttemptPolicy.isCurrent(
                expectedGeneration: 4,
                currentGeneration: 5
            ),
            "a timed-out attempt must not clear or overwrite a newer retry"
        )
        assertTrue(
            ParakeetModelDownloadAttemptPolicy.isCurrent(
                expectedGeneration: 5,
                currentGeneration: 5
            ),
            "the active retry should own completion-side state changes"
        )
    }

    runSuite("ParakeetModelDownloadProgressTracker bounds UI callback volume") {
        let tracker = ParakeetModelDownloadProgressTracker(
            stageCount: 1,
            initialActivityUptime: 0
        )

        assertEqual(
            tracker.progressToPublish(
                rawProgress: 0,
                beginsNewStage: true,
                activityUptime: 0
            ),
            0,
            "the initial download state should publish"
        )
        assertNil(
            tracker.progressToPublish(
                rawProgress: 0.001,
                beginsNewStage: false,
                activityUptime: 240
            ),
            "tiny byte-level updates should stay off the main actor"
        )
        assertEqual(
            tracker.remainingNoProgressInterval(timeout: 300, nowUptime: 300),
            240,
            "a throttled UI callback should still refresh download liveness"
        )
        assertEqual(
            tracker.progressToPublish(
                rawProgress: 0.003,
                beginsNewStage: false,
                activityUptime: 480
            ),
            0.003,
            "meaningful progress should refresh the UI and stall watchdog"
        )
        assertEqual(
            tracker.remainingNoProgressInterval(timeout: 300, nowUptime: 780),
            0,
            "the watchdog should expire only after the full quiet interval"
        )
    }

    runSuite("ParakeetBundledModelLayoutPolicy resolves the current runtime bundle layout") {
        let root = makeBundledModelFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        writeBundledModelFixture(
            root: root,
            subdirectory: ParakeetBundledModelLayoutPolicy.runtime.subdirectory,
            checkFile: ParakeetBundledModelLayoutPolicy.runtime.checkFile
        )
        let modelRoot = root.appendingPathComponent("parakeet-models/\(ParakeetModelVariant.v3.directoryName)")
        for file in ParakeetModelVariant.v3.requiredModelDirectoryNames.map({ "\($0)/coremldata.bin" })
            + ParakeetModelVariant.v3.requiredFileNames {
            let url = modelRoot.appendingPathComponent(file)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data([0]).write(to: url)
        }

        let resolved = ParakeetBundledModelLayoutPolicy.resolveBundledModelPath(
            resourcePath: root.path
        )

        assertEqual(
            resolved?.lastPathComponent,
            ParakeetBundledModelLayoutPolicy.runtime.subdirectory,
            "the packaged runtime bundle directory should resolve as bundled"
        )
    }

    runSuite("ParakeetBundledModelLayoutPolicy ignores legacy-only bundled layouts") {
        let root = makeBundledModelFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        writeBundledModelFixture(
            root: root,
            subdirectory: "parakeet-tdt-0.6b-v3-coreml",
            checkFile: "Encoder.mlmodelc"
        )

        let resolved = ParakeetBundledModelLayoutPolicy.resolveBundledModelPath(
            resourcePath: root.path
        )

        assertNil(
            resolved,
            "legacy-only bundle directories are not loadable through the current FluidAudio runtime layout"
        )
    }

    runSuite("ParakeetBundledModelLayoutPolicy ignores incomplete runtime bundles") {
        let root = makeBundledModelFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        writeBundledModelFixture(
            root: root,
            subdirectory: ParakeetBundledModelLayoutPolicy.runtime.subdirectory,
            checkFile: "Encoder.mlmodelc"
        )

        let resolved = ParakeetBundledModelLayoutPolicy.resolveBundledModelPath(
            resourcePath: root.path
        )

        assertNil(
            resolved,
            "the runtime bundle should not count as present unless JointDecisionv3.mlmodelc exists"
        )
    }
}

@MainActor
private func testParakeetTeardownWaiting() async {
    let gate = ParakeetModelTeardownGate()
    let initiallyIdle = await gate.wait()
    gate.begin()
    let canceled = Task { @MainActor in await gate.wait() }
    await Task.yield()
    canceled.cancel()
    let canceledResult = await canceled.value
    let remainedPending = gate.isPending
    let successor = Task { @MainActor in await gate.wait() }
    let secondSuccessor = Task { @MainActor in await gate.wait() }
    await Task.yield()
    gate.finish()
    let successorResult = await successor.value
    let secondResult = await secondSuccessor.value
    gate.finish() // Repeated completion must never double-resume a waiter.

    gate.begin()
    let canceledBeforeStart = Task { @MainActor in await gate.wait() }
    canceledBeforeStart.cancel()
    let preCanceledResult = await canceledBeforeStart.value
    let retryStillPending = gate.isPending
    gate.finish()
    let idleAgain = await gate.wait()

    runSuite("Teardown waits are event-driven, reusable, and independently cancellable") {
        assertTrue(initiallyIdle)
        assertFalse(canceledResult)
        assertTrue(remainedPending, "canceling initialization must not release native decoder ownership")
        assertTrue(successorResult)
        assertTrue(secondResult, "completion resumes every still-live waiter")
        assertFalse(preCanceledResult)
        assertTrue(retryStillPending)
        assertTrue(idleAgain)
        assertFalse(gate.isPending)
    }
}

private func makeBundledModelFixtureRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ParakeetBundledModelLayoutPolicy-\(UUID().uuidString)", isDirectory: true)
    let resources = root.appendingPathComponent("parakeet-models", isDirectory: true)
    try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    return root
}

private func writeBundledModelFixture(root: URL, subdirectory: String, checkFile: String) {
    let directory = root
        .appendingPathComponent("parakeet-models", isDirectory: true)
        .appendingPathComponent(subdirectory, isDirectory: true)
        .appendingPathComponent(checkFile, isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}
