import Foundation

private enum AnalyticsDeliveryResult {
    case delivered
    case retry
    case drop
}

enum AnalyticsDeliveryPolicy {
    fileprivate static func result(response: URLResponse?, error: Error?) -> AnalyticsDeliveryResult {
        if error != nil {
            return .retry
        }

        guard let response = response as? HTTPURLResponse else {
            return .retry
        }

        switch response.statusCode {
        case 200..<300:
            return .delivered
        case 429, 500..<600:
            return .retry
        case 400..<500:
            return .drop
        default:
            return .retry
        }
    }

    static func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 5)
        return min(pow(2.0, Double(exponent)), 60)
    }
}

final class AnalyticsReporter {
    static let shared = AnalyticsReporter()

    static var isAvailable: Bool {
        shared.apiKey != nil && shared.captureHost != nil
    }

    static func track(_ event: String, properties: [String: String] = [:], usageDurationSeconds: Double? = nil) {
        shared.trackEvent(event, properties: properties, usageDurationSeconds: usageDurationSeconds)
    }

    /// Shared bucketing for `duration_ms` string context values (Sentry policy
    /// and reliability packets must emit identical `duration_bucket` values).
    static func durationBucket(fromMilliseconds value: String?) -> String? {
        guard let value,
              let milliseconds = Double(value) else {
            return nil
        }
        return durationBucket(seconds: milliseconds / 1000)
    }

    static func durationBucket(seconds: Double) -> String {
        switch seconds {
        case ..<10:
            return "lt_10s"
        case ..<30:
            return "10_29s"
        case ..<120:
            return "30_119s"
        case ..<600:
            return "2_9m"
        case ..<1800:
            return "10_29m"
        default:
            return "30m_plus"
        }
    }

    /// String-keyed companion to `latencyBucket(milliseconds:)`, mirroring
    /// `durationBucket(fromMilliseconds:)`. Sub-second resolution matters for
    /// start-path timings, where `durationBucket` would collapse everything
    /// under ten seconds into one bucket.
    static func latencyBucket(fromMilliseconds value: String?) -> String? {
        guard let value, let milliseconds = Double(value) else { return nil }
        return latencyBucket(milliseconds: Int(milliseconds.rounded()))
    }

    static func latencyBucket(milliseconds: Int) -> String {
        switch milliseconds {
        case ..<100:
            return "lt_100ms"
        case ..<250:
            return "100_249ms"
        case ..<500:
            return "250_499ms"
        case ..<1_000:
            return "500_999ms"
        case ..<2_000:
            return "1_2s"
        case ..<5_000:
            return "2_5s"
        default:
            return "5s_plus"
        }
    }

    static func wordCountBucket(_ count: Int) -> String {
        switch count {
        case ..<10:
            return "lt_10"
        case ..<50:
            return "10_49"
        case ..<150:
            return "50_149"
        case ..<300:
            return "150_299"
        default:
            return "300_plus"
        }
    }

