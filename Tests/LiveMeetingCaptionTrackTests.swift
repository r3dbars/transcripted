import Foundation

@MainActor
func testLiveMeetingCaptionTrack() async {
    runSuite("Mic-only captions never construct an unused recognizer") {
        var created = 0
        let micOnly = LiveMeetingCaptionTrackSet(capturesSystemAudio: false) {
            created += 1
            return created
        }
        assertEqual(created, 1, "only the captured microphone gets a recognizer")
        assertEqual(micOnly.microphone, 1)
        assertTrue(micOnly.system == nil)

        let dual = LiveMeetingCaptionTrackSet(capturesSystemAudio: true) {
            created += 1
            return created
        }
        assertEqual(dual.microphone, 2)
        assertEqual(dual.system, 3, "system audio has its own decoder state")
    }

    await runSuite("An unavailable caption model releases resources from its partial load") {
        let model = CaptionTestRecognizer(failLoad: true)
        let track = LiveMeetingCaptionTrack(recognizer: model)
        let result = await track.load()
        assertEqual(result, .failed)
        let calls = await model.calls
        let retained = await model.retainsModels
        assertEqual(calls, ["load", "cleanup"])
        assertFalse(retained, "the app-lifetime dictation track must not hold a failed load")
    }

    await runSuite("A cancelled caption load releases models before warmup") {
        let entered = CaptionTestSignal()
        let release = CaptionTestSignal()
        let model = CaptionTestRecognizer()
        let track = LiveMeetingCaptionTrack(recognizer: model)
        let loading = Task {
            await track.load(beforeWarmup: {
                await entered.signal()
                await release.wait()
            })
        }
        await entered.wait()
        loading.cancel()
        await release.signal()
        let result = await loading.value
        let calls = await model.calls
        assertEqual(result, .failed)
        assertEqual(calls, ["load", "cleanup"], "cancelled loads neither infer nor retain their models")
    }

    // Release can land during the normal feed, during the first flush
    // prediction, or just before reset. In every case the remaining tail
    // waits intact, then commits once in the same sequence.
    for blockedAfter in 1...3 {
        await runSuite("Final transcription owns inference after caption operation \(blockedAfter)") {
            let permission = CaptionTestPermission()
            let events = CaptionTestEvents()
            let model = CaptionTestRecognizer { step in
                if step == blockedAfter { await permission.block() }
            }
            let track = LiveMeetingCaptionTrack(recognizer: model)
            track.queue.append([Float](repeating: 0.1, count: 5_120))
            await track.start(shouldYield: { await permission.shouldYield() }) { event, sequence in
                await events.append(event, sequence: sequence)
            }
            await permission.observed.wait()
            let blockedCalls = await model.calls
            let blockedEvents = await events.values
            assertEqual(blockedCalls, Array(["process:5120", "process:5120", "process:4960"].prefix(blockedAfter)),
                        "no extra prediction or reset is admitted while the final pass owns inference")
            assertTrue(blockedEvents.isEmpty, "a deferred tail is not committed early")

            await permission.unblock()
            await events.received.wait()
            let finishedCalls = await model.calls
            let delivered = await events.values
            assertEqual(finishedCalls, ["process:5120", "process:5120", "process:4960", "reset"])
            assertEqual(delivered.map(\.event), [.utterance("hello there friend")], "the full provisional tail survives the yield")
            assertEqual(delivered.map(\.sequence), [1], "one ordered commit")
            await track.stop()
        }
    }

    await runSuite("Cancelling a deferred caption flush does not reset during final transcription") {
        let permission = CaptionTestPermission()
        let model = CaptionTestRecognizer { step in
            if step == 2 { await permission.block() }
        }
        let track = LiveMeetingCaptionTrack(recognizer: model)
        track.queue.append([Float](repeating: 0.1, count: 5_120))
        await track.start(shouldYield: { await permission.shouldYield() }) { _, _ in }
        await permission.observed.wait()
        let pause = Task { await track.pause() }
        await permission.cancelled.wait()
        await permission.unblock()
        await pause.value
        let pausedCalls = await model.calls
        assertEqual(pausedCalls, ["process:5120", "process:5120"], "pause cancels the tail and allocates no reset caches")

        let nextPermission = CaptionTestPermission()
        await nextPermission.block()
        await track.start(shouldYield: { await nextPermission.shouldYield() }) { _, _ in }
        await nextPermission.observed.wait()
        let waitingCalls = await model.calls
        assertEqual(waitingCalls, pausedCalls, "the next take cannot reset while the final pass is active")
        await nextPermission.unblock()
        await model.resetSeen.wait()
        let nextCalls = await model.calls
        assertEqual(nextCalls, pausedCalls + ["reset"], "one fresh decoder after the final pass completes")
        await track.pause()
        await track.stop()
    }

    for failedPrediction in 1...2 {
        await runSuite("Failed caption prediction \(failedPrediction) resets its retained input before retrying") {
            let permission = CaptionTestPermission()
            let model = BufferedCaptionTestRecognizer(failedPrediction: failedPrediction) {
                await permission.block()
            }
            let track = LiveMeetingCaptionTrack(recognizer: model)
            track.queue.append([Float](repeating: 0.1, count: 10_240))
            await track.start(shouldYield: { await permission.shouldYield() }) { _, _ in }
            await permission.observed.wait()
            let retained = await model.bufferedSamples
            let predictions = await model.predictions
            assertTrue(retained >= 10_080, "the fake preserves failed input like FluidAudio")
            assertEqual(predictions, failedPrediction)
            await permission.unblock()
            await model.resetSeen.wait()
            let finalPredictions = await model.predictions
            let finalBuffer = await model.bufferedSamples
            assertEqual(finalPredictions, failedPrediction, "failure cleanup must not append a flush to unshifted input")
            assertEqual(finalBuffer, 0, "the next feed starts with clean decoder input")
            await track.stop()
        }
    }

    await runSuite("A late native prediction cannot consume the next take's PCM or publish stale words") {
        let hold = CaptionTestProcessHold()
        let oldEvents = CaptionTestEvents()
        let model = CaptionTestRecognizer { step in
            if step == 1 { await hold.run() }
        }
        let track = LiveMeetingCaptionTrack(recognizer: model)
        track.queue.append([Float](repeating: 0.1, count: 5_120))
        await track.start(shouldYield: { false }) { event, sequence in
            await oldEvents.append(event, sequence: sequence)
        }
        await hold.entered.wait()
        let pause = Task { await track.pause() }
        await hold.cancelled.wait()
        track.queue.removeAll()
        track.queue.append([Float](repeating: 0.2, count: 5_120))
        await hold.release.signal()
        await pause.value
        let stale = await oldEvents.values
        assertTrue(stale.isEmpty)

        let nextEvents = CaptionTestEvents()
        await track.start(shouldYield: { false }) { event, sequence in
            await nextEvents.append(event, sequence: sequence)
        }
        await nextEvents.received.wait()
        let calls = await model.calls
        let firstSamples = await model.firstSamples
        assertEqual(calls, ["process:5120", "reset", "process:5120"], "reset precedes the next take's first feed")
        assertEqual(firstSamples, [Float(0.1), Float(0.2)], "the paused predecessor leaves the new PCM queued")
        await track.pause()
        await track.stop()
    }
}

