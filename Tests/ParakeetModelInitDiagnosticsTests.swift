import AVFoundation
import Foundation

func testParakeetModelInitDiagnostics() {
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

    runSuite("ParakeetBundledModelLayoutPolicy prefers the current runtime bundle layout") {
        let root = makeBundledModelFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        writeBundledModelFixture(
            root: root,
            subdirectory: ParakeetBundledModelLayoutPolicy.runtime.subdirectory,
            checkFile: ParakeetBundledModelLayoutPolicy.runtime.checkFile
        )
        writeBundledModelFixture(
            root: root,
            subdirectory: ParakeetBundledModelLayoutPolicy.legacy.subdirectory,
            checkFile: ParakeetBundledModelLayoutPolicy.legacy.checkFile
        )

        let resolved = ParakeetBundledModelLayoutPolicy.resolveBundledModelPath(
            resourcePath: root.path
        )

        assertEqual(
            resolved?.lastPathComponent,
            ParakeetBundledModelLayoutPolicy.runtime.subdirectory,
            "the runtime bundle directory should win when both layouts exist"
        )
    }

    runSuite("ParakeetBundledModelLayoutPolicy falls back to the legacy bundle layout") {
        let root = makeBundledModelFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        writeBundledModelFixture(
            root: root,
            subdirectory: ParakeetBundledModelLayoutPolicy.legacy.subdirectory,
            checkFile: ParakeetBundledModelLayoutPolicy.legacy.checkFile
        )

        let resolved = ParakeetBundledModelLayoutPolicy.resolveBundledModelPath(
            resourcePath: root.path
        )

        assertEqual(
            resolved?.lastPathComponent,
            ParakeetBundledModelLayoutPolicy.legacy.subdirectory,
            "older bundled builds should still resolve their legacy Parakeet directory"
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