    static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<1:
            return "0"
        case 1:
            return "1"
        case 2...3:
            return "2_3"
        case 4...9:
            return "4_9"
        default:
            return "10_plus"
        }
    }

    static func queueDepthBucket(_ depth: Int) -> String {
        switch depth {
        case ..<1:
            return "0"
        case 1:
            return "1"
        case 2...3:
            return "2_3"
        default:
            return "4_plus"
        }
    }

    static func defaultProperties(
        distinctID: String,
        sessionID: String,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [String: String] {
        var properties: [String: String] = [
            "distinct_id": distinctID,
            "app_version": infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build_version": infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "build_channel": AnalyticsRuntimeConfiguration.buildChannel(infoDictionary: infoDictionary),
            "build_revision": AnalyticsRuntimeConfiguration.buildRevision(infoDictionary: infoDictionary),
            "os_major": "\(operatingSystemVersion.majorVersion)",
        ]

        let sanitizedSessionID = AnalyticsPayloadSanitizer.sanitizeText(sessionID)
        if !sanitizedSessionID.isEmpty {
            properties["session_id"] = sanitizedSessionID
        }

        return properties
    }

    static func captureProperties(
        sanitizedProperties: [String: String],
        distinctID: String,
        sessionID: String,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [String: String] {
        var eventProperties = defaultProperties(
            distinctID: distinctID,
            sessionID: sessionID,
            infoDictionary: infoDictionary,
            operatingSystemVersion: operatingSystemVersion
        )
        // Caller properties can carry historical build metadata, such as an older
        // build that crashed before the current app launch noticed it.
        for (key, value) in sanitizedProperties {
            eventProperties[key] = value
        }
        return eventProperties
    }

    private convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        self.init(
            apiKey: AnalyticsRuntimeConfiguration.apiKey(),
            captureHost: AnalyticsRuntimeConfiguration.host(),
            session: URLSession(configuration: configuration),
            bufferStore: AnalyticsDeliveryBufferStore(
                fileURL: AnalyticsDeliveryBufferStore.defaultFileURL()
            ),
            userDefaults: .standard,
            observePreferenceChanges: true,
            usageStore: .shared
        )
    }

    init(
        apiKey: String?,
        captureHost: String?,
        session: URLSession,
        bufferStore: AnalyticsDeliveryBufferStore,
        userDefaults: UserDefaults = .standard,
        currentDate: @escaping () -> Date = Date.init,
        retryDelay: @escaping (Int) -> TimeInterval = AnalyticsDeliveryPolicy.retryDelay(afterAttempt:),
        persistDebounceInterval: TimeInterval = AnalyticsReporter.defaultPersistDebounceInterval,
        analyticsEnabled: (() -> Bool)? = nil,
        observePreferenceChanges: Bool = false,
        usageStore: UsageHealthStore? = nil
    ) {
        self.apiKey = apiKey
        self.usageStore = usageStore
        self.captureHost = captureHost
        self.session = session
        self.bufferStore = bufferStore
        self.userDefaults = userDefaults
        self.currentDate = currentDate
        self.retryDelay = retryDelay
        self.persistDebounceInterval = persistDebounceInterval
        self.analyticsEnabled = analyticsEnabled ?? { AnalyticsPreferences.isEnabled(userDefaults: userDefaults) }
        deliveryQueue.setSpecific(key: Self.deliveryQueueSpecificKey, value: true)

        if observePreferenceChanges {
            preferenceObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: userDefaults,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                // Defaults mutations made by the ledger also notify synchronously.
                // Serialize clearing after the writer releases its ledger lock.
                self.deliveryQueue.async { [weak self] in
                    guard let self, !self.analyticsEnabled() else { return }
                    self.clearPendingCaptures()
                }
            }
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: Self.appWillTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Final synchronous persist so debounced buffer writes are not lost on quit.
            self?.enqueueUsageDigests(includeCurrentDay: true)
            self?.persistPendingCapturesNow()
        }

        if usageStore != nil {
            let timer = DispatchSource.makeTimerSource(queue: deliveryQueue)
            timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10)) // leeway lets macOS coalesce the wakeup
            timer.setEventHandler { [weak self] in
                self?.runMinuteTick()
                self?.flushPendingCapturesLocked()
            }
            digestTimer = timer
            timer.resume()
        }
        if self.analyticsEnabled() {
            enqueueUsageDigests(includeCurrentDay: false)
            flushPendingCaptures()
        } else {
            clearPendingCaptures()
        }
    }

    deinit {
        digestTimer?.cancel()
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    let apiKey: String?
    private let usageStore: UsageHealthStore?
    let captureHost: String?
    private static let isoDateFormatter = ISO8601DateFormatter()
    private let sessionID = TelemetryContext.launchSessionID
    private let session: URLSession
    private let bufferStore: AnalyticsDeliveryBufferStore
    let userDefaults: UserDefaults
    let currentDate: () -> Date
    private let retryDelay: (Int) -> TimeInterval
    private let persistDebounceInterval: TimeInterval
    let analyticsEnabled: () -> Bool
    private static let deliveryQueueSpecificKey = DispatchSpecificKey<Bool>()
    private let deliveryQueue = DispatchQueue(label: "com.transcripted.analytics.delivery-buffer")
    private var inFlightCaptureIDs: Set<String> = []
    private var preferenceObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var digestTimer: DispatchSourceTimer?

    // The in-memory buffer is the source of truth after the first load; disk writes
    // are debounced so a burst of tracked events costs one file write, not one per
    // event. All of this state must only be touched on `deliveryQueue`.
    static let defaultPersistDebounceInterval: TimeInterval = 1.0
    // NSApplication.willTerminateNotification's raw name, so this file stays
    // Foundation-only while still catching normal app quits.
    private static let appWillTerminateNotification = Notification.Name("NSApplicationWillTerminateNotification")
    private var pendingCaptures: [PendingAnalyticsCapture] = []
    private var hasLoadedPendingCaptures = false
    private var needsPersist = false
    private var pendingPersistWorkItem: DispatchWorkItem?

    private var distinctID: String { InstallIdentity.id(userDefaults: userDefaults) }

    func trackEvent(_ event: String, properties: [String: String] = [:], usageDurationSeconds: Double? = nil) {
        guard analyticsEnabled() else {
            clearPendingCaptures()
            return
        }

        guard let policy = AnalyticsEventPolicy.policy(forEvent: event) else { return }
        let enrichedProperties = TelemetryContext.enrich(event: event, properties: properties)
        let sanitizedProperties = AnalyticsPayloadSanitizer.sanitizeProperties(
            enrichedProperties,
            allowedKeys: policy.allowedProperties.union(TelemetryContext.keys)
        )
        usageStore?.record(event: event, properties: sanitizedProperties, durationSeconds: usageDurationSeconds, now: currentDate())
        guard apiKey != nil, let captureHost, normalizedCaptureURL(from: captureHost) != nil else { return }

        var eventProperties = Self.captureProperties(
            sanitizedProperties: sanitizedProperties,
            distinctID: distinctID,
            sessionID: sessionID
        )

        let now = currentDate()
        let traits = InstallIdentity.traits(userDefaults: userDefaults, now: now)
        eventProperties.merge(traits) { current, _ in current }
        let capture = PendingAnalyticsCapture(
            id: UUID().uuidString,
            event: policy.name,
            distinctID: distinctID,
            timestamp: Self.isoDateFormatter.string(from: now),
            enqueuedAt: now.timeIntervalSince1970,
            attemptCount: 0,
            nextRetryAt: nil,
            properties: eventProperties,
            personProperties: traits
        )

        enqueue(capture)
    }

    func enqueueUsageDigests(includeCurrentDay: Bool) {
        syncOnDeliveryQueue {
            guard self.analyticsEnabled(), let store = self.usageStore,
                  self.apiKey != nil, let host = self.captureHost,
                  self.normalizedCaptureURL(from: host) != nil,
                  let policy = AnalyticsEventPolicy.policy(forEvent: "usage_digest") else { return }
            let now = self.currentDate()
            self.loadPendingCapturesIfNeededLocked(now: now)
            for digest in store.pendingDigests(includeCurrentDay: includeCurrentDay, now: now) {
                if !self.pendingCaptures.contains(where: { $0.id == digest.id }) {
                    var properties = digest.properties
                    properties["install_uuid"] = self.distinctID
                    let safe = AnalyticsPayloadSanitizer.sanitizeProperties(properties, allowedKeys: policy.allowedProperties)
                    self.pendingCaptures.append(PendingAnalyticsCapture(
                        id: digest.id, event: "usage_digest", distinctID: self.distinctID,
                        timestamp: Self.isoDateFormatter.string(from: now), enqueuedAt: now.timeIntervalSince1970,
                        attemptCount: 0, nextRetryAt: nil,
                        properties: Self.captureProperties(sanitizedProperties: safe, distinctID: self.distinctID, sessionID: self.sessionID),
                        personProperties: InstallIdentity.traits(userDefaults: self.userDefaults, now: now),
                        aggregateProperties: digest.aggregates
                    ))
                    self.pendingCaptures = self.bufferStore.cappedRecords(self.pendingCaptures, now: now)
                    self.needsPersist = true
                }
                guard self.pendingCaptures.contains(where: { $0.id == digest.id }),
                      self.persistPendingCapturesLocked() else { continue }
                store.markDigestEnqueued(id: digest.id)
            }
            self.flushPendingCapturesLocked()
        }
    }

    func flushPendingCapturesForTesting() {
        flushPendingCaptures()
    }

    /// Synchronously persists the in-memory buffer to disk. Called on app
    /// termination so debounced writes are not lost; also usable as a test drain hook.
    /// Blocks until every `track` call made so far has been processed.
    ///
    /// `enqueue` hops onto `deliveryQueue` and re-reads `analyticsEnabled()` on the
    /// far side, so a capture tracked immediately before the preference is flipped
    /// off gets discarded by its own opt-out — which is exactly the opt-out
    /// transition event, the one metric that ordering exists to preserve. The
    /// delivery queue is serial, so a sync barrier after the async enqueue
    /// guarantees the enqueue already ran. Call this before disabling analytics.
    ///
    /// This does not defeat "opt-out purges the buffer": the capture gets its one
    /// delivery attempt while still enabled, and the subsequent preference change
    /// still deletes the retry file and blocks further sends.
    static func drainPendingTrackCalls() {
        shared.persistPendingCapturesNow()
    }

    func persistPendingCapturesNow() {
        syncOnDeliveryQueue {
            self.persistPendingCapturesLocked()
        }
    }

    private func enqueue(_ capture: PendingAnalyticsCapture) {
        // Async so `track` callers (usually the main thread) never block on buffer file I/O.
        deliveryQueue.async {
            guard self.analyticsEnabled() else {
                self.clearBufferedCapturesLocked()
                return
            }

            let now = self.currentDate()
            self.loadPendingCapturesIfNeededLocked(now: now)
            self.pendingCaptures.append(capture)
            self.pendingCaptures = self.bufferStore.cappedRecords(self.pendingCaptures, now: now)
            self.schedulePersistLocked()
            self.flushPendingCapturesLocked()
        }
    }

    private func flushPendingCaptures() {
        deliveryQueue.async {
            self.flushPendingCapturesLocked()
        }
    }

    private func clearPendingCaptures() {
        RetentionTelemetry.clearObservation(userDefaults: userDefaults)
        usageStore?.clear()
        syncOnDeliveryQueue {
            self.inFlightCaptureIDs.removeAll()
            self.clearBufferedCapturesLocked()
        }
    }

    private func loadPendingCapturesIfNeededLocked(now: Date) {
        guard !hasLoadedPendingCaptures else { return }
        pendingCaptures = bufferStore.load(now: now)
        hasLoadedPendingCaptures = true
    }

    private func clearBufferedCapturesLocked() {
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        needsPersist = false
        pendingCaptures = []
        hasLoadedPendingCaptures = true
        bufferStore.remove()
    }

    private func schedulePersistLocked() {
        needsPersist = true
        guard pendingPersistWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.persistPendingCapturesLocked()
        }
        pendingPersistWorkItem = workItem
        deliveryQueue.asyncAfter(deadline: .now() + persistDebounceInterval, execute: workItem)
    }

    @discardableResult
    private func persistPendingCapturesLocked() -> Bool {
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        guard needsPersist else { return true }
        needsPersist = false
        // `save` re-applies TTL/count/byte caps and removes the file when empty, so
        // the on-disk format, owner-only permissions, and cap semantics are unchanged.
        let saved = bufferStore.save(pendingCaptures, now: currentDate())
        needsPersist = !saved
        return saved
    }

    func syncOnDeliveryQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.deliveryQueueSpecificKey) == true {
            work()
        } else {
            deliveryQueue.sync(execute: work)
        }
    }

    private func flushPendingCapturesLocked() {
        guard analyticsEnabled() else {
            inFlightCaptureIDs.removeAll()
            clearBufferedCapturesLocked()
            return
        }

        guard let apiKey,
              let captureHost,
              let urlString = normalizedCaptureURL(from: captureHost),
              let url = URL(string: urlString) else {
            return
        }

        let now = currentDate()
        loadPendingCapturesIfNeededLocked(now: now)
        pendingCaptures = bufferStore.cappedRecords(pendingCaptures, now: now)

        for capture in pendingCaptures {
            guard capture.nextRetryAt.map({ $0 <= now.timeIntervalSince1970 }) ?? true else { continue }
            guard !inFlightCaptureIDs.contains(capture.id) else { continue }

            inFlightCaptureIDs.insert(capture.id)
            send(capture, apiKey: apiKey, url: url)
        }
    }

    private func send(_ capture: PendingAnalyticsCapture, apiKey: String, url: URL) {
        let payload = AnalyticsCaptureRequest(
            apiKey: apiKey,
            event: capture.event,
            distinctID: capture.distinctID,
            timestamp: capture.timestamp,
            properties: capture.properties,
            uuid: capture.id,
            personProperties: capture.personProperties,
            aggregateProperties: capture.aggregateProperties
        )

        guard let data = try? JSONEncoder().encode(payload) else {
            completeDelivery(for: capture, result: .drop)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        session.dataTask(with: request) { [weak self] _, response, error in
            let result = AnalyticsDeliveryPolicy.result(response: response, error: error)
            self?.deliveryQueue.async {
                self?.completeDeliveryLocked(for: capture, result: result)
            }
        }.resume()
    }

    private func completeDelivery(for capture: PendingAnalyticsCapture, result: AnalyticsDeliveryResult) {
        deliveryQueue.async {
            self.completeDeliveryLocked(for: capture, result: result)
        }
    }

    private func completeDeliveryLocked(for capture: PendingAnalyticsCapture, result: AnalyticsDeliveryResult) {
        defer { inFlightCaptureIDs.remove(capture.id) }

        guard analyticsEnabled() else {
            inFlightCaptureIDs.removeAll()
            clearBufferedCapturesLocked()
            return
        }

        let now = currentDate()
        loadPendingCapturesIfNeededLocked(now: now)
        guard let index = pendingCaptures.firstIndex(where: { $0.id == capture.id }) else { return }

        switch result {
        case .delivered, .drop:
            pendingCaptures.remove(at: index)
        case .retry:
            var retryCapture = pendingCaptures[index]
            retryCapture.attemptCount += 1
            retryCapture.nextRetryAt = now.addingTimeInterval(retryDelay(retryCapture.attemptCount)).timeIntervalSince1970
            pendingCaptures[index] = retryCapture
        }

        schedulePersistLocked()
    }

    private func normalizedCaptureURL(from host: String) -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Security: reject non-HTTPS hosts so analytics payloads (including the api_key and
        // distinct_id) cannot be sent over plaintext HTTP or to an arbitrary URI scheme.
        // A tampered Info.plist or a malicious observability-overrides.plist could otherwise
        // redirect analytics to an attacker-controlled endpoint over plain HTTP.
        guard trimmedHost.lowercased().hasPrefix("https://") else {
            return nil
        }
        return "\(trimmedHost)/capture/"
    }
}
