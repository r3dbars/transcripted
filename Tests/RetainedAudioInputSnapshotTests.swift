import Foundation

@MainActor
func testRetainedAudioInputSnapshot() async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("SnapshotTests-\(UUID().uuidString)", isDirectory: true)
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            precondition(root.lastPathComponent.hasPrefix("SnapshotTests-"))
            try? fm.removeItem(at: root)
        }
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let source = root.appendingPathComponent("system_audio.wav")
        let original = Data((0..<(1 << 20) + 17).map { UInt8($0 % 251) })

        runSuite("Reprocessing pins the opened bytes even when compression replaces their pathname") {
            do {
                try original.write(to: source)
                var snapshot: RetainedAudioInputSnapshot? = try .prepareSynchronously(
                    microphoneURL: source, systemURL: source, scratchRoot: scratch,
                    sourceDidOpen: { admitted in
                        try! fm.removeItem(at: admitted)
                        try! Data("replacement".utf8).write(to: admitted)
                    }
                )
                let held = snapshot!.systemURL
                assertEqual(try Data(contentsOf: held), original)
                assertEqual(snapshot!.microphoneURL, held, "the same track is copied once")
                assertEqual(try Data(contentsOf: source), Data("replacement".utf8), "snapshotting never removes the new retained file")
                let mode = try fm.attributesOfItem(atPath: held.path)[.posixPermissions] as? NSNumber
                assertEqual(mode?.intValue, 0o600)
                let directory = snapshot!.directory
                let directoryMode = try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
                assertEqual(directoryMode?.intValue, 0o700)
                snapshot = nil
                assertTrue(!fm.fileExists(atPath: directory.path), "the last owner cleans only its private directory")
                assertTrue(fm.fileExists(atPath: source.path), "retained original paths are never cleanup targets")
            } catch { assertTrue(false, "snapshot failed: \(error)") }
        }

        runSuite("Already promoted WAV inputs are admitted as M4A without changing format") {
            do {
                try fm.removeItem(at: source)
                let promoted = source.deletingPathExtension().appendingPathExtension("m4a")
                try original.write(to: promoted)
                let snapshot = try RetainedAudioInputSnapshot.prepareSynchronously(
                    microphoneURL: nil, systemURL: source, scratchRoot: scratch
                )
                assertEqual(snapshot.systemURL.pathExtension, "m4a")
                assertEqual(try Data(contentsOf: snapshot.systemURL), original)
                assertTrue(fm.fileExists(atPath: promoted.path), "admission leaves the replacement in the retained library")
                try fm.removeItem(at: promoted)
                assertEqual(try Data(contentsOf: snapshot.systemURL), original, "later user deletion cannot invalidate admitted bytes")
            } catch { assertTrue(false, "promotion fallback failed: \(error)") }
        }

        runSuite("Filesystems without cloning stream the same admitted descriptor in bounded chunks") {
            do {
                try original.write(to: source)
                let snapshot = try RetainedAudioInputSnapshot.prepareSynchronously(
                    microphoneURL: nil, systemURL: source, scratchRoot: scratch,
                    sourceDidOpen: { admitted in
                        try! fm.removeItem(at: admitted)
                        try! Data("new pathname bytes".utf8).write(to: admitted)
                    }, attemptClone: { _, _ in false }
                )
                assertEqual(try Data(contentsOf: snapshot.systemURL), original, "stream fallback reads beyond one chunk from the original descriptor")
                try original.write(to: source)
            } catch { assertTrue(false, "stream fallback failed: \(error)") }
        }

        runSuite("A missing microphone aborts snapshot admission and cleans partial owned output") {
            do {
                try original.write(to: source)
                do {
                    _ = try RetainedAudioInputSnapshot.prepareSynchronously(
                        microphoneURL: root.appendingPathComponent("missing.wav"), systemURL: source, scratchRoot: scratch
                    )
                    assertTrue(false, "missing requested tracks must fail closed")
                } catch {
                    assertEqual(try fm.contentsOfDirectory(atPath: scratch.path), [])
                    assertEqual(try Data(contentsOf: source), original)
                }
            } catch { assertTrue(false, "fixture failed: \(error)") }
        }

        runSuite("Symlinks and nonregular inputs are rejected without touching their targets") {
            do {
                let link = root.appendingPathComponent("linked.wav")
                try fm.createSymbolicLink(at: link, withDestinationURL: source)
                for invalid in [link, root] {
                    do {
                        _ = try RetainedAudioInputSnapshot.prepareSynchronously(
                            microphoneURL: nil, systemURL: invalid, scratchRoot: scratch
                        )
                        assertTrue(false, "unsafe source must be rejected")
                    } catch { assertEqual(try Data(contentsOf: source), original) }
                }
                assertEqual(try fm.contentsOfDirectory(atPath: scratch.path), [])
            } catch { assertTrue(false, "fixture failed: \(error)") }
        }

        await runSuite("Cancellation reaches detached snapshot copying after file admission") {
            let entered = SnapshotTestSignal(), release = DispatchSemaphore(value: 0)
            let workerCancelled = SnapshotTestFlag()
            let work = Task.detached {
                try await RetainedAudioInputSnapshot.prepare(
                    microphoneURL: nil, systemURL: source, scratchRoot: scratch,
                    sourceDidOpen: { _ in
                        Task { await entered.send() }
                        release.wait()
                        workerCancelled.set(Task.isCancelled)
                    }
                )
            }
            await entered.wait()
            work.cancel()
            release.signal()
            do {
                _ = try await work.value
                assertTrue(false, "cancelled admission must not return an input owner")
            } catch {
                assertTrue(error is CancellationError)
                assertTrue(workerCancelled.value, "cancellation is forwarded to the worker, not only checked by its caller")
                assertEqual((try? fm.contentsOfDirectory(atPath: scratch.path)) ?? ["unreadable"], [])
                assertTrue(fm.fileExists(atPath: source.path))
            }
        }

        runSuite("Failure handoff leaves persistent snapshot bytes for the retry owner") {
            do {
                var snapshot: RetainedAudioInputSnapshot? = try .prepareSynchronously(
                    microphoneURL: nil, systemURL: source, scratchRoot: scratch
                )
                let held = snapshot!.systemURL
                snapshot!.preserveForRecovery()
                snapshot = nil
                assertEqual(try Data(contentsOf: held), original, "failed queue persistence must never race owner cleanup")
            } catch { assertTrue(false, "fixture failed: \(error)") }
        }

        runSuite("Copy and model completion resume only the same uncancelled meeting action") {
            let token = UUID()
            let admission = SavedAudioReprocessAdmission(actionID: token, modelIdentifier: "model-a")
            func resumes(action: UUID = token, model: String = "model-a", capture: Bool = false,
                         dictation: Bool = false, background: Bool = false, cancelled: Bool = false) -> Bool {
                admission.mayResume(currentActionID: action, currentModelIdentifier: model,
                                    captureActive: capture, dictationBusy: dictation,
                                    backgroundWork: background, cancelled: cancelled)
            }
            assertTrue(resumes())
            assertTrue(!resumes(action: UUID()), "another action owns a late copy or model completion")
            assertTrue(!resumes(model: "model-b"), "a changed selection requires a fresh request")
            assertTrue(!resumes(capture: true), "a new recording must keep its state")
            assertTrue(!resumes(dictation: true))
            assertTrue(!resumes(background: true))
            assertTrue(!resumes(cancelled: true), "cancellation while waiting cannot launch Core")
        }

        runSuite("Graceful cancellation discards a completed preparation but never claimed Core inputs") {
            do {
                let waiting = try RetainedAudioInputSnapshot.prepareSynchronously(
                    microphoneURL: nil, systemURL: source, scratchRoot: scratch
                )
                assertTrue(waiting.discardUnstartedPreparation(), "model-wait references do not prevent safe preparation cleanup")
                assertTrue(!fm.fileExists(atPath: waiting.systemURL.path))
                assertTrue(!waiting.claimForTranscription(microphoneURL: nil, systemURL: waiting.systemURL),
                           "a delayed model completion cannot admit discarded inputs")
                let running = try RetainedAudioInputSnapshot.prepareSynchronously(
                    microphoneURL: nil, systemURL: source, scratchRoot: scratch
                )
                assertTrue(!running.claimForTranscription(microphoneURL: source, systemURL: running.systemURL),
                           "ownership cannot be attached to a different input pair")
                assertTrue(running.claimForTranscription(microphoneURL: nil, systemURL: running.systemURL))
                assertTrue(!running.discardUnstartedPreparation(), "preparation cancellation cannot delete a native task's inputs")
                assertEqual(try Data(contentsOf: running.systemURL), original)
            } catch { assertTrue(false, "ownership fixture failed: \(error)") }
        }

        runSuite("The selected output is bound before the audio copy can suspend") {
            do {
                let target = root.appendingPathComponent("Selected.md")
                for expected in [Optional(UUID()), nil] {
                    let identity = expected.map { "transcript_id: \($0.uuidString)\n" } ?? ""
                    try ("---\ncapture_type: meeting\n" + identity + "---\n\nOriginal synthetic body.")
                        .write(to: target, atomically: true, encoding: .utf8)
                    let snapshot = try RetainedAudioInputSnapshot.prepareSynchronously(
                        microphoneURL: nil, systemURL: source, scratchRoot: scratch,
                        replacementURL: target, expectedTranscriptID: expected,
                        sourceDidOpen: { _ in
                            try! "---\ncapture_type: meeting\ntranscript_id: \(UUID().uuidString)\n---\n\nDifferent meeting."
                                .write(to: target, atomically: true, encoding: .utf8)
                        }
                    )
                    assertTrue(snapshot.replacementExpectation != nil)
                    assertTrue((try? snapshot.replacementExpectation!.matches(at: target)) != true,
                               "a modern or legacy selection must not adopt a later target")
                }
            } catch { assertTrue(false, "output expectation fixture failed: \(error)") }
        }

        await runSuite("Superseding a completed preparation cleans copies still held by an older wait") {
            do {
                let preparation = Task {
                    try await RetainedAudioInputSnapshot.prepare(
                        microphoneURL: nil, systemURL: source, scratchRoot: scratch
                    )
                }
                let olderWait = try await preparation.value
                assertTrue(fm.fileExists(atPath: olderWait.systemURL.path))
                await RetainedAudioInputSnapshot.cancelPreparation(preparation)
                assertTrue(!fm.fileExists(atPath: olderWait.systemURL.path), "a completed task's success result must not prevent supersession cleanup")
                assertTrue(!olderWait.claimForTranscription(microphoneURL: nil, systemURL: olderWait.systemURL))
                let activePreparation = Task {
                    try await RetainedAudioInputSnapshot.prepare(
                        microphoneURL: nil, systemURL: source, scratchRoot: scratch
                    )
                }
                let active = try await activePreparation.value
                assertTrue(active.claimForTranscription(microphoneURL: nil, systemURL: active.systemURL))
                await RetainedAudioInputSnapshot.cancelPreparation(activePreparation)
                assertEqual(try Data(contentsOf: active.systemURL), original, "the same cleanup cannot invalidate claimed Core reads")
            } catch { assertTrue(false, "supersession fixture failed: \(error)") }
        }
    } catch { assertTrue(false, "owned snapshot test setup failed: \(error)") }
}

private actor SnapshotTestSignal {
    private var sent = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if sent { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func send() {
        sent = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private final class SnapshotTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}
