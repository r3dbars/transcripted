import Foundation
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

@Suite("Personal History ingestion")
struct PersonalHistoryControllerTests {
    @Test("Storage operations preserve order and recover after failure")
    func orderedStorageTail() async {
        enum ExpectedFailure: Error { case value }
        actor Log {
            var entries: [String] = []
            var gateOpen = false
            func add(_ value: String) { entries.append(value) }
            func open() { gateOpen = true }
            func waitUntilOpen() async {
                while !gateOpen { await Task.yield() }
            }
        }
        let log = Log()
        var tail = OrderedAsyncTaskTail()
        let first = tail.enqueue {
            await log.add("append-start")
            await log.waitUntilOpen()
            await log.add("append-end")
        }
        let second = tail.enqueue { await log.add("delete") }
        while await log.entries.isEmpty { await Task.yield() }
        await log.open()
        _ = await first.result
        _ = await second.result
        let failure = tail.enqueue { throw ExpectedFailure.value }
        let afterFailure = tail.enqueue { await log.add("after-failure") }
        _ = await failure.result
        _ = await afterFailure.result

        #expect(await log.entries == [
            "append-start", "append-end", "delete", "after-failure",
        ])
    }

    @Test("Disabled history acknowledges but never persists")
    func disabledDoesNotPersist() async {
        let fixture = Fixture()
        #expect(await fixture.controller.ingest([fixture.event()]))
        #expect(await fixture.store.events.isEmpty)
        #expect(await fixture.controller.nextWordStatus().snapshot.opportunities == 0)
    }

    @Test("Enabled history persists allowed events")
    func enabledPersists() async {
        let fixture = Fixture()
        fixture.controller.isEnabled = true
        let event = fixture.event(text: " personal writing helps personal writing helps ")

        #expect(await fixture.controller.ingest([event]))
        #expect(await fixture.store.events == [event])
        #expect(await settledStatus(fixture.controller).snapshot.learnedTransitions > 0)
    }

    @Test("Live paired aggregates persist before ack and survive restart without replay scoring")
    func pairedCheckpointSurvivesRestart() async {
        let fixture = Fixture(enabled: true)
        #expect(await settledStatus(fixture.controller).phase == .ready)
        let event = fixture.event(
            text: " alpha beta alpha beta alpha beta alpha beta "
        )

        #expect(await fixture.controller.ingest([event]))
        let before = await settledStatus(fixture.controller).snapshot
        #expect(before.opportunities > 0)
        let stored = await fixture.store.checkpoint
        let data = try? JSONEncoder().encode(stored)
        let checkpointJSON = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(stored != nil)
        #expect(!checkpointJSON.contains("alpha"))
        #expect(!checkpointJSON.contains("beta"))
        #expect(!checkpointJSON.contains(event.id))
        #expect(!checkpointJSON.contains(event.sessionIdentifier))

        let restarted = PersonalHistoryController(
            store: fixture.store,
            settings: TildeSettings(keyboard: fixture.defaults)
        )
        let after = await settledStatus(restarted).snapshot
        #expect(after.opportunities == before.opportunities)
        #expect(after.outcomeCells == before.outcomeCells)
        #expect(after.predictionDisagreements == before.predictionDisagreements)
        #expect(after.activeDays == before.activeDays)
        #expect(after.learnedContexts == before.learnedContexts)
        #expect(after.learnedTransitions == before.learnedTransitions)

        let continuation = fixture.event(id: "after-restart", text: " beta ")
        #expect(await restarted.ingest([continuation]))
        var uninterrupted = PersonalNextWordShadow()
        uninterrupted.consume([event], scoring: true)
        uninterrupted.consume([continuation], scoring: true)
        #expect(await settledStatus(restarted).snapshot == uninterrupted.snapshot)
    }

    @Test("Disabling retains the checkpoint while exclusion changes clear it")
    func checkpointDisableAndExclusionLifecycle() async {
        let fixture = Fixture(enabled: true)
        #expect(await settledStatus(fixture.controller).phase == .ready)
        #expect(await fixture.controller.ingest([
            fixture.event(text: " alpha beta alpha beta alpha beta "),
        ]))
        let saved = await fixture.store.checkpoint
        #expect(saved != nil)

        fixture.controller.isEnabled = false
        #expect(await fixture.controller.nextWordStatus().phase == .inactive)
        #expect(await fixture.store.checkpoint == saved)

        fixture.controller.isEnabled = true
        #expect(await settledStatus(fixture.controller).phase == .ready)
        fixture.controller.excludedApps = ["com.example.Other"]
        let reset = await settledStatus(fixture.controller)
        #expect(reset.snapshot.opportunities == 0)
        #expect(await fixture.store.checkpoint == saved)

        fixture.controller.excludedApps = []
        #expect(await settledStatus(fixture.controller).snapshot.opportunities == 0)
        let restarted = PersonalHistoryController(
            store: fixture.store,
            settings: TildeSettings(keyboard: fixture.defaults)
        )
        #expect(await settledStatus(restarted).snapshot.opportunities == 0)
    }

    @Test("A mismatched checkpoint is discarded before bounded replay")
    func mismatchedCheckpointFailsClosed() async {
        let checkpoint = PersonalNextWordStoredCheckpoint(
            historyIdentifier: "other-history",
            experimentIdentifier: "experiment",
            excludedApps: [],
            checkpoint: PersonalNextWordShadow().checkpoint
        )
        let fixture = Fixture(enabled: true, checkpoint: checkpoint)

        let status = await settledStatus(fixture.controller)
        #expect(status.phase == .ready)
        #expect(status.snapshot.opportunities == 0)
        #expect(await fixture.store.replayMaximumBytes == [4 * 1_024 * 1_024])
    }

    @Test("An exclusion change prevents stale replay from publishing old-scope totals")
    func exclusionChangeDefeatsStaleReplay() async {
        var prior = PersonalNextWordShadow()
        prior.consume([PersonalHistoryEvent(
            id: "prior",
            timestampMilliseconds: PersonalNextWordShadow.evaluationStartMilliseconds + 1,
            historyIdentifier: "history",
            consentIdentifier: "consent",
            sessionIdentifier: "session",
            appBundleIdentifier: "com.example.Editor",
            source: .typed,
            text: " alpha beta alpha beta alpha beta "
        )!])
        let stored = PersonalNextWordStoredCheckpoint(
            historyIdentifier: "history",
            experimentIdentifier: "experiment",
            excludedApps: [],
            checkpoint: prior.checkpoint
        )
        let fixture = Fixture(enabled: true, blockReplays: true, checkpoint: stored)
        await fixture.store.waitForReplayStart()

        fixture.controller.excludedApps = ["com.example.Other"]
        await fixture.store.releaseReplays()

        let status = await settledStatus(fixture.controller)
        #expect(status.phase == .ready)
        #expect(status.snapshot.opportunities == 0)
    }

    @Test("A failed append cannot publish a paired checkpoint")
    func failedAppendDoesNotPublishCheckpoint() async {
        let fixture = Fixture(enabled: true, appendFailure: .corruptStore)
        #expect(await settledStatus(fixture.controller).phase == .ready)
        let event = fixture.event(text: " alpha beta alpha beta alpha beta ")

        #expect(!(await fixture.controller.ingest([event])))
        #expect(await fixture.store.events.isEmpty)
        #expect(await fixture.store.checkpoint == nil)
        #expect(await fixture.controller.nextWordStatus().snapshot.opportunities == 0)
    }

    @Test("Storage errors map to fixed privacy-safe menu copy")
    func storageErrorCopy() {
        enum UnexpectedFailure: Error { case value }
        let corrupt = PersonalHistoryStorageHealth.failure(
            error: PersonalHistoryStorageError.corruptStore
        )
        let transientKeychain = PersonalHistoryStorageHealth.failure(
            error: PersonalHistoryStorageError.keychain(-50)
        )

        #expect(corrupt == .storeCorrupt)
        #expect(corrupt?.menuLine == "History: not saving — reset required")
        #expect(PersonalHistoryStorageHealth.failure(
            error: PersonalHistoryStorageError.missingKey
        ) == .keyUnavailable)
        #expect(PersonalHistoryStorageHealth.failure(
            error: PersonalHistoryStorageError.invalidKey
        ) == .keyUnavailable)
        #expect(transientKeychain == .storageUnavailable)
        #expect(transientKeychain?.menuLine == "History: not saving — storage unavailable")
        #expect(PersonalHistoryStorageHealth.failure(
            error: CocoaError(.fileWriteNoPermission)
        ) == .storageUnavailable)
        #expect(PersonalHistoryStorageHealth.failure(
            error: UnexpectedFailure.value
        ) == .internalError)
        #expect(PersonalHistoryStorageHealth.healthy.menuLine == nil)
        #expect(PersonalHistoryStorageHealth.internalError.menuLine
            == "History: not saving — restart Transcripted")
    }

    @Test("Repeated failures log once and the next stored event logs recovery")
    func storageFailureDeduplicationAndRecovery() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("tilde-history-health-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DiagnosticsLog(logURL: root.appendingPathComponent("diagnostics.log"))
        let fixture = Fixture(diagnostics: diagnostics)
        fixture.controller.isEnabled = true
        #expect(await settledStatus(fixture.controller).phase == .ready)
        await fixture.store.setAppendFailure(.corruptStore)

        #expect(!(await fixture.controller.ingest([fixture.event(id: "failure-one")])))
        #expect(!(await fixture.controller.ingest([fixture.event(id: "failure-two")])))
        #expect(fixture.controller.storageHealthSnapshot == .storeCorrupt)

        await fixture.store.setAppendFailure(nil)
        #expect(await fixture.controller.ingest([fixture.event(id: "recovery")]))
        #expect(await fixture.controller.ingest([fixture.event(id: "healthy")]))
        #expect(fixture.controller.storageHealthSnapshot == .healthy)
        diagnostics.flush()

        let contents = try String(
            contentsOf: root.appendingPathComponent("diagnostics.log"),
            encoding: .utf8
        )
        #expect(contents.components(separatedBy: "personal-history-write-failed").count == 2)
        #expect(contents.contains("reason=store-corrupt"))
        #expect(contents.components(separatedBy: "personal-history-write-recovered").count == 2)
    }

    @Test("Startup replay failure surfaces once as storage health")
    func startupReplayFailure() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("tilde-history-replay-health-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DiagnosticsLog(logURL: root.appendingPathComponent("diagnostics.log"))
        let fixture = Fixture(
            enabled: true,
            appendFailure: .missingKey,
            replayFailure: .missingKey,
            diagnostics: diagnostics
        )

        #expect(await settledStatus(fixture.controller).phase == .unavailable)
        #expect(fixture.controller.storageHealthSnapshot == .keyUnavailable)
        #expect(fixture.controller.storageHealthSnapshot.menuLine
            == "History: not saving — reset required")
        #expect(!(await fixture.controller.ingest([fixture.event(id: "same-failure")])))

        diagnostics.flush()

        let contents = try String(
            contentsOf: root.appendingPathComponent("diagnostics.log"),
            encoding: .utf8
        )
        #expect(contents.components(separatedBy: "personal-history-write-failed").count == 2)
        #expect(contents.contains("reason=key-unavailable"))
        #expect(!contents.contains("personal-history-write-recovered"))
    }

    @Test("Empty replay cannot recover an append failure")
    func emptyReplayDoesNotRecoverAppendFailure() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("tilde-history-empty-replay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DiagnosticsLog(logURL: root.appendingPathComponent("diagnostics.log"))
        let fixture = Fixture(diagnostics: diagnostics)
        fixture.controller.isEnabled = true
        #expect(await settledStatus(fixture.controller).phase == .ready)
        await fixture.store.setAppendFailure(.keychain(-50))

        #expect(!(await fixture.controller.ingest([fixture.event(id: "failed-append")])))
        #expect(fixture.controller.storageHealthSnapshot == .storageUnavailable)
        let replayCount = await fixture.store.replayCount
        await fixture.store.setAppendFailure(nil)
        fixture.controller.excludedApps = ["com.example.Other"]
        for _ in 0..<100 {
            if await fixture.store.replayCount > replayCount { break }
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(await fixture.store.replayCount > replayCount)
        #expect(await fixture.store.events.isEmpty)
        #expect(fixture.controller.storageHealthSnapshot == .storageUnavailable)
        diagnostics.flush()
        let contents = try String(
            contentsOf: root.appendingPathComponent("diagnostics.log"),
            encoding: .utf8
        )
        #expect(contents.contains("reason=storage-unavailable"))
        #expect(!contents.contains("personal-history-write-recovered"))
    }

    @Test("Deletion dominates a stale write failure")
    func deletionDominatesStaleWriteFailure() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("tilde-history-stale-health-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DiagnosticsLog(logURL: root.appendingPathComponent("diagnostics.log"))
        let fixture = Fixture(
            appendFailure: .corruptStore,
            blockAppends: true,
            diagnostics: diagnostics
        )
        fixture.controller.isEnabled = true
        #expect(await settledStatus(fixture.controller).phase == .ready)
        let controller = fixture.controller
        let event = fixture.event(id: "old-generation")
        let ingest = Task { await controller.ingest([event]) }
        await fixture.store.waitForAppendStart()

        let deletion = Task { try await controller.deleteAll() }
        while controller.isEnabled { await Task.yield() }
        await fixture.store.releaseAppends()

        #expect(!(await ingest.value))
        try await deletion.value
        #expect(controller.storageHealthSnapshot == .healthy)
        diagnostics.flush()
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("diagnostics.log").path
        ))
    }

    @Test("Delayed deletion cannot erase reenabled write health")
    func delayedDeletionPreservesReenabledHealth() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("tilde-history-delete-health-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DiagnosticsLog(logURL: root.appendingPathComponent("diagnostics.log"))
        let fixture = Fixture(blockDeletes: true, diagnostics: diagnostics)
        fixture.controller.isEnabled = true
        #expect(await settledStatus(fixture.controller).phase == .ready)
        await fixture.store.setAppendFailure(.corruptStore)
        #expect(!(await fixture.controller.ingest([fixture.event(id: "first-failure")])))

        let controller = fixture.controller
        let deletion = Task { try await controller.deleteAll() }
        await fixture.store.waitForDeleteStart()
        controller.isEnabled = true
        let newEvent = fixture.event(id: "new-generation-failure")
        let newIngest = Task { await controller.ingest([newEvent]) }
        await fixture.store.releaseDeletes()

        try await deletion.value
        #expect(!(await newIngest.value))
        #expect(controller.storageHealthSnapshot == .storeCorrupt)
        diagnostics.flush()
        let contents = try String(
            contentsOf: root.appendingPathComponent("diagnostics.log"),
            encoding: .utf8
        )
        #expect(contents.components(separatedBy: "personal-history-write-failed").count == 2)
    }

    @Test("Excluded apps are discarded before storage")
    func excludedAppDoesNotPersist() async {
        let fixture = Fixture()
        fixture.controller.isEnabled = true
        fixture.controller.excludedApps = ["com.example.Editor"]

        #expect(await fixture.controller.ingest([fixture.event()]))
        #expect(await fixture.store.events.isEmpty)
        #expect(await settledStatus(fixture.controller).snapshot.opportunities == 0)
    }

    @Test("A password-manager bundle id is excluded from live ingestion even when the caller's own exclusion list is empty")
    func alwaysExcludedAppDoesNotPersistWithEmptyConfiguredExclusions() async {
        // `excludedApps` defaults to `[]` here — this is the exact
        // configuration in which the always-excluded (password manager /
        // Keychain) set used to be silently skipped by `ingestSerially`,
        // because it checked `configuration.excludedApps.contains(...)`
        // directly instead of going through `DefaultExcludedApps`.
        let fixture = Fixture()
        fixture.controller.isEnabled = true
        let event = fixture.event(app: "com.1password.1password")

        #expect(await fixture.controller.ingest([event]))
        #expect(await fixture.store.events.isEmpty)
        #expect(await settledStatus(fixture.controller).snapshot.opportunities == 0)
    }

    @Test("A password-manager bundle id is excluded from startup replay even when the caller's own exclusion list is empty")
    func alwaysExcludedAppIsFilteredFromReplayWithEmptyConfiguredExclusions() async {
        // Same bug, replay path: `finishReplay` used to filter only against
        // `configuration.excludedApps`, so a password-manager event already
        // sitting in the store would still be replayed into next-word
        // scoring when the owner had never configured any exclusions.
        let fixture = Fixture(
            enabled: true,
            preloaded: [
                ("password-manager", " private vault contents repeat ", "com.1password.1password"),
                ("allowed", " personal writing helps personal writing helps ", "com.example.Editor"),
            ]
        )

        let status = await settledStatus(fixture.controller)
        #expect(status.phase == .ready)
        var expected = PersonalNextWordShadow()
        expected.consume(await fixture.store.events.filter {
            $0.appBundleIdentifier == "com.example.Editor"
        }, scoring: false)
        #expect(status.snapshot == expected.snapshot)
    }

    @Test("Deletion disables capture and rejects queued events from the old history")
    func deletionRotatesHistory() async throws {
        let fixture = Fixture()
        fixture.controller.isEnabled = true
        #expect(await settledStatus(fixture.controller).phase == .ready)
        let eventBeforeDeletion = fixture.event(
            text: " personal writing helps personal writing helps "
        )
        #expect(await fixture.controller.ingest([eventBeforeDeletion]))
        #expect(await settledStatus(fixture.controller).snapshot.learnedTransitions > 0)
        #expect(await fixture.store.checkpoint != nil)

        try await fixture.controller.deleteAll()
        #expect(!fixture.controller.isEnabled)
        #expect(await fixture.store.events.isEmpty)
        #expect(await fixture.controller.nextWordStatus().snapshot.opportunities == 0)
        #expect(await fixture.store.checkpoint == nil)

        fixture.controller.isEnabled = true
        #expect(await fixture.controller.ingest([eventBeforeDeletion]))
        #expect(await fixture.store.events.isEmpty)

        let eventAfterDeletion = fixture.event()
        #expect(await fixture.controller.ingest([eventAfterDeletion]))
        #expect(await fixture.store.events == [eventAfterDeletion])
    }

    @Test("Menu copy stays honest until every paired next-word threshold is met")
    func nextWordStatusCopy() {
        let empty = PersonalNextWordShadow(evaluationStartMilliseconds: 0).snapshot
        #expect(PersonalNextWordShadowStatus(phase: .ready, snapshot: empty).menuLine
            == "Next-word test: 0/2,000 shared fresh words · 0/200 candidate predictions · 0/100 disagreements · 0/14 active days · shadow-only")
        #expect(PersonalNextWordShadowStatus(phase: .inactive, snapshot: empty).menuLine
            == "Next-word test: off · shadow-only")
        #expect(PersonalNextWordShadowStatus(phase: .loading, snapshot: empty).menuLine
            == "Next-word test: loading recent history… · shadow-only")

        let early = PersonalNextWordShadowSnapshot(
            opportunities: 20,
            predictions: 7,
            exactHits: 3,
            learnedContexts: 12,
            learnedTransitions: 18,
            capacityLimited: false,
            baselinePredictions: 5,
            baselineExactHits: 2,
            predictionDisagreements: 4,
            activeDays: 2
        )
        #expect(PersonalNextWordShadowStatus(phase: .ready, snapshot: early).menuLine
            == "Next-word test: 20/2,000 shared fresh words · 7/200 candidate predictions · 4/100 disagreements · 2/14 active days · shadow-only")
        #expect(PersonalNextWordShadowStatus(phase: .unavailable, snapshot: empty).menuLine
            == "Next-word test: unavailable · shadow-only")

        let reportable = PersonalNextWordShadowSnapshot(
            opportunities: 2_000,
            predictions: 200,
            exactHits: 100,
            learnedContexts: 80,
            learnedTransitions: 120,
            capacityLimited: false,
            baselinePredictions: 180,
            baselineExactHits: 80,
            predictionDisagreements: 100,
            activeDays: 14
        )
        #expect(PersonalNextWordShadowStatus(phase: .ready, snapshot: reportable).menuLine
            == "Next-word test: candidate 5.0% vs baseline 4.0% effective · 2,000 shared fresh words · shadow-only")

        let thresholdMisses = [
            PersonalNextWordShadowSnapshot(
                opportunities: 1_999, predictions: 200, exactHits: 100,
                learnedContexts: 1, learnedTransitions: 1, capacityLimited: false,
                predictionDisagreements: 100, activeDays: 14
            ),
            PersonalNextWordShadowSnapshot(
                opportunities: 2_000, predictions: 199, exactHits: 100,
                learnedContexts: 1, learnedTransitions: 1, capacityLimited: false,
                predictionDisagreements: 100, activeDays: 14
            ),
            PersonalNextWordShadowSnapshot(
                opportunities: 2_000, predictions: 200, exactHits: 100,
                learnedContexts: 1, learnedTransitions: 1, capacityLimited: false,
                predictionDisagreements: 99, activeDays: 14
            ),
            PersonalNextWordShadowSnapshot(
                opportunities: 2_000, predictions: 200, exactHits: 100,
                learnedContexts: 1, learnedTransitions: 1, capacityLimited: false,
                predictionDisagreements: 100, activeDays: 13
            ),
        ]
        for snapshot in thresholdMisses {
            #expect(PersonalNextWordShadowStatus(phase: .ready, snapshot: snapshot).menuLine
                .contains("candidate predictions"))
        }

        let capacityLimited = PersonalNextWordShadowSnapshot(
            opportunities: 20,
            predictions: 7,
            exactHits: 3,
            learnedContexts: 12,
            learnedTransitions: 18,
            capacityLimited: true,
            predictionDisagreements: 4,
            activeDays: 2
        )
        #expect(PersonalNextWordShadowStatus(
            phase: .ready,
            snapshot: capacityLimited
        ).menuLine == "Next-word test: 20/2,000 shared fresh words · 7/200 candidate predictions · 4/100 disagreements · 2/14 active days · memory limit reached · shadow-only")
    }

    @Test("Enabled startup replays only allowed encrypted history")
    func enabledStartupReplay() async {
        let fixture = Fixture(
            enabled: true,
            excludedApps: ["com.example.Excluded"],
            preloaded: [
                ("excluded", " private excluded history repeats ", "com.example.Excluded"),
                ("allowed", " personal writing helps personal writing helps ", "com.example.Editor"),
            ]
        )

        let status = await settledStatus(fixture.controller)
        #expect(status.phase == .ready)
        var expected = PersonalNextWordShadow()
        expected.consume(await fixture.store.events.filter {
            $0.appBundleIdentifier == "com.example.Editor"
        }, scoring: false)
        #expect(status.snapshot == expected.snapshot)
    }

    @Test("Startup replay uses a bounded recent tail and censors its first fragment")
    func startupReplayUsesBoundedTail() async {
        let fixture = Fixture(
            enabled: true,
            preloaded: [
                ("tail", "gment complete word ", "com.example.Editor"),
            ]
        )

        let status = await settledStatus(fixture.controller)
        #expect(status.phase == .ready)
        #expect(await fixture.store.replayMaximumBytes == [4 * 1_024 * 1_024])
        #expect(status.snapshot.learnedContexts == 2)
        #expect(status.snapshot.learnedTransitions == 3)
    }

    @Test("Writing during startup is acknowledged without waiting and warms without scoring")
    func loadingIngestAcknowledgesBeforeReplay() async {
        let fixture = Fixture(
            enabled: true,
            preloaded: [("training", " personal writing helps ", "com.example.Editor")],
            blockReplays: true
        )
        await fixture.store.waitForReplayStart()
        let live = fixture.event(id: "live-during-replay", text: " personal writing helps ")
        let controller = fixture.controller
        let store = fixture.store
        let ingest = Task { await controller.ingest([live]) }

        #expect(await ingest.value)
        #expect(await store.events.count == 2)
        #expect(await controller.nextWordStatus().phase == .loading)
        await store.releaseReplays()

        var expected = PersonalNextWordShadow()
        expected.consume(await store.events, scoring: false)
        #expect(await settledStatus(controller).snapshot == expected.snapshot)
    }

    @Test("A replay that finishes during a startup append cannot lose that batch")
    func replayFinishesDuringLoadingAppend() async {
        let fixture = Fixture(
            enabled: true,
            preloaded: [("training", " personal writing helps ", "com.example.Editor")],
            blockReplays: true,
            blockAppends: true
        )
        await fixture.store.waitForReplayStart()
        let live = fixture.event(id: "live-during-append", text: " novel startup branch ")
        let controller = fixture.controller
        let store = fixture.store
        let ingest = Task { await controller.ingest([live]) }
        await store.waitForAppendStart()

        await store.releaseReplays()
        #expect(await settledStatus(controller).phase == .ready)
        await store.releaseAppends()
        #expect(await ingest.value)

        var expected = PersonalNextWordShadow()
        expected.consume(await store.events, scoring: false)
        #expect(await settledStatus(controller).snapshot == expected.snapshot)
    }

    @Test("Concurrent ready batches score and checkpoint in durable order")
    func concurrentReadyIngestsAreSerialized() async {
        let fixture = Fixture(enabled: true, blockAppends: true)
        #expect(await settledStatus(fixture.controller).phase == .ready)
        let first = fixture.event(
            id: "concurrent-first",
            text: " alpha beta alpha beta alpha beta "
        )
        let second = fixture.event(
            id: "concurrent-second",
            text: " beta alpha beta alpha "
        )
        let controller = fixture.controller
        let store = fixture.store
        let firstIngest = Task { await controller.ingest([first]) }
        await store.waitForAppendStart()
        let secondIngest = Task { await controller.ingest([second]) }

        await store.releaseAppends()
        #expect(await firstIngest.value)
        #expect(await secondIngest.value)

        var expected = PersonalNextWordShadow()
        expected.consume([first])
        expected.consume([second])
        let actual = await settledStatus(controller).snapshot
        #expect(actual == expected.snapshot)
        #expect(await store.checkpoint?.checkpoint == expected.checkpoint)
    }

    @Test("A newer off setting rejects work queued under an older revision")
    func disableWinsOverQueuedIngest() async {
        let fixture = Fixture()
        fixture.controller.isEnabled = true
        fixture.controller.isEnabled = false

        #expect(await fixture.controller.ingest([fixture.event(text: "personal writing ")]))
        #expect(await fixture.store.events.isEmpty)
        #expect(await fixture.controller.nextWordStatus().phase == .inactive)
    }

    @Test("Consent rotation prevents next-word contexts crossing off and on")
    func consentRotationBreaksContexts() async {
        let fixture = Fixture()
        fixture.controller.isEnabled = true
        #expect(await fixture.controller.ingest([fixture.event(id: "before", text: " alpha ")]))
        let firstConsent = fixture.defaults.string(
            forKey: PersonalHistorySettingsContract.consentIdentifierKey
        )

        fixture.controller.isEnabled = false
        fixture.controller.isEnabled = true
        let secondConsent = fixture.defaults.string(
            forKey: PersonalHistorySettingsContract.consentIdentifierKey
        )
        #expect(firstConsent != secondConsent)
        #expect(await fixture.controller.ingest([
            fixture.event(id: "after", text: " beta "),
        ]))

        let status = await settledStatus(fixture.controller).snapshot
        #expect(status.opportunities == 0)
        #expect(status.predictions == 0)
    }

    @Test("Personal next-word prediction gates on exclusions and never perturbs shadow scoring")
    func personalNextWordPredictionGatesAndDoesNotPerturbScoring() async {
        let fixture = Fixture(enabled: true, excludedApps: ["com.example.Blocked"])
        #expect(await settledStatus(fixture.controller).phase == .ready)
        let trainingText = " three four Finish three four Finish "
        #expect(await fixture.controller.ingest([fixture.event(text: trainingText)]))
        let before = await settledStatus(fixture.controller).snapshot

        let allowed = await fixture.controller.personalNextWordPrediction(
            afterTailWords: ["three", "four"],
            appBundleIdentifier: "com.example.Editor"
        )
        #expect(allowed?.word == "Finish")
        #expect(allowed?.support == 2)

        let excluded = await fixture.controller.personalNextWordPrediction(
            afterTailWords: ["three", "four"],
            appBundleIdentifier: "com.example.Blocked"
        )
        #expect(excluded == nil)

        let missingApp = await fixture.controller.personalNextWordPrediction(
            afterTailWords: ["three", "four"],
            appBundleIdentifier: nil
        )
        #expect(missingApp == nil)

        // Repeated read-only lookups must never perturb the paired shadow
        // experiment's own scoring — the whole point of routing this
        // through the same actor without any new state.
        for _ in 0..<5 {
            _ = await fixture.controller.personalNextWordPrediction(
                afterTailWords: ["three", "four"],
                appBundleIdentifier: "com.example.Editor"
            )
        }
        let after = await settledStatus(fixture.controller).snapshot
        #expect(after == before)
    }

    @Test("The trained model survives a restart the bounded raw tail could not")
    func trainedModelSurvivesRestartBeyondTheReplayTail() async {
        let fixture = Fixture(enabled: true, modelPersistenceInterval: 0)
        #expect(await settledStatus(fixture.controller).phase == .ready)
        let learned = fixture.event(
            id: "learned",
            text: " alpha beta gamma alpha beta gamma "
        )
        #expect(await fixture.controller.ingest([learned]))
        let saved = await fixture.store.trainedModel
        #expect(saved != nil)
        #expect(saved?.coveredThroughSequence == 1)

        // The raw records roll out of the bounded replay window. Before the
        // trained table was durable this is exactly where learning quietly
        // reset; now only the saved model can carry it across.
        await fixture.store.dropRecords()

        let restarted = fixture.restart()
        #expect(await settledStatus(restarted).phase == .ready)
        let continuation = fixture.event(id: "after-restart", text: " alpha beta ")
        #expect(await restarted.ingest([continuation]))

        var uninterrupted = PersonalNextWordShadow()
        uninterrupted.consume([learned], scoring: true)
        uninterrupted.consume([continuation], scoring: true)
        #expect(await settledStatus(restarted).snapshot == uninterrupted.snapshot)
        #expect(await restarted.personalNextWordPrediction(
            afterTailWords: ["alpha", "beta"],
            appBundleIdentifier: "com.example.Editor"
        ) == uninterrupted.predictNextWord(afterTailWords: ["alpha", "beta"]))
    }

    @Test("Without a saved model the same restart loses what the tail no longer holds")
    func withoutATrainedModelLearningStillResets() async {
        // The control for the test above: the durable table is the only
        // thing standing between a rolled-off tail and a reset model.
        let fixture = Fixture(enabled: true, modelPersistenceInterval: 0)
        #expect(await settledStatus(fixture.controller).phase == .ready)
        await fixture.store.setSaveModelFailure(.corruptStore)
        let learned = fixture.event(
            id: "learned",
            text: " alpha beta gamma alpha beta gamma "
        )

        // A model that cannot be saved must not fail the ingest: the events
        // themselves are durable and the table is derived state.
        #expect(await fixture.controller.ingest([learned]))
        #expect(await fixture.store.trainedModel == nil)
        #expect(fixture.controller.storageHealthSnapshot == .healthy)
        await fixture.store.dropRecords()

        let restarted = fixture.restart()
        #expect(await settledStatus(restarted).snapshot.learnedTransitions == 0)
    }

    @Test("A throttled, stale save is still exact: the log positions after it are replayed")
    func staleSaveIsToppedUpByCoverage() async {
        let fixture = Fixture(enabled: true, modelPersistenceInterval: 3_600)
        #expect(await settledStatus(fixture.controller).phase == .ready)
        let batches = [
            fixture.event(id: "one", text: " alpha beta gamma "),
            fixture.event(id: "two", text: "alpha beta gamma "),
            fixture.event(id: "three", text: "alpha beta delta "),
        ]
        for batch in batches {
            #expect(await fixture.controller.ingest([batch]))
        }
        // One save for three batches — the table is a whole-file record and
        // is not rewritten per keystroke batch.
        #expect(await fixture.store.trainedModelSaves == 1)
        #expect(await fixture.store.trainedModel?.coveredThroughSequence == 1)

        let restarted = fixture.restart(modelPersistenceInterval: 3_600)
        #expect(await settledStatus(restarted).phase == .ready)

        var uninterrupted = PersonalNextWordShadow()
        for batch in batches { uninterrupted.consume([batch], scoring: true) }
        let status = await settledStatus(restarted)
        #expect(status.snapshot.learnedContexts == uninterrupted.snapshot.learnedContexts)
        #expect(status.snapshot.learnedTransitions == uninterrupted.snapshot.learnedTransitions)
        #expect(await restarted.personalNextWordPrediction(
            afterTailWords: ["alpha", "beta"],
            appBundleIdentifier: "com.example.Editor"
        ) == uninterrupted.predictNextWord(afterTailWords: ["alpha", "beta"]))
    }

    @Test("Deleting personalization data deletes the trained model")
    func deletionRemovesTheTrainedModel() async throws {
        let fixture = Fixture(enabled: true, modelPersistenceInterval: 0)
        #expect(await settledStatus(fixture.controller).phase == .ready)
        #expect(await fixture.controller.ingest([
            fixture.event(text: " alpha beta alpha beta "),
        ]))
        #expect(await fixture.store.trainedModel != nil)

        try await fixture.controller.deleteAll()

        #expect(await fixture.store.trainedModel == nil)
        #expect(await fixture.store.events.isEmpty)
        #expect(await fixture.controller.nextWordStatus().snapshot.learnedTransitions == 0)
        let restarted = fixture.restart()
        #expect(await settledStatus(restarted).snapshot.learnedTransitions == 0)
    }

    @Test("An exclusion change refuses a trained model learned under the old scope")
    func exclusionChangeDiscardsTheTrainedModel() async {
        let fixture = Fixture(enabled: true, modelPersistenceInterval: 0)
        #expect(await settledStatus(fixture.controller).phase == .ready)
        #expect(await fixture.controller.ingest([
            fixture.event(text: " alpha beta alpha beta "),
        ]))
        #expect(await fixture.store.trainedModel != nil)
        await fixture.store.dropRecords()

        fixture.controller.excludedApps = ["com.example.Other"]

        let reset = await settledStatus(fixture.controller)
        #expect(reset.snapshot.learnedTransitions == 0)
        #expect(reset.snapshot.opportunities == 0)
    }

    @Test("Disabled Personal History never serves a personal prediction")
    func disabledHistoryNeverServesPersonalPrediction() async {
        let fixture = Fixture(enabled: false)
        let prediction = await fixture.controller.personalNextWordPrediction(
            afterTailWords: ["three", "four"],
            appBundleIdentifier: "com.example.Editor"
        )
        #expect(prediction == nil)
    }

    private actor MemoryStore: PersonalHistoryStore {
        nonisolated let location = URL(fileURLWithPath: "/tmp/tilde-personal-history-test")
        private(set) var records: [PersonalHistoryRecord] = []
        private(set) var checkpoint: PersonalNextWordStoredCheckpoint?
        private(set) var trainedModel: PersonalNextWordStoredModel?
        private(set) var trainedModelSaves = 0
        private var saveModelFailure: PersonalHistoryStorageError?
        private var nextSequence: Int64 = 0
        var events: [PersonalHistoryEvent] { records.flatMap(\.events) }
        private var appendFailure: PersonalHistoryStorageError?
        private var replayFailure: PersonalHistoryStorageError?
        private var replayBlocked: Bool
        private var replayStartWaiters: [CheckedContinuation<Void, Never>] = []
        private var replayWaiters: [CheckedContinuation<Void, Never>] = []
        private var replayStarted = false
        private var appendBlocked: Bool
        private var appendStartWaiters: [CheckedContinuation<Void, Never>] = []
        private var appendWaiters: [CheckedContinuation<Void, Never>] = []
        private var appendStarted = false
        private(set) var replayCount = 0
        private(set) var replayMaximumBytes: [Int64] = []
        private var deleteBlocked: Bool
        private var deleteStartWaiters: [CheckedContinuation<Void, Never>] = []
        private var deleteWaiters: [CheckedContinuation<Void, Never>] = []
        private var deleteStarted = false

        init(
            events: [PersonalHistoryEvent] = [],
            checkpoint: PersonalNextWordStoredCheckpoint? = nil,
            appendFailure: PersonalHistoryStorageError? = nil,
            replayFailure: PersonalHistoryStorageError? = nil,
            replayBlocked: Bool = false,
            appendBlocked: Bool = false,
            deleteBlocked: Bool = false
        ) {
            if !events.isEmpty {
                nextSequence = 1
                records = [PersonalHistoryRecord(sequence: 1, events: events)]
            }
            self.checkpoint = checkpoint
            self.appendFailure = appendFailure
            self.replayFailure = replayFailure
            self.replayBlocked = replayBlocked
            self.appendBlocked = appendBlocked
            self.deleteBlocked = deleteBlocked
        }

        @discardableResult
        func append(
            _ events: [PersonalHistoryEvent],
            checkpoint: PersonalNextWordStoredCheckpoint?
        ) async throws -> Int64 {
            appendStarted = true
            appendStartWaiters.forEach { $0.resume() }
            appendStartWaiters.removeAll()
            if appendBlocked {
                await withCheckedContinuation { appendWaiters.append($0) }
            }
            if let appendFailure { throw appendFailure }
            nextSequence += 1
            records.append(PersonalHistoryRecord(sequence: nextSequence, events: events))
            if let checkpoint { self.checkpoint = checkpoint }
            return nextSequence
        }

        func saveTrainedModel(_ model: PersonalNextWordStoredModel) async throws {
            trainedModelSaves += 1
            if let saveModelFailure { throw saveModelFailure }
            trainedModel = model
        }

        func setSaveModelFailure(_ failure: PersonalHistoryStorageError?) {
            saveModelFailure = failure
        }

        /// What the 4 MiB bounded replay does to an old history: the raw
        /// records roll out of reach while the store lives on.
        func dropRecords() {
            records = []
        }

        func setAppendFailure(_ failure: PersonalHistoryStorageError?) {
            appendFailure = failure
        }

        func setReplayFailure(_ failure: PersonalHistoryStorageError?) {
            replayFailure = failure
        }

        func waitForReplayStart() async {
            guard !replayStarted else { return }
            await withCheckedContinuation { replayStartWaiters.append($0) }
        }

        func releaseReplays() {
            replayBlocked = false
            replayWaiters.forEach { $0.resume() }
            replayWaiters.removeAll()
        }

        func waitForAppendStart() async {
            guard !appendStarted else { return }
            await withCheckedContinuation { appendStartWaiters.append($0) }
        }

        func releaseAppends() {
            appendBlocked = false
            appendWaiters.forEach { $0.resume() }
            appendWaiters.removeAll()
        }

        func waitForDeleteStart() async {
            guard !deleteStarted else { return }
            await withCheckedContinuation { deleteStartWaiters.append($0) }
        }

        func releaseDeletes() {
            deleteBlocked = false
            deleteWaiters.forEach { $0.resume() }
            deleteWaiters.removeAll()
        }

        func loadReplay(maximumBytes: Int64) async throws -> PersonalHistoryReplay {
            replayCount += 1
            replayMaximumBytes.append(maximumBytes)
            replayStarted = true
            replayStartWaiters.forEach { $0.resume() }
            replayStartWaiters.removeAll()
            if replayBlocked {
                await withCheckedContinuation { replayWaiters.append($0) }
            }
            if let replayFailure { throw replayFailure }
            return PersonalHistoryReplay(
                records: records,
                checkpoint: checkpoint,
                trainedModel: trainedModel
            )
        }
        func deleteAll() async throws {
            deleteStarted = true
            deleteStartWaiters.forEach { $0.resume() }
            deleteStartWaiters.removeAll()
            if deleteBlocked {
                await withCheckedContinuation { deleteWaiters.append($0) }
            }
            records = []
            nextSequence = 0
            checkpoint = nil
            trainedModel = nil
        }
        func summary() async throws -> PersonalHistorySummary {
            PersonalHistorySummary(location: location, approximateBytes: Int64(events.count))
        }
    }

    private struct Fixture {
        private static let freshTimestamp = PersonalNextWordShadow.evaluationStartMilliseconds
            + 24 * 60 * 60 * 1_000

        let defaults: UserDefaults
        let store: MemoryStore
        let controller: PersonalHistoryController

        init(
            enabled: Bool = false,
            excludedApps: Set<String> = [],
            preloaded: [(id: String, text: String, app: String)] = [],
            appendFailure: PersonalHistoryStorageError? = nil,
            replayFailure: PersonalHistoryStorageError? = nil,
            blockReplays: Bool = false,
            blockAppends: Bool = false,
            blockDeletes: Bool = false,
            checkpoint: PersonalNextWordStoredCheckpoint? = nil,
            diagnostics: DiagnosticsLog = .shared,
            modelPersistenceInterval: TimeInterval
                = PersonalHistoryController.defaultModelPersistenceInterval
        ) {
            let name = "tilde.tests.personal-history.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            let historyIdentifier = "history"
            defaults.set(
                historyIdentifier,
                forKey: PersonalHistorySettingsContract.historyIdentifierKey
            )
            defaults.set(
                "consent",
                forKey: PersonalHistorySettingsContract.consentIdentifierKey
            )
            defaults.set("experiment", forKey: "PersonalNextWordExperimentIdentifier")
            defaults.set(enabled, forKey: PersonalHistorySettingsContract.enabledKey)
            defaults.set(
                Array(excludedApps).sorted(),
                forKey: PersonalHistorySettingsContract.excludedAppsKey
            )
            store = MemoryStore(
                events: preloaded.map {
                    PersonalHistoryEvent(
                        id: $0.id,
                        timestampMilliseconds: Self.freshTimestamp,
                        historyIdentifier: historyIdentifier,
                        consentIdentifier: "consent",
                        sessionIdentifier: "session",
                        appBundleIdentifier: $0.app,
                        source: .typed,
                        text: $0.text
                    )!
                },
                checkpoint: checkpoint,
                appendFailure: appendFailure,
                replayFailure: replayFailure,
                replayBlocked: blockReplays,
                appendBlocked: blockAppends,
                deleteBlocked: blockDeletes
            )
            controller = PersonalHistoryController(
                store: store,
                settings: TildeSettings(keyboard: defaults),
                diagnostics: diagnostics,
                modelPersistenceInterval: modelPersistenceInterval
            )
        }

        /// A relaunch of Tilde against the same durable store.
        func restart(
            modelPersistenceInterval: TimeInterval = 0
        ) -> PersonalHistoryController {
            PersonalHistoryController(
                store: store,
                settings: TildeSettings(keyboard: defaults),
                modelPersistenceInterval: modelPersistenceInterval
            )
        }

        func event(
            id: String = "event",
            text: String = "hello",
            app: String = "com.example.Editor"
        ) -> PersonalHistoryEvent {
            PersonalHistoryEvent(
                id: id,
                timestampMilliseconds: Self.freshTimestamp,
                historyIdentifier: defaults.string(
                    forKey: PersonalHistorySettingsContract.historyIdentifierKey
                )!,
                consentIdentifier: defaults.string(
                    forKey: PersonalHistorySettingsContract.consentIdentifierKey
                )!,
                sessionIdentifier: "session",
                appBundleIdentifier: app,
                source: .typed,
                text: text
            )!
        }
    }

    private func settledStatus(
        _ controller: PersonalHistoryController
    ) async -> PersonalNextWordShadowStatus {
        for _ in 0..<100 {
            let status = await controller.nextWordStatus()
            if status.phase == .ready || status.phase == .unavailable { return status }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await controller.nextWordStatus()
    }

}
