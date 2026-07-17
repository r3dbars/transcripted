import Foundation

func testDictationStoppedAudioRecovery() {
    runSuite("Dictation stopped audio recovery writes a valid private WAV") {
        let directory = makeRecoveryTestDirectory("wav")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

        do {
            let recovery = try DictationStoppedAudioRecoveryStore.persist(
                samples16k: [-1, -0.5, 0, 0.5, 1],
                sessionID: sessionID,
                directory: directory
            )
            assertNotNil(recovery, "non-empty stopped audio should be checkpointed")
            guard let recovery else { return }
            let data = try Data(contentsOf: recovery.url)
            assertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF", "recovery audio should use a WAV container")
            assertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE", "recovery audio should identify the WAV format")
            assertEqual(readUInt32LE(data, offset: 24), 16_000, "recovery audio should be stored at the inference sample rate")
            assertEqual(readUInt16LE(data, offset: 34), 16, "recovery audio should use 16-bit PCM")
            assertEqual(readUInt32LE(data, offset: 40), 10, "WAV data length should match the sample count")
            let attributes = try FileManager.default.attributesOfItem(atPath: recovery.url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
            assertEqual(permissions, 0o600, "recovery audio should be owner-only")
            let discovered = DictationStoppedAudioRecoveryStore.pendingRecoveries(limit: 1, directory: directory)
            assertEqual(discovered, [recovery], "durable metadata should make recovery discoverable after store recreation")
        } catch {
            assertTrue(false, "recovery WAV should persist: \(error)")
        }
    }

    runSuite("Dictation stopped audio recovery survives failed transcript persistence") {
        let directory = makeRecoveryTestDirectory("retain")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let recovery = try DictationStoppedAudioRecoveryStore.persist(
                samples16k: [0.25, -0.25],
                sessionID: UUID(),
                directory: directory
            )
            let cleaned = DictationStoppedAudioRecoveryStore.cleanup(
                recovery,
                transcriptPersisted: false,
                explicitDiscard: false
            )
            assertFalse(cleaned, "failed transcript persistence must not clean recovery audio")
            assertTrue(FileManager.default.fileExists(atPath: recovery!.url.path), "recovery audio must remain durable")
        } catch {
            assertTrue(false, "recovery audio should persist: \(error)")
        }
    }

    runSuite("Dictation stopped audio recovery cleans up only after success or explicit discard") {
        for transcriptPersisted in [true, false] {
            let directory = makeRecoveryTestDirectory(transcriptPersisted ? "saved" : "discarded")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let recovery = try DictationStoppedAudioRecoveryStore.persist(
                    samples16k: [0.1],
                    sessionID: UUID(),
                    directory: directory
                )
                let cleaned = DictationStoppedAudioRecoveryStore.cleanup(
                    recovery,
                    transcriptPersisted: transcriptPersisted,
                    explicitDiscard: !transcriptPersisted
                )
                assertTrue(cleaned, "successful save or explicit discard should clean recovery audio")
                assertFalse(FileManager.default.fileExists(atPath: recovery!.url.path), "cleaned recovery audio should be deleted")
                assertTrue(
                    DictationStoppedAudioRecoveryStore.pendingRecoveries(directory: directory).isEmpty,
                    "cleanup should remove restart-discovery metadata"
                )
            } catch {
                assertTrue(false, "recovery cleanup should succeed: \(error)")
            }
        }
    }

    runSuite("Dictation stopped audio recovery limits after newest-first ordering") {
        let oldSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let middleSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let newSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let recoveries = [
            DictationStoppedAudioRecovery(url: URL(fileURLWithPath: "/old.wav"), sessionID: oldSessionID, createdAt: Date(timeIntervalSince1970: 1)),
            DictationStoppedAudioRecovery(url: URL(fileURLWithPath: "/new.wav"), sessionID: newSessionID, createdAt: Date(timeIntervalSince1970: 3)),
            DictationStoppedAudioRecovery(url: URL(fileURLWithPath: "/middle.wav"), sessionID: middleSessionID, createdAt: Date(timeIntervalSince1970: 2))
        ]

        let limited = DictationStoppedAudioRecoveryStore.mostRecent(recoveries, limit: 2)

        assertEqual(
            limited.map(\.sessionID),
            [newSessionID, middleSessionID],
            "the limit must select the newest recoveries regardless of enumeration order"
        )
    }

    runSuite("Stopped audio persistence rejects cancelled and superseded sessions") {
        let activeSessionID = UUID()
        assertTrue(
            DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                taskCancelled: false,
                isDictating: true,
                taskSessionID: activeSessionID,
                currentSessionID: activeSessionID
            ),
            "the current live stop task should persist its recovery checkpoint"
        )
        assertFalse(
            DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                taskCancelled: true,
                isDictating: true,
                taskSessionID: activeSessionID,
                currentSessionID: activeSessionID
            ),
            "a cancelled stop task must not persist after detached resampling returns"
        )
        assertFalse(
            DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                taskCancelled: false,
                isDictating: true,
                taskSessionID: activeSessionID,
                currentSessionID: UUID()
            ),
            "an old stop task must not mutate a successor session"
        )
    }

    runSuite("Dictation controller checkpoints audio before waiting for the model") {
        do {
            let source = try String(
                contentsOf: repoFixtureURL("Sources/UI/Overlay/DictationSessionController.swift"),
                encoding: .utf8
            )
            guard let persistRange = source.range(of: "DictationStoppedAudioRecoveryStore.persist("),
                  let modelWaitRange = source.range(of: "if !appState.sttRouter.isModelLoaded", range: persistRange.upperBound..<source.endIndex) else {
                assertTrue(false, "controller should persist stopped audio before the model wait")
                return
            }
            assertTrue(persistRange.lowerBound < modelWaitRange.lowerBound, "durable checkpoint must precede the model failure boundary")
            guard let snapshotRange = source.range(of: "snapshotRecordedSamplesForPersistence()"),
                  let commitGuardRange = source.range(
                    of: "DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(",
                    range: snapshotRange.upperBound..<persistRange.lowerBound
                  ) else {
                assertTrue(false, "controller should revalidate session ownership after snapshot resampling and before persistence")
                return
            }
            assertTrue(
                snapshotRange.lowerBound < commitGuardRange.lowerBound && commitGuardRange.lowerBound < persistRange.lowerBound,
                "cancel/session guard must run after the detached snapshot and before recovery persistence"
            )
            assertTrue(source.contains("transcriptPersisted: saveResult.saved != nil"), "cleanup should be tied to successful transcript persistence")
            assertTrue(source.contains("if emptyReason != .modelFailure"), "model failures should retain recovery audio")
            assertTrue(
                source.contains("cancelDictation(preserveStoppedAudio: true)"),
                "termination timeout must not convert a durable checkpoint into an implicit discard"
            )
            let appSource = try String(contentsOf: repoFixtureURL("Sources/TranscriptedApp.swift"), encoding: .utf8)
            assertTrue(
                appSource.contains("sessionController.presentPendingStoppedAudioRecoveryIfNeeded()"),
                "launch should scan for pending stopped audio"
            )
        } catch {
            assertTrue(false, "controller source should be readable: \(error)")
        }
    }
}

private func makeRecoveryTestDirectory(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationStoppedAudioRecoveryTests-\(suffix)-\(UUID().uuidString)", isDirectory: true)
}

private func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}