private actor CaptionTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor CaptionTestPermission {
    nonisolated let observed = CaptionTestSignal()
    nonisolated let cancelled = CaptionTestSignal()
    private let released = CaptionTestSignal()
    private var blocked = false
    func block() { blocked = true }
    func unblock() async { blocked = false; await released.signal() }
    func shouldYield() async -> Bool {
        if blocked {
            await observed.signal()
            await withTaskCancellationHandler {
                await released.wait()
            } onCancel: { [cancelled] in
                Task { await cancelled.signal() }
            }
        }
        return blocked
    }
}

private actor CaptionTestProcessHold {
    nonisolated let entered = CaptionTestSignal()
    nonisolated let cancelled = CaptionTestSignal()
    nonisolated let release = CaptionTestSignal()
    func run() async {
        await entered.signal()
        await withTaskCancellationHandler {
            // A native prediction may ignore cancellation until it returns.
            await release.wait()
        } onCancel: { [cancelled] in
            Task { await cancelled.signal() }
        }
    }
}

private actor CaptionTestEvents {
    struct Entry: Sendable {
        let event: LiveMeetingCaptionTrack.Event
        let sequence: Int
    }
    nonisolated let received = CaptionTestSignal()
    private(set) var values: [Entry] = []
    func append(_ event: LiveMeetingCaptionTrack.Event, sequence: Int) async {
        values.append(Entry(event: event, sequence: sequence))
        await received.signal()
    }
}

private actor CaptionTestRecognizer: LiveMeetingCaptionRecognizing {
    private struct LoadFailure: Error {}
    nonisolated let resetSeen = CaptionTestSignal()
    private(set) var calls: [String] = []
    private(set) var firstSamples: [Float] = []
    private(set) var retainsModels = false
    private var step = 0
    private let failLoad: Bool
    private let afterProcess: @Sendable (Int) async -> Void
    init(failLoad: Bool = false, afterProcess: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.failLoad = failLoad
        self.afterProcess = afterProcess
    }
    func loadModels() throws {
        calls.append("load")
        retainsModels = true
        if failLoad { throw LoadFailure() }
    }
    func process(_ samples: [Float]) async {
        calls.append("process:\(samples.count)")
        firstSamples.append(samples.first ?? 0)
        step += 1
        await afterProcess(step)
    }
    func partialTranscript() -> String { ["", "hello", "hello there", "hello there friend"][min(step, 3)] }
    func endOfUtteranceDetected() -> Bool { step == 1 }
    func reset() async { calls.append("reset"); await resetSeen.signal() }
    func cleanup() { calls.append("cleanup"); retainsModels = false }
}

/// Models the dependency's important failure semantics: failed input is not
/// shifted, so blindly appending again can run multiple predictions at once.
private actor BufferedCaptionTestRecognizer: LiveMeetingCaptionRecognizing {
    private struct PredictionFailure: Error {}
    nonisolated let resetSeen = CaptionTestSignal()
    private(set) var bufferedSamples = 0
    private(set) var predictions = 0
    private var successfulPredictions = 0
    private let failedPrediction: Int
    private let afterFailure: @Sendable () async -> Void
    init(failedPrediction: Int, afterFailure: @escaping @Sendable () async -> Void) {
        self.failedPrediction = failedPrediction
        self.afterFailure = afterFailure
    }
    func loadModels() {}
    func process(_ samples: [Float]) async throws {
        bufferedSamples += samples.count
        while bufferedSamples >= 10_080 {
            predictions += 1
            if predictions == failedPrediction {
                await afterFailure()
                throw PredictionFailure()
            }
            successfulPredictions += 1
            bufferedSamples -= 5_120
        }
    }
    func partialTranscript() -> String { successfulPredictions > 0 ? "heard words" : "" }
    func endOfUtteranceDetected() -> Bool { successfulPredictions > 0 }
    func reset() async { bufferedSamples = 0; successfulPredictions = 0; await resetSeen.signal() }
    func cleanup() { bufferedSamples = 0 }
}
