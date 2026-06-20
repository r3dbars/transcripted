import Foundation

private struct AnalyticsCaptureRequest: Encodable {
    let apiKey: String
    let event: String
    let distinctID: String
    let timestamp: String
    let properties: [String: String]

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case event
        case distinctID = "distinct_id"
        case timestamp
        case properties
    }
}

struct PendingAnalyticsCapture: Codable, Equatable {
    let id: String
    let event: String
    let distinctID: String
    let timestamp: String
    let enqueuedAt: TimeInterval
    var attemptCount: Int
    var nextRetryAt: TimeInterval?
    let properties: [String: String]
}

struct AnalyticsDeliveryBufferStore {
    private struct BufferFile: Codable {
        let version: Int
        let records: [PendingAnalyticsCapture]
    }

    static let fileName = "analytics-delivery-buffer.json"
    static let defaultMaxRecordCount = 100
    static let defaultMaxFileBytes = 64 * 1024
    static let defaultTTL: TimeInterval = 24 * 60 * 60

    let fileURL: URL
    let fileManager: FileManager
    let maxRecordCount: Int
    let maxFileBytes: Int
    let ttl: TimeInterval

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        maxRecordCount: Int = Self.defaultMaxRecordCount,
        maxFileBytes: Int = Self.defaultMaxFileBytes,
        ttl: TimeInterval = Self.defaultTTL
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.maxRecordCount = maxRecordCount
        self.maxFileBytes = maxFileBytes
        self.ttl = ttl
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        fileManager.transcriptedStateDir.appendingPathComponent(fileName, isDirectory: false)
    }

    func load(now: Date = Date()) -> [PendingAnalyticsCapture] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        do {
            let file = try JSONDecoder().decode(BufferFile.self, from: data)
            return cappedRecords(file.records, now: now)
        } catch {
            remove()
            return []
        }
    }

    func save(_ records: [PendingAnalyticsCapture], now: Date = Date()) {
        let capped = cappedRecords(records, now: now)
        guard !capped.isEmpty else {
            remove()
            return
        }

        do {
            try fileManager.createPrivateDirectory(at: fileURL.deletingLastPathComponent())
            let data = try JSONEncoder().encode(BufferFile(version: 1, records: capped))
            try data.write(to: fileURL, options: [.atomic])
            fileManager.restrictFileToOwnerOnly(at: fileURL)
        } catch {
            return
        }
    }

    func remove() {
        try? fileManager.removeItem(at: fileURL)
    }

    func cappedRecords(_ records: [PendingAnalyticsCapture], now: Date = Date()) -> [PendingAnalyticsCapture] {
        let cutoff = now.timeIntervalSince1970 - ttl
        var capped = records
            .filter { $0.enqueuedAt >= cutoff }
            .sorted { lhs, rhs in
                if lhs.enqueuedAt == rhs.enqueuedAt {
                    return lhs.id < rhs.id
                }
                return lhs.enqueuedAt < rhs.enqueuedAt
            }

        if capped.count > maxRecordCount {
            capped = Array(capped.suffix(maxRecordCount))
        }

        while !capped.isEmpty && encodedByteCount(capped) > maxFileBytes {
            capped.removeFirst()
        }

        return capped
    }

    private func encodedByteCount(_ records: [PendingAnalyticsCapture]) -> Int {
        (try? JSONEncoder().encode(BufferFile(version: 1, records: records)).count) ?? Int.max
    }
}

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

enum AnalyticsRuntimeConfiguration {
    static let apiKeyInfoKey = "TranscriptedPostHogAPIKey"
    static let hostInfoKey = "TranscriptedPostHogHost"
    static let buildChannelInfoKey = "TranscriptedBuildChannel"
    static let buildRevisionInfoKey = "TranscriptedBuildRevision"
    static let buildChannelEnvironmentKey = "TRANSCRIPTED_ANALYTICS_BUILD_CHANNEL"
    static let buildRevisionEnvironmentKey = "TRANSCRIPTED_ANALYTICS_BUILD_REVISION"
    private static let localOverridesFileName = "observability-overrides.plist"

