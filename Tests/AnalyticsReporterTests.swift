import Foundation

func testAnalyticsReporter() {
    runSuite("AnalyticsRuntimeConfiguration prefers Transcripted overrides before legacy Draft") {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AnalyticsReporterTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default

        defer { try? fm.removeItem(at: appSupport) }

        let transcriptedOverrides = appSupport
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("observability-overrides.plist")
        let draftOverrides = appSupport
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("observability-overrides.plist")

        try? fm.createDirectory(at: transcriptedOverrides.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createDirectory(at: draftOverrides.deletingLastPathComponent(), withIntermediateDirectories: true)

        NSDictionary(dictionary: [
            AnalyticsRuntimeConfiguration.apiKeyInfoKey: "transcripted-key",
        ]).write(to: transcriptedOverrides, atomically: true)
        NSDictionary(dictionary: [
            AnalyticsRuntimeConfiguration.apiKeyInfoKey: "draft-key",
        ]).write(to: draftOverrides, atomically: true)

        let value = AnalyticsRuntimeConfiguration.localOverrideValue(
            forKey: AnalyticsRuntimeConfiguration.apiKeyInfoKey,
            appSupportDirectory: appSupport
        )

        assertEqual(value, "transcripted-key", "Transcripted override should win over legacy Draft fallback")
    }

    runSuite("AnalyticsRuntimeConfiguration falls back to Draft overrides for legacy local secrets") {
        let appSupport = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AnalyticsReporterTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default

        defer { try? fm.removeItem(at: appSupport) }

        let draftOverrides = appSupport
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("observability-overrides.plist")

        try? fm.createDirectory(at: draftOverrides.deletingLastPathComponent(), withIntermediateDirectories: true)
        NSDictionary(dictionary: [
            AnalyticsRuntimeConfiguration.hostInfoKey: "https://legacy.example.com",
        ]).write(to: draftOverrides, atomically: true)

        let value = AnalyticsRuntimeConfiguration.localOverrideValue(
            forKey: AnalyticsRuntimeConfiguration.hostInfoKey,
            appSupportDirectory: appSupport
        )

        assertEqual(value, "https://legacy.example.com", "legacy Draft override should still work when Transcripted override is absent")
    }

    runSuite("AnalyticsReporter default properties include exact build metadata") {
        let properties = AnalyticsReporter.defaultProperties(
            distinctID: "anonymous-device",
            sessionID: "session-1",
            infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "456",
                AnalyticsRuntimeConfiguration.buildChannelInfoKey: "local",
                AnalyticsRuntimeConfiguration.buildRevisionInfoKey: "abc123def456",
            ],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        )

        assertEqual(properties["distinct_id"], "anonymous-device", "distinct id should be included")
        assertEqual(properties["app_version"], "1.2.3", "app version should be included")
        assertEqual(properties["build_version"], "456", "build version should be included")
        assertEqual(properties["build_channel"], "local", "build channel should distinguish local builds from shipped builds")
        assertEqual(properties["build_revision"], "abc123def456", "build revision should distinguish same-version main builds")
        assertEqual(properties["os_major"], "15", "OS major version should be included")
        assertEqual(properties["session_id"], "session-1", "sanitized session id should be included")
    }

    runSuite("AnalyticsRuntimeConfiguration accepts safe local build metadata overrides") {
        let info: [String: Any] = [
            AnalyticsRuntimeConfiguration.buildChannelInfoKey: "release",
            AnalyticsRuntimeConfiguration.buildRevisionInfoKey: "abc123def456",
        ]
        let environment = [
            AnalyticsRuntimeConfiguration.buildChannelEnvironmentKey: "local",
            AnalyticsRuntimeConfiguration.buildRevisionEnvironmentKey: "main.20260619",
        ]

        assertEqual(
            AnalyticsRuntimeConfiguration.buildChannel(environment: environment, infoDictionary: info),
            "local",
            "local analytics build channel override should win"
        )
        assertEqual(
            AnalyticsRuntimeConfiguration.buildRevision(environment: environment, infoDictionary: info),
            "main.20260619",
            "local analytics build revision override should win"
        )
    }

    runSuite("AnalyticsRuntimeConfiguration rejects unsafe build metadata") {
        let info: [String: Any] = [
            AnalyticsRuntimeConfiguration.buildChannelInfoKey: "/Users/jane/build",
            AnalyticsRuntimeConfiguration.buildRevisionInfoKey: "person@example.com",
        ]
        let environment = [
            AnalyticsRuntimeConfiguration.buildChannelEnvironmentKey: "release\nbeta",
            AnalyticsRuntimeConfiguration.buildRevisionEnvironmentKey: "sk-private",
        ]

        assertEqual(
            AnalyticsRuntimeConfiguration.buildChannel(environment: environment, infoDictionary: info),
            "unknown",
            "unsafe build channels should not become analytics metadata"
        )
        assertEqual(
            AnalyticsRuntimeConfiguration.buildRevision(environment: environment, infoDictionary: info),
            "unknown",
            "unsafe build revisions should not become analytics metadata"
        )
    }

    runSuite("AnalyticsReporter keeps caller build metadata over current defaults") {
        let properties = AnalyticsReporter.captureProperties(
            sanitizedProperties: [
                "app_version": "1.2.2",
                "build_version": "455",
            ],
            distinctID: "anonymous-device",
            sessionID: "session-1",
            infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "456",
            ],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        )

        assertEqual(properties["app_version"], "1.2.2", "caller app version should win")
        assertEqual(properties["build_version"], "455", "caller build version should win")
        assertEqual(properties["distinct_id"], "anonymous-device", "default distinct id should remain")
        assertEqual(properties["session_id"], "session-1", "default session id should remain")
    }

    runSuite("AnalyticsReporter default properties fall back when build metadata is unavailable") {
        let properties = AnalyticsReporter.defaultProperties(
            distinctID: "anonymous-device",
            sessionID: "session-1",
            infoDictionary: [:],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        )

        assertEqual(properties["app_version"], "unknown", "missing app version should not remove default metadata")
        assertEqual(properties["build_version"], "unknown", "missing build version should not remove default metadata")
        assertEqual(properties["build_channel"], "unknown", "missing build channel should not remove default metadata")
        assertEqual(properties["build_revision"], "unknown", "missing build revision should not remove default metadata")
        assertEqual(properties["os_major"], "15", "OS major version should still be present")
    }

    runSuite("AnalyticsReporter default properties trim session identifiers") {
        let properties = AnalyticsReporter.defaultProperties(
            distinctID: "anonymous-device",
            sessionID: "  session-1  ",
            infoDictionary: [:],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        )

        assertEqual(properties["session_id"], "session-1", "session identifiers should be trimmed before analytics capture")
    }

    runSuite("AnalyticsReporter default properties omit blank session identifiers") {
        let properties = AnalyticsReporter.defaultProperties(
            distinctID: "anonymous-device",
            sessionID: "   ",
            infoDictionary: [:],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        )

        assertNil(properties["session_id"], "blank session identifiers should not be sent as analytics metadata")
    }

    runSuite("AnalyticsReporter default properties cap long session identifiers") {
        let longSessionID = String(repeating: "session-fragment-", count: 8)
        let properties = AnalyticsReporter.defaultProperties(
            distinctID: "anonymous-device",
            sessionID: longSessionID,
            infoDictionary: [:],
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        )

        let sessionID = properties["session_id"] ?? ""
        assertTrue(sessionID.count <= 83, "session identifiers should honor the analytics value cap")
        assertTrue(sessionID.hasSuffix("..."), "capped session identifiers should keep the truncation marker")
    }

    runSuite("AnalyticsReporter wordCountBucket keeps tiny captures coarse") {
        assertEqual(
            AnalyticsReporter.wordCountBucket(5),
            "lt_10",
            "tiny dictations and meetings should stay in the smallest coarse bucket"
        )
    }

    runSuite("AnalyticsReporter wordCountBucket switches buckets at exact boundaries") {
        assertEqual(AnalyticsReporter.wordCountBucket(10), "10_49", "ten words should enter the next bucket")
        assertEqual(AnalyticsReporter.wordCountBucket(50), "50_149", "fifty words should enter the midrange bucket")
        assertEqual(AnalyticsReporter.wordCountBucket(150), "150_299", "one hundred fifty words should enter the long-capture bucket")
    }

    runSuite("AnalyticsReporter wordCountBucket keeps upper edges in their current bucket") {
        assertEqual(AnalyticsReporter.wordCountBucket(49), "10_49", "forty-nine words should stay below the midrange bucket")
        assertEqual(AnalyticsReporter.wordCountBucket(149), "50_149", "one hundred forty-nine words should stay in the midrange bucket")
        assertEqual(AnalyticsReporter.wordCountBucket(299), "150_299", "two hundred ninety-nine words should stay below the capped bucket")
    }

    runSuite("AnalyticsReporter wordCountBucket caps long transcripts") {
        assertEqual(
            AnalyticsReporter.wordCountBucket(300),
            "300_plus",
            "three hundred or more words should be bucketed instead of exposing raw length"
        )
        assertEqual(
            AnalyticsReporter.wordCountBucket(5_000),
            "300_plus",
            "large transcripts should stay in the same coarse analytics bucket"
        )
    }

    runSuite("AnalyticsReporter wordCountBucket treats invalid negative counts as tiny") {
        assertEqual(
            AnalyticsReporter.wordCountBucket(-4),
            "lt_10",
            "invalid negative word counts should fail closed to the smallest bucket"
        )
    }

    runSuite("AnalyticsReporter countBucket keeps zero start attempts explicit") {
        assertEqual(
            AnalyticsReporter.countBucket(0),
            "0",
            "start-failure telemetry should preserve that no recording attempt ran"
        )
    }

    runSuite("AnalyticsReporter countBucket preserves a single start attempt") {
        assertEqual(
            AnalyticsReporter.countBucket(1),
            "1",
            "one failed recording attempt should stay distinguishable from retry loops"
        )
    }

    runSuite("AnalyticsReporter countBucket groups midrange retry attempts") {
        assertEqual(AnalyticsReporter.countBucket(2), "2_3", "two attempts should enter the first retry bucket")
        assertEqual(AnalyticsReporter.countBucket(3), "2_3", "three attempts should stay in the first retry bucket")
        assertEqual(AnalyticsReporter.countBucket(4), "4_9", "four attempts should enter the repeated retry bucket")
        assertEqual(AnalyticsReporter.countBucket(9), "4_9", "nine attempts should remain below the high retry bucket")
    }

    runSuite("AnalyticsReporter countBucket caps unexpected retry spikes") {
        assertEqual(
            AnalyticsReporter.countBucket(10),
            "10_plus",
            "ten or more failed starts should be bucketed instead of exposing raw counts"
        )
        assertEqual(
            AnalyticsReporter.countBucket(37),
            "10_plus",
            "large retry spikes should stay privacy-safe and dashboard-stable"
        )
    }

    runSuite("AnalyticsReporter queueDepthBucket keeps empty meeting queues explicit") {
        assertEqual(
            AnalyticsReporter.queueDepthBucket(0),
            "0",
            "empty meeting queues should stay distinguishable from queued work"
        )
    }

    runSuite("AnalyticsReporter queueDepthBucket preserves a single queued job") {
        assertEqual(
            AnalyticsReporter.queueDepthBucket(1),
            "1",
            "one queued meeting job should stay visible as a single-job backlog"
        )
    }

    runSuite("AnalyticsReporter queueDepthBucket groups small meeting backlogs") {
        assertEqual(AnalyticsReporter.queueDepthBucket(2), "2_3", "two queued meeting jobs should enter the small backlog bucket")
        assertEqual(AnalyticsReporter.queueDepthBucket(3), "2_3", "three queued meeting jobs should stay in the small backlog bucket")
    }

    runSuite("AnalyticsReporter queueDepthBucket caps larger meeting backlogs") {
        assertEqual(
            AnalyticsReporter.queueDepthBucket(4),
            "4_plus",
            "four or more queued meeting jobs should be bucketed instead of exposing raw depth"
        )
        assertEqual(
            AnalyticsReporter.queueDepthBucket(21),
            "4_plus",
            "large queued meeting backlogs should stay coarse for analytics"
        )
    }

    runSuite("AnalyticsReporter queueDepthBucket treats invalid negative depths as empty") {
        assertEqual(
            AnalyticsReporter.queueDepthBucket(-3),
            "0",
            "invalid negative depths should fail closed to the empty queue bucket"
        )
    }

    runSuite("AnalyticsReporter durationBucket keeps short captures coarse") {
        assertEqual(
            AnalyticsReporter.durationBucket(seconds: 5),
            "lt_10s",
            "short dictation and meeting durations should stay in the shortest coarse bucket"
        )
    }

    runSuite("AnalyticsReporter durationBucket switches buckets at second boundaries") {
        assertEqual(AnalyticsReporter.durationBucket(seconds: 10), "10_29s", "ten seconds should enter the next bucket")
        assertEqual(AnalyticsReporter.durationBucket(seconds: 30), "30_119s", "thirty seconds should enter the next bucket")
        assertEqual(AnalyticsReporter.durationBucket(seconds: 120), "2_9m", "two minutes should enter the minutes bucket")
    }

    runSuite("AnalyticsReporter durationBucket keeps upper edges in their current bucket") {
        assertEqual(AnalyticsReporter.durationBucket(seconds: 29.9), "10_29s", "values below thirty seconds should stay in the second bucket")
        assertEqual(AnalyticsReporter.durationBucket(seconds: 119.9), "30_119s", "values below two minutes should stay in the midrange bucket")
        assertEqual(AnalyticsReporter.durationBucket(seconds: 599.9), "2_9m", "values below ten minutes should stay in the short meeting bucket")
    }

    runSuite("AnalyticsReporter durationBucket caps long sessions") {
        assertEqual(
            AnalyticsReporter.durationBucket(seconds: 1800),
            "30m_plus",
            "thirty minutes or more should stay bucketed instead of exposing raw duration"
        )
        assertEqual(
            AnalyticsReporter.durationBucket(seconds: 7200),
            "30m_plus",
            "multi-hour sessions should stay in the same coarse analytics bucket"
        )
    }

    runSuite("AnalyticsReporter durationBucket treats invalid negative durations as short") {
        assertEqual(
            AnalyticsReporter.durationBucket(seconds: -1),
            "lt_10s",
            "invalid negative durations should fail closed to the shortest duration bucket"
        )
    }

    runSuite("AnalyticsReporter latencyBucket keeps sub-second stop timings visible") {
        assertEqual(AnalyticsReporter.latencyBucket(milliseconds: 0), "lt_100ms", "instant timings should stay in the first latency bucket")
        assertEqual(AnalyticsReporter.latencyBucket(milliseconds: 99), "lt_100ms", "values below one hundred ms should stay in the first latency bucket")
        assertEqual(AnalyticsReporter.latencyBucket(milliseconds: 100), "100_249ms", "one hundred ms should enter the next bucket")
        assertEqual(AnalyticsReporter.latencyBucket(milliseconds: 250), "250_499ms", "two hundred fifty ms should enter the next bucket")
        assertEqual(AnalyticsReporter.latencyBucket(milliseconds: 500), "500_999ms", "five hundred ms should enter the next bucket")
        assertEqual(AnalyticsReporter.latencyBucket(milliseconds: 1_000), "1_2s", "one second should enter the short seconds bucket")
        assertEqual(AnalyticsReporter.latencyBucket(milliseconds: 2_000), "2_5s", "two seconds should enter the slow stop bucket")
        assertEqual(AnalyticsReporter.latencyBucket(milliseconds: 5_000), "5s_plus", "five seconds or more should stay capped")
    }

    runSuite("AnalyticsReporter latencyBucket treats invalid negative timings as fast") {
        assertEqual(
            AnalyticsReporter.latencyBucket(milliseconds: -1),
            "lt_100ms",
            "invalid negative timings should fail closed to the smallest latency bucket"
        )
    }

    runSuite("AnalyticsReporter persists only sanitized allowlisted retry records") {
        let fixture = makeAnalyticsReporterFixture(responses: [.networkFailure])
        defer { fixture.cleanup() }

        fixture.reporter.trackEvent(
            "dictation_completed",
            properties: [
                "trigger": "hotkey",
                "duration_bucket": "30_119s",
                "word_count_bucket": "50_149",
                "audio_path": "/Users/jane/private.wav",
                "meeting_title": "Secret roadmap",
                "speaker_name": "Jane",
                "transcript_text": "private words",
            ]
        )

        assertTrue(
            waitUntil { AnalyticsReporterTestURLProtocol.requestCount() == 1 && loadBufferedAnalyticsCaptures(from: fixture.bufferURL).first?.attemptCount == 1 },
            "failed delivery should leave one persisted retry record"
        )

        let captures = loadBufferedAnalyticsCaptures(from: fixture.bufferURL)
        assertEqual(captures.count, 1, "one failed capture should remain buffered")
        assertEqual(captures.first?.event, "dictation_completed", "buffer should persist the reviewed event name")
        assertEqual(captures.first?.properties["trigger"], "hotkey", "allowlisted properties should survive persistence")
        assertEqual(captures.first?.properties["duration_bucket"], "30_119s", "allowlisted buckets should survive persistence")
        assertNil(captures.first?.properties["audio_path"], "audio paths should never be persisted")
        assertNil(captures.first?.properties["meeting_title"], "meeting titles should never be persisted")
        assertNil(captures.first?.properties["speaker_name"], "speaker names should never be persisted")
        assertNil(captures.first?.properties["transcript_text"], "transcript text should never be persisted")

        let diskJSON = readStringIfPresent(fixture.bufferURL) ?? ""
        assertFalse(diskJSON.contains("test-api-key"), "retry buffer must not persist the PostHog API key")
        assertFalse(diskJSON.contains("posthog.example.com"), "retry buffer must not persist the PostHog host")
        assertFalse(diskJSON.contains("api_key"), "retry buffer must not persist capture request secrets")
        assertFalse(diskJSON.contains("Content-Type"), "retry buffer must not persist HTTP headers")
        assertFalse(diskJSON.contains("/Users/jane/private.wav"), "retry buffer must not persist raw local paths")
        assertFalse(diskJSON.contains("Secret roadmap"), "retry buffer must not persist raw titles")
        assertFalse(diskJSON.contains("private words"), "retry buffer must not persist transcript text")
    }

    runSuite("AnalyticsReporter retries transient failures and deletes after success") {
        let fixture = makeAnalyticsReporterFixture(
            responses: [.status(503), .status(200)],
            retryDelay: { _ in 0 }
        )
        defer { fixture.cleanup() }

        fixture.reporter.trackEvent("app_launched")

        assertTrue(
            waitUntil { AnalyticsReporterTestURLProtocol.requestCount() == 1 && loadBufferedAnalyticsCaptures(from: fixture.bufferURL).first?.attemptCount == 1 },
            "5xx delivery should leave the capture ready for retry"
        )

        fixture.reporter.flushPendingCapturesForTesting()

        assertTrue(
            waitUntil { AnalyticsReporterTestURLProtocol.requestCount() == 2 && !FileManager.default.fileExists(atPath: fixture.bufferURL.path) },
            "successful retry should delete the persisted capture"
        )
    }

    runSuite("AnalyticsReporter drops non-429 4xx responses and retains 429 responses") {
        let badRequest = makeAnalyticsReporterFixture(responses: [.status(400)])
        defer { badRequest.cleanup() }

        badRequest.reporter.trackEvent("app_launched")

        assertTrue(
            waitUntil { AnalyticsReporterTestURLProtocol.requestCount() == 1 && !FileManager.default.fileExists(atPath: badRequest.bufferURL.path) },
            "400 responses should drop the persisted capture"
        )

        let retryAfter429 = makeAnalyticsReporterFixture(
            responses: [.status(429)],
            now: Date(timeIntervalSince1970: 1_000),
            retryDelay: { _ in 30 }
        )
        defer { retryAfter429.cleanup() }

        retryAfter429.reporter.trackEvent("app_launched")

        assertTrue(
            waitUntil { AnalyticsReporterTestURLProtocol.requestCount() == 1 && loadBufferedAnalyticsCaptures(from: retryAfter429.bufferURL).first?.attemptCount == 1 },
            "429 responses should retain the capture"
        )

        let captures = loadBufferedAnalyticsCaptures(from: retryAfter429.bufferURL)
        assertEqual(captures.count, 1, "429 capture should stay buffered")
        assertEqual(captures.first?.nextRetryAt, Optional(1_030.0), "429 capture should honor retry backoff")

        retryAfter429.reporter.flushPendingCapturesForTesting()
        Thread.sleep(forTimeInterval: 0.05)
        assertEqual(AnalyticsReporterTestURLProtocol.requestCount(), 1, "backoff should prevent an immediate retry")
    }

    runSuite("AnalyticsReporter flushes persisted launch captures on reporter initialization") {
        let fixture = makeAnalyticsReporterFixture(responses: [.status(200)], autostart: false)
        defer { fixture.cleanup() }

        fixture.store.save([
            makePendingAnalyticsCapture(event: "app_launched", enqueuedAt: 1_000),
        ], now: Date(timeIntervalSince1970: 1_000))

        fixture.start()

        assertTrue(
            waitUntil { AnalyticsReporterTestURLProtocol.requestCount() == 1 && !FileManager.default.fileExists(atPath: fixture.bufferURL.path) },
            "reporter startup should flush pending launch captures"
        )
    }

    runSuite("AnalyticsReporter opt-out wipes the retry buffer and prevents delivery") {
        let fixture = makeAnalyticsReporterFixture(responses: [.networkFailure], observePreferenceChanges: true)
        defer { fixture.cleanup() }

        fixture.reporter.trackEvent("app_launched")

        assertTrue(
            waitUntil { AnalyticsReporterTestURLProtocol.requestCount() == 1 && loadBufferedAnalyticsCaptures(from: fixture.bufferURL).count == 1 },
            "failed delivery should create a retry file before opt-out"
        )

        AnalyticsPreferences.setEnabled(false, userDefaults: fixture.userDefaults)

        assertTrue(
            waitUntil { !FileManager.default.fileExists(atPath: fixture.bufferURL.path) },
            "analytics opt-out notification should delete the retry file"
        )

        fixture.reporter.trackEvent("app_launched")

        assertTrue(
            waitUntil { !FileManager.default.fileExists(atPath: fixture.bufferURL.path) },
            "analytics opt-out should delete the retry file"
        )
        assertEqual(AnalyticsReporterTestURLProtocol.requestCount(), 1, "opt-out should prevent new delivery attempts")
    }

    runSuite("AnalyticsReporter refuses non-HTTPS PostHog hosts before buffering") {
        let fixture = makeAnalyticsReporterFixture(
            responses: [.status(200)],
            captureHost: "http://posthog.example.com"
        )
        defer { fixture.cleanup() }

        fixture.reporter.trackEvent("app_launched")

        assertEqual(AnalyticsReporterTestURLProtocol.requestCount(), 0, "non-HTTPS hosts should not be contacted")
        assertFalse(FileManager.default.fileExists(atPath: fixture.bufferURL.path), "non-HTTPS hosts should not create retry records")
    }

    runSuite("AnalyticsDeliveryBufferStore caps records, expires stale captures, and recovers from corrupt JSON") {
        let fixture = makeAnalyticsReporterFixture(responses: [], autostart: false)
        defer { fixture.cleanup() }

        let defaultStore = AnalyticsDeliveryBufferStore(fileURL: fixture.bufferURL)
        let records = (0..<105).map { index in
            makePendingAnalyticsCapture(id: "capture-\(index)", enqueuedAt: TimeInterval(index))
        }
        defaultStore.save(records, now: Date(timeIntervalSince1970: 200))

        let capped = defaultStore.load(now: Date(timeIntervalSince1970: 200))
        assertEqual(capped.count, 100, "buffer should cap persisted captures near one hundred records")
        assertEqual(capped.first?.id, "capture-5", "record cap should drop the oldest captures first")

        let tinyStore = AnalyticsDeliveryBufferStore(
            fileURL: fixture.bufferURL,
            maxRecordCount: 100,
            maxFileBytes: 1_200,
            ttl: AnalyticsDeliveryBufferStore.defaultTTL
        )
        tinyStore.save(records, now: Date(timeIntervalSince1970: 200))
        let byteCapped = tinyStore.load(now: Date(timeIntervalSince1970: 200))
        assertTrue(byteCapped.count < 100, "byte cap should drop old records until the JSON file is small")
        assertTrue((try? Data(contentsOf: fixture.bufferURL).count) ?? Int.max <= 1_200, "retry file should stay under the configured byte cap")

        let ttlStore = AnalyticsDeliveryBufferStore(
            fileURL: fixture.bufferURL,
            maxRecordCount: 100,
            maxFileBytes: AnalyticsDeliveryBufferStore.defaultMaxFileBytes,
            ttl: 10
        )
        ttlStore.save([
            makePendingAnalyticsCapture(id: "old", enqueuedAt: 1_000),
            makePendingAnalyticsCapture(id: "fresh", enqueuedAt: 1_016),
        ], now: Date(timeIntervalSince1970: 1_020))
        let ttlCaptures = ttlStore.load(now: Date(timeIntervalSince1970: 1_020))
        assertEqual(ttlCaptures.map(\.id), ["fresh"], "TTL should drop records older than one day in production")

        try? Data("not-json".utf8).write(to: fixture.bufferURL, options: [.atomic])
        assertEqual(defaultStore.load().count, 0, "corrupt retry files should recover as an empty buffer")
        assertFalse(FileManager.default.fileExists(atPath: fixture.bufferURL.path), "corrupt retry files should be deleted")
    }
}

