import Foundation

// Synthetic integration of the production admission gate, analysis policy and
// real private WAV store. The CoreAudio/AppKit controller and ASR model are not
// instantiated here; a blocked checkpoint and model outcome are injected.
func testDictationStoppedAudioInterleaving() async {
    for modelOutcome: SyntheticStoppedAudioModelOutcome in [.text, .emptyRetry, .errorRetry] {
        await runSuite("Two Stops during a blocked WAV checkpoint, model outcome \(modelOutcome)") {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DictationStoppedAudioInterleaving-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let sessionID = UUID()
            let checkpoint = SyntheticBlockedCheckpoint()
            let finalizer = SyntheticStoppedAudioFinalizer(
                checkpoint: checkpoint,
                directory: directory,
                modelOutcome: modelOutcome
            )

            let firstStop = Task { await finalizer.stop(sessionID: sessionID) }
            await checkpoint.waitUntilEntered()
            let repeatedStop = Task { await finalizer.stop(sessionID: sessionID) }
            let repeatedOutcome = await repeatedStop.value
            assertEqual(repeatedOutcome, .ignored, "a second Stop must return while the first WAV write is blocked")
            let beforeRelease = await finalizer.counts()
            assertEqual(beforeRelease.persisted, 0, "the test barrier must actually hold the first checkpoint")
            await checkpoint.release()

            let firstOutcome = await firstStop.value
            let counts = await finalizer.counts()
            assertEqual(counts.persisted, 1, "only the admitted Stop may persist a WAV")
            assertEqual(counts.terminalPublications, 1, "only the admitted Stop may publish a terminal outcome")
            let pending = DictationStoppedAudioRecoveryStore.pendingRecoveries(directory: directory)
            if modelOutcome == .text {
                assertEqual(firstOutcome, .delivered, "a decoded transcript can publish one delivery")
                assertEqual(counts.deliveries, 1, "the repeated Stop cannot deliver duplicate text")
                assertTrue(pending.isEmpty, "a successful synthetic transcript save retires its WAV")
            } else {
                assertEqual(firstOutcome, .recoveryNeeded, "empty/error retry with measurable signal must not be called silence")
                assertEqual(counts.deliveries, 0, "undecoded audio must not claim a paste/copy delivery")
                assertEqual(pending.count, 1, "the one durable recovery must remain discoverable after empty inference")
                assertTrue(
                    pending.first.map { FileManager.default.fileExists(atPath: $0.url.path) } == true,
                    "the retained WAV must still exist for Home -> Import Audio"
                )
            }
        }
    }
}

private enum SyntheticStoppedAudioModelOutcome: Sendable, Equatable {
    case text
    case emptyRetry
    case errorRetry
}

private enum SyntheticStoppedAudioStopOutcome: Sendable, Equatable {
    case ignored
    case delivered
    case recoveryNeeded
    case failed
}

private enum SyntheticRetryError: Error {
    case modelFailed
}

private actor SyntheticBlockedCheckpoint {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        for waiter in waitingForEntry { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        guard !released else { return }
        released = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waitingForRelease { waiter.resume() }
    }
}

private actor SyntheticStoppedAudioFinalizer {
    private var admission = DictationStopFinalizationGate()
    private var persisted = 0
    private var terminalPublications = 0
    private var deliveries = 0
    private let checkpoint: SyntheticBlockedCheckpoint
    private let directory: URL
    private let modelOutcome: SyntheticStoppedAudioModelOutcome
    private let samples = [Float](repeating: 0.1, count: 16_000)

    init(
        checkpoint: SyntheticBlockedCheckpoint,
        directory: URL,
        modelOutcome: SyntheticStoppedAudioModelOutcome
    ) {
        self.checkpoint = checkpoint
        self.directory = directory
        self.modelOutcome = modelOutcome
    }

    func stop(sessionID: UUID) async -> SyntheticStoppedAudioStopOutcome {
        guard admission.admit(sessionID: sessionID) else { return .ignored }
        await checkpoint.block()
        do {
            guard let recovery = try DictationStoppedAudioRecoveryStore.persist(
                samples16k: samples,
                sessionID: sessionID,
                directory: directory
            ) else { return .failed }
            persisted += 1
            terminalPublications += 1
            let retryText: String
            do {
                retryText = try await injectedFocusedRetry()
            } catch {
                let analysis = DictationAudioRecovery.analyze(samples: samples, sampleRate: 16_000)
                let reason = DictationEmptyInferencePolicy.reason(
                    hasUsableSpeechSignal: analysis.hasUsableSpeechSignal
                )
                return reason == .audioNeedsRecovery ? .recoveryNeeded : .failed
            }
            if retryText.isEmpty {
                let analysis = DictationAudioRecovery.analyze(samples: samples, sampleRate: 16_000)
                let reason = DictationEmptyInferencePolicy.reason(
                    hasUsableSpeechSignal: analysis.hasUsableSpeechSignal
                )
                return reason == .audioNeedsRecovery ? .recoveryNeeded : .failed
            }
            deliveries += 1
            _ = DictationStoppedAudioRecoveryStore.cleanup(recovery, transcriptPersisted: true)
            return .delivered
        } catch {
            return .failed
        }
    }

    private func injectedFocusedRetry() async throws -> String {
        switch modelOutcome {
        case .text:
            return "decoded words"
        case .emptyRetry:
            return ""
        case .errorRetry:
            throw SyntheticRetryError.modelFailed
        }
    }

    func counts() -> (persisted: Int, terminalPublications: Int, deliveries: Int) {
        (persisted, terminalPublications, deliveries)
    }
}