    static func apiKey() -> String? {
        firstNonEmpty(
            ProcessInfo.processInfo.environment["POSTHOG_API_KEY"],
            localOverrideValue(forKey: apiKeyInfoKey),
            Bundle.main.object(forInfoDictionaryKey: apiKeyInfoKey) as? String
        )
    }

    static func host() -> String? {
        firstNonEmpty(
            ProcessInfo.processInfo.environment["POSTHOG_HOST"],
            localOverrideValue(forKey: hostInfoKey),
            Bundle.main.object(forInfoDictionaryKey: hostInfoKey) as? String
        )
    }

    static func buildChannel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        firstSafeBuildMetadata(
            environment[buildChannelEnvironmentKey],
            infoDictionary?[buildChannelInfoKey] as? String
        ) ?? "unknown"
    }

    static func buildRevision(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        firstSafeBuildMetadata(
            environment[buildRevisionEnvironmentKey],
            infoDictionary?[buildRevisionInfoKey] as? String
        ) ?? "unknown"
    }

    static func localOverrideValue(forKey key: String) -> String? {
        localOverrideValue(forKey: key, appSupportDirectory: applicationSupportDirectory())
    }

    static func localOverrideValue(forKey key: String, appSupportDirectory: URL) -> String? {
        for url in localOverridesSearchURLs(appSupportDirectory: appSupportDirectory) {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let overrides = plist as? [String: String] else {
                continue
            }
            if let value = firstNonEmpty(overrides[key]) {
                return value
            }
        }

        return nil
    }

    static func localOverridesSearchURLs(appSupportDirectory: URL) -> [URL] {
        [
            appSupportDirectory
                .appendingPathComponent("Transcripted", isDirectory: true)
                .appendingPathComponent(localOverridesFileName),
            appSupportDirectory
                .appendingPathComponent("Draft", isDirectory: true)
                .appendingPathComponent(localOverridesFileName),
        ]
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func firstSafeBuildMetadata(_ candidates: String?...) -> String? {
        candidates
            .compactMap { value -> String? in
                guard let trimmed = firstNonEmpty(value),
                      trimmed.count <= 80,
                      trimmed.allSatisfy({ character in
                          character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
                      }),
                      AnalyticsPayloadSanitizer.sanitizeText(trimmed) == trimmed else {
                    return nil
                }
                return trimmed
            }
            .first
    }
}

final class AnalyticsReporter {
    static let shared = AnalyticsReporter()

    static var isAvailable: Bool {
        shared.apiKey != nil && shared.captureHost != nil
    }

    static func track(_ event: String, properties: [String: String] = [:]) {
        shared.trackEvent(event, properties: properties)
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
            observePreferenceChanges: true
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
        analyticsEnabled: (() -> Bool)? = nil,
        observePreferenceChanges: Bool = false
    ) {
        self.apiKey = apiKey
        self.captureHost = captureHost
        self.session = session
        self.bufferStore = bufferStore
        self.userDefaults = userDefaults
        self.currentDate = currentDate
        self.retryDelay = retryDelay
        self.analyticsEnabled = analyticsEnabled ?? { AnalyticsPreferences.isEnabled(userDefaults: userDefaults) }
        deliveryQueue.setSpecific(key: Self.deliveryQueueSpecificKey, value: true)

        if observePreferenceChanges {
            preferenceObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: userDefaults,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                if !self.analyticsEnabled() {
                    self.clearPendingCaptures()
                }
            }
        }