private final class AnalyticsReporterFixture {
    let directory: URL
    let bufferURL: URL
    let store: AnalyticsDeliveryBufferStore
    let userDefaults: UserDefaults
    private let makeReporter: () -> AnalyticsReporter
    private let suiteName: String
    private var startedReporter: AnalyticsReporter?

    var reporter: AnalyticsReporter {
        if let startedReporter {
            return startedReporter
        }
        let reporter = makeReporter()
        startedReporter = reporter
        return reporter
    }

    init(
        directory: URL,
        bufferURL: URL,
        store: AnalyticsDeliveryBufferStore,
        userDefaults: UserDefaults,
        suiteName: String,
        makeReporter: @escaping () -> AnalyticsReporter,
        startedReporter: AnalyticsReporter? = nil
    ) {
        self.directory = directory
        self.bufferURL = bufferURL
        self.store = store
        self.userDefaults = userDefaults
        self.suiteName = suiteName
        self.makeReporter = makeReporter
        self.startedReporter = startedReporter
    }

    func start() {
        _ = reporter
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

private enum AnalyticsReporterTestResponse {
    case status(Int)
    case networkFailure
}

private func makeAnalyticsReporterFixture(
    responses: [AnalyticsReporterTestResponse],
    captureHost: String = "https://posthog.example.com",
    now: Date = Date(timeIntervalSince1970: 2_000),
    retryDelay: @escaping (Int) -> TimeInterval = { _ in 1 },
    analyticsEnabled: (() -> Bool)? = nil,
    observePreferenceChanges: Bool = false,
    autostart: Bool = true
) -> AnalyticsReporterFixture {
    AnalyticsReporterTestURLProtocol.reset(responses: responses)

    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("AnalyticsReporterTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bufferURL = directory.appendingPathComponent(AnalyticsDeliveryBufferStore.fileName)
    let store = AnalyticsDeliveryBufferStore(fileURL: bufferURL)
    let suiteName = "AnalyticsReporterTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AnalyticsReporterTestURLProtocol.self]
    let session = URLSession(configuration: configuration)

    let fixture = AnalyticsReporterFixture(
        directory: directory,
        bufferURL: bufferURL,
        store: store,
        userDefaults: defaults,
        suiteName: suiteName,
        makeReporter: {
            AnalyticsReporter(
                apiKey: "test-api-key",
                captureHost: captureHost,
                session: session,
                bufferStore: store,
                userDefaults: defaults,
                currentDate: { now },
                retryDelay: retryDelay,
                analyticsEnabled: analyticsEnabled,
                observePreferenceChanges: observePreferenceChanges
            )
        }
    )

    if autostart {
        fixture.start()
    }

    return fixture
}

private func makePendingAnalyticsCapture(
    id: String = UUID().uuidString,
    event: String = "app_launched",
    enqueuedAt: TimeInterval = 1_000,
    nextRetryAt: TimeInterval? = nil
) -> PendingAnalyticsCapture {
    PendingAnalyticsCapture(
        id: id,
        event: event,
        distinctID: "anonymous-device",
        timestamp: "2026-06-20T12:00:00Z",
        enqueuedAt: enqueuedAt,
        attemptCount: 0,
        nextRetryAt: nextRetryAt,
        properties: [
            "distinct_id": "anonymous-device",
            "app_version": "1.0",
            "build_version": "1",
            "build_channel": "test",
            "build_revision": "abc123",
            "os_major": "26",
            "session_id": "session-1",
        ]
    )
}

private struct AnalyticsReporterTestBufferFile: Decodable {
    let version: Int
    let records: [PendingAnalyticsCapture]
}

private func loadBufferedAnalyticsCaptures(from url: URL) -> [PendingAnalyticsCapture] {
    guard let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(AnalyticsReporterTestBufferFile.self, from: data) else {
        return []
    }
    return file.records
}

private func readStringIfPresent(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func waitUntil(timeout: TimeInterval = 2, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

private final class AnalyticsReporterTestURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [AnalyticsReporterTestResponse] = []
    private static var requests: [URLRequest] = []

    static func reset(responses: [AnalyticsReporterTestResponse]) {
        lock.lock()
        self.responses = responses
        self.requests = []
        lock.unlock()
    }

    static func requestCount() -> Int {
        lock.lock()
        let count = requests.count
        lock.unlock()
        return count
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = Self.nextResponse(recording: request)
        switch response {
        case .networkFailure:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .status(let status):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func nextResponse(recording request: URLRequest) -> AnalyticsReporterTestResponse {
        lock.lock()
        requests.append(request)
        let response = responses.isEmpty ? .status(200) : responses.removeFirst()
        lock.unlock()
        return response
    }
}
