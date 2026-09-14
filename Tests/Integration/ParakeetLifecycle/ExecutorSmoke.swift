import Foundation
import FluidAudio

@main struct ParakeetLifecycleExecutorSmoke {
    @MainActor static var assertions = 0
    @MainActor static func check(_ value: Bool, _ description: String) {
        guard value else { fatalError("FAIL: \(description)") }
        assertions += 1
    }
    @MainActor static func settle() async {
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    @MainActor static func waitFor(_ event: String) async {
        for _ in 0..<500 {
            if await FakeFluidAudio.shared.events.contains(event) { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        fatalError("Timed out waiting for \(event); events: inspect fake loader")
    }
    @MainActor static func finishLoad(_ variant: String, attempt: Int = 1) async {
        let fake = FakeFluidAudio.shared
        await waitFor("download-\(variant)#\(attempt)")
        await fake.release("download-\(variant)#\(attempt)")
        await waitFor("load-\(variant)#\(attempt)")
        await fake.release("load-\(variant)#\(attempt)")
        await waitFor("manager-\(variant)#\(attempt)")
        await fake.release("manager-\(variant)#\(attempt)")
    }
    @MainActor static func dispose(_ engine: ParakeetEngine) async {
        engine.cancelModelWork()
        engine.teardownModel()
        await engine.modelCleanupTask?.value
    }

    @MainActor static func joiningAndReadyPrefetch() async {
        await FakeFluidAudio.shared.reset()
        let engine = ParakeetEngine()
        let first = Task { await engine.initialize(variant: .v2) }
        await waitFor("download-v2#1")
        var secondFinished = false
        let second = Task {
            await engine.initialize(variant: .v2)
            secondFinished = true
        }
        await settle()
        check(!secondFinished, "same-variant initialization waits for the shared load")
        await finishLoad("v2")
        await first.value; await second.value
        check(secondFinished, "same-variant initialization resumes when the shared load completes")
        check(engine.isModelLoaded(for: .v2), "v2 ready")
        check(await FakeFluidAudio.shared.events.filter { $0.hasPrefix("download-") }.count == 1, "one shared download")
        let manager = engine.asrManager
        await engine.prefetchModelFilesIfNeeded(variant: .v3)
        check(engine.asrManager === manager && engine.modelVariant == .v2, "prefetch preserves idle loaded manager")
        check(engine.modelDownloadState == .ready, "prefetch preserves readiness")
        await dispose(engine)
    }

    @MainActor static func prefetchJoinAndFailedRetry() async {
        let fake = FakeFluidAudio.shared
        await fake.reset()
        let engine = ParakeetEngine()
        let prefetch = Task { await engine.prefetchModelFilesIfNeeded(variant: .v2) }
        await waitFor("download-v2#1")
        await fake.progress("download-v2#1", 0.8)
        await settle()
        check(engine.modelDownloadState == .downloading(progress: 0.2), "current progress reaches published state")
        let initialization = Task { await engine.initialize(variant: .v2) }
        await settle()
        check(await fake.events == ["download-v2#1"], "initialize joins existing prefetch")
        await fake.release("download-v2#1", fail: true)
        await prefetch.value; await initialization.value
        if case .failed = engine.modelDownloadState { check(true, "current failure is visible") }
        else { check(false, "current download error must publish failure") }
        check(engine.modelFilePrefetchTask == nil && engine.modelInitializationTask == nil, "failed work relinquishes task ownership")
        let retry = Task { await engine.initialize(variant: .v2) }
        await waitFor("download-v2#2"); await fake.release("download-v2#2")
        await waitFor("load-v2#1"); await fake.release("load-v2#1")
        await waitFor("manager-v2#1"); await fake.release("manager-v2#1")
        await retry.value
        check(engine.isModelLoaded(for: .v2), "retry succeeds after current error")
        await dispose(engine)
    }

    @MainActor static func rapidSwitchAndStaleProgress() async {
        let fake = FakeFluidAudio.shared
        await fake.reset()
        let engine = ParakeetEngine()
        let old = Task { await engine.initialize(variant: .v3) }
        await waitFor("download-v3#1")
        let middle = Task { await engine.initialize(variant: .v2) }
        await settle()
        check(engine.modelVariant == .v2, "middle selection installed")
        let latest = Task { await engine.initialize(variant: .v3) }
        await settle()
        check(engine.modelVariant == .v3, "latest selection installed")
        check(await fake.events == ["download-v3#1"], "successor waits for canceled native work")
        let state = engine.modelDownloadState
        await fake.progress("download-v3#1", 0.8)
        await settle()
        check(engine.modelDownloadState == state, "same-version stale progress rejected by generation")
        await fake.release("download-v3#1")
        await waitFor("download-v3#2")
        check(!(await fake.events.contains("load-v3#1")), "stale download success cannot load models")
        await fake.release("download-v3#2")
        await waitFor("load-v3#1"); await fake.release("load-v3#1")
        await waitFor("manager-v3#1"); await fake.release("manager-v3#1")
        await old.value; await middle.value; await latest.value
        check(engine.isModelLoaded(for: .v3), "latest v3 ready")
        check(!(await fake.events.contains("download-v2#1")), "superseded middle selection never allocates")
        await dispose(engine)
    }

    @MainActor static func staleManagerResult(fail: Bool) async {
        let fake = FakeFluidAudio.shared
        await fake.reset()
        let engine = ParakeetEngine()
        let first = Task { await engine.initialize(variant: .v3) }
        await waitFor("download-v3#1"); await fake.release("download-v3#1")
        await waitFor("load-v3#1"); await fake.release("load-v3#1")
        await waitFor("manager-v3#1")
        let next = Task { await engine.initialize(variant: .v2) }
        await settle()
        check(!(await fake.events.contains("download-v2#1")), "native manager initialization drains before replacement")
        await fake.release("manager-v3#1", fail: fail)
        await waitFor("download-v2#1")
        let events = await fake.events
        check(events.firstIndex(of: "cleanup-v3")! < events.firstIndex(of: "download-v2#1")!, "stale manager cleaned before next allocation")
        check(!engine.asrManagerReady && engine.loadedModelVariant == nil, "stale success/error cannot publish readiness")
        check(engine.modelDownloadState == .downloading(progress: 0), "stale error cannot replace successor state")
        await finishLoad("v2")
        await first.value; await next.value
        check(engine.isModelLoaded(for: .v2), "replacement ready after stale manager result")
        await dispose(engine)
    }

    @MainActor static func watchdogRetry() async {
        let fake = FakeFluidAudio.shared
        await fake.reset()
        let engine = ParakeetEngine()
        let first = Task { await engine.initialize(variant: .v2) }
        await waitFor("download-v2#1")
        engine.scheduleModelDownloadWatchdog(
            generation: engine.modelDownloadAttemptGeneration,
            progressTracker: ParakeetModelDownloadProgressTracker(initialActivityUptime: ProcessInfo.processInfo.systemUptime - 301)
        )
        await settle()
        if case .failed = engine.modelDownloadState { check(true, "watchdog failed stalled download") }
        else { check(false, "watchdog must fail stalled download") }
        check(engine.modelInitializationTask == nil && engine.modelFilePrefetchTask == nil, "watchdog cancels task ownership")
        let retry = Task { await engine.initialize(variant: .v2) }
        await settle()
        check(await fake.events == ["download-v2#1"], "retry waits for stalled native task")
        await fake.release("download-v2#1", fail: true)
        await waitFor("download-v2#2")
        await fake.progress("download-v2#1", 1)
        await settle()
        check(engine.modelDownloadState == .downloading(progress: 0), "stalled callback cannot overwrite retry")
        await fake.release("download-v2#2")
        await waitFor("load-v2#1"); await fake.release("load-v2#1")
        await waitFor("manager-v2#1"); await fake.release("manager-v2#1")
        await first.value; await retry.value
        check(engine.isModelLoaded(for: .v2), "retry succeeds after watchdog")
        await dispose(engine)
    }

    @MainActor static func activeInferenceTeardown() async {
        let fake = FakeFluidAudio.shared
        await fake.reset()
        let engine = ParakeetEngine()
        let load = Task { await engine.initialize(variant: .v3) }
        await finishLoad("v3"); await load.value
        let manager = engine.asrManager
        for kind in 0..<3 {
            engine.isRecording = kind == 0
            engine.isTranscribing = kind == 1
            engine.hasActiveASRWork = kind == 2
            await engine.initialize(variant: .v2)
            check(engine.modelVariant == .v3 && engine.isModelLoaded(for: .v3), "active work rejects selection before mutation")
            await engine.prefetchModelFilesIfNeeded(variant: .v2)
            check(engine.asrManager === manager, "active work rejects prefetch")
        }
        engine.teardownModel()
        check(engine.asrManager === manager && engine.modelTeardownGate.isPending, "teardown retains actively used manager")
        check(!engine.asrManagerReady && engine.loadedModelVariant == nil, "teardown clears readiness immediately")
        let reload = Task { await engine.initialize(variant: .v3) }
        await settle()
        check(!(await fake.events.contains("cleanup-v3")), "no cleanup while inference active")
        await fake.delayNextCleanup()
        engine.hasActiveASRWork = false
        engine.finishDeferredModelTeardownIfIdle()
        await waitFor("cleanup-drain-v3#1")
        await settle()
        check(!(await fake.events.contains("load-v3#2")), "replacement waits for actual native cleanup completion")
        await fake.release("cleanup-drain-v3#1")
        // Reuses its prefetched path, so only native load/manager repeat.
        await waitFor("load-v3#2")
        let events = await fake.events
        check(events.firstIndex(of: "cleanup-v3")! < events.firstIndex(of: "load-v3#2")!, "cleanup completes before reallocation")
        await fake.release("load-v3#2")
        await waitFor("manager-v3#2"); await fake.release("manager-v3#2")
        await reload.value
        check(engine.isModelLoaded(for: .v3), "reload resumes when inference drains")
        await dispose(engine)
    }

    @MainActor static func main() async {
        // A hard process deadline also covers accidental cycles in task.value.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            fputs("FAIL: lifecycle executor exceeded 30 second deadline\n", stderr)
            exit(1)
        }
        await joiningAndReadyPrefetch()
        await prefetchJoinAndFailedRetry()
        await rapidSwitchAndStaleProgress()
        await staleManagerResult(fail: false)
        await staleManagerResult(fail: true)
        await watchdogRetry()
        await activeInferenceTeardown()
        print("PASS: production Parakeet lifecycle executor (\(assertions) assertions)")
    }
}