        if self.analyticsEnabled() {
            flushPendingCaptures()
        } else {
            clearPendingCaptures()
        }
    }

    deinit {
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
    }

    // Config is read once from env/plist/overrides file and cached for the app lifetime.
    private let apiKey: String?
    private let captureHost: String?
    private static let isoDateFormatter = ISO8601DateFormatter()
    private let storageKey = "observability-anonymous-analytics-id"
    private let sessionID = UUID().uuidString
    private let session: URLSession
    private let bufferStore: AnalyticsDeliveryBufferStore
    private let userDefaults: UserDefaults
    private let currentDate: () -> Date
    private let retryDelay: (Int) -> TimeInterval
    private let analyticsEnabled: () -> Bool
    private static let deliveryQueueSpecificKey = DispatchSpecificKey<Bool>()
    private let deliveryQueue = DispatchQueue(label: "com.transcripted.analytics.delivery-buffer")
    private var inFlightCaptureIDs: Set<String> = []
    private var preferenceObserver: NSObjectProtocol?

    private lazy var distinctID: String = {
        if let existing = userDefaults.string(forKey: storageKey) {
            return existing
        }

        let newValue = UUID().uuidString
        userDefaults.set(newValue, forKey: storageKey)
        return newValue
    }()

    func trackEvent(_ event: String, properties: [String: String] = [:]) {
        guard analyticsEnabled() else {
            clearPendingCaptures()
            return
        }

        guard apiKey != nil,
              let captureHost,
              normalizedCaptureURL(from: captureHost) != nil,
              let policy = AnalyticsEventPolicy.policy(forEvent: event) else {
            return
        }

        let sanitizedProperties = AnalyticsPayloadSanitizer.sanitizeProperties(
            properties,
            allowedKeys: policy.allowedProperties
        )

        let eventProperties = Self.captureProperties(
            sanitizedProperties: sanitizedProperties,
            distinctID: distinctID,
            sessionID: sessionID
        )

        let now = currentDate()
        let capture = PendingAnalyticsCapture(
            id: UUID().uuidString,
            event: policy.name,
            distinctID: distinctID,
            timestamp: Self.isoDateFormatter.string(from: now),
            enqueuedAt: now.timeIntervalSince1970,
            attemptCount: 0,
            nextRetryAt: nil,
            properties: eventProperties
        )

        enqueue(capture)
    }

    func flushPendingCapturesForTesting() {
        flushPendingCaptures()
    }

    private func enqueue(_ capture: PendingAnalyticsCapture) {
        syncOnDeliveryQueue {
            guard self.analyticsEnabled() else {
                self.bufferStore.remove()
                return
            }

            let now = self.currentDate()
            var records = self.bufferStore.load(now: now)
            records.append(capture)
            self.bufferStore.save(records, now: now)
            self.flushPendingCapturesLocked()
        }
    }

    private func flushPendingCaptures() {
        deliveryQueue.async {
            self.flushPendingCapturesLocked()
        }
    }

    private func clearPendingCaptures() {
        syncOnDeliveryQueue {
            self.inFlightCaptureIDs.removeAll()
            self.bufferStore.remove()
        }
    }

    private func syncOnDeliveryQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.deliveryQueueSpecificKey) == true {
            work()
        } else {
            deliveryQueue.sync(execute: work)
        }
    }

    private func flushPendingCapturesLocked() {
        guard analyticsEnabled() else {
            inFlightCaptureIDs.removeAll()
            bufferStore.remove()
            return
        }

        guard let apiKey,
              let captureHost,
              let urlString = normalizedCaptureURL(from: captureHost),
              let url = URL(string: urlString) else {
            return
        }

        let now = currentDate()
        let records = bufferStore.load(now: now)
        bufferStore.save(records, now: now)

        for capture in records {
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
            properties: capture.properties
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
            bufferStore.remove()
            return
        }

        let now = currentDate()
        var records = bufferStore.load(now: now)
        guard let index = records.firstIndex(where: { $0.id == capture.id }) else { return }

        switch result {
        case .delivered, .drop:
            records.remove(at: index)
        case .retry:
            var retryCapture = records[index]
            retryCapture.attemptCount += 1
            retryCapture.nextRetryAt = now.addingTimeInterval(retryDelay(retryCapture.attemptCount)).timeIntervalSince1970
            records[index] = retryCapture
        }

        bufferStore.save(records, now: now)
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
