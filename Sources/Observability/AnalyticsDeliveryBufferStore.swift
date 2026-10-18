import Foundation

struct AnalyticsCaptureRequest: Encodable {
    let apiKey: String
    let event: String
    let distinctID: String
    let timestamp: String
    let properties: [String: String]
    var uuid: String? = nil
    var personProperties: [String: String]? = nil
    var aggregateProperties: [String: [String: String]]? = nil

    private struct PropertyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(event, forKey: .event)
        try container.encode(distinctID, forKey: .distinctID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(uuid, forKey: .uuid)
        var values = container.nestedContainer(keyedBy: PropertyKey.self, forKey: .properties)
        for (key, value) in properties {
            try values.encode(value, forKey: PropertyKey(key))
        }
        // PostHog creates/updates an anonymous install profile via $set on capture.
        // Never accept caller-provided person properties or collect an email.
        if let personProperties {
            try values.encode(personProperties, forKey: PropertyKey("$set"))
        }
        if event == "usage_digest", let aggregateProperties {
            for key in ["failures_by_kind", "capture_quality_counts"] {
                if let counts = aggregateProperties[key] {
                    let safeCounts = counts.filter {
                        PayloadSanitizationCore.category($0.key) != nil && ["0", "1", "2_3", "4_9", "10_plus"].contains($0.value)
                    }
                    try values.encode(safeCounts, forKey: PropertyKey(key))
                }
            }
        }
        try values.encode(true, forKey: PropertyKey("$geoip_disable"))
    }

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case event
        case distinctID = "distinct_id"
        case timestamp
        case uuid
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
    var personProperties: [String: String]? = nil
    var aggregateProperties: [String: [String: String]]? = nil
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

    @discardableResult
    func save(_ records: [PendingAnalyticsCapture], now: Date = Date()) -> Bool {
        let capped = cappedRecords(records, now: now)
        guard !capped.isEmpty else {
            remove()
            return !fileManager.fileExists(atPath: fileURL.path)
        }

        do {
            try fileManager.createPrivateDirectory(at: fileURL.deletingLastPathComponent())
            let data = try JSONEncoder().encode(BufferFile(version: 1, records: capped))
            try data.write(to: fileURL, options: [.atomic])
            fileManager.restrictFileToOwnerOnly(at: fileURL)
            return true
        } catch {
            return false
        }
    }

    func remove() {
        try? fileManager.removeItem(at: fileURL)
    }

    func cappedRecords(_ records: [PendingAnalyticsCapture], now: Date = Date()) -> [PendingAnalyticsCapture] {
        let cutoff = now.timeIntervalSince1970 - ttl
        let digestCutoff = now.timeIntervalSince1970 - 14 * 24 * 60 * 60
        var capped = records
            .filter { $0.enqueuedAt >= (["usage_digest", "app_active_day"].contains($0.event) ? digestCutoff : cutoff) }
            .sorted { lhs, rhs in
                if lhs.enqueuedAt == rhs.enqueuedAt {
                    return lhs.id < rhs.id
                }
                return lhs.enqueuedAt < rhs.enqueuedAt
            }

        // Reserve capacity for at most 14 daily rollups. Lifecycle bursts must
        // never evict their only durable copy. The whole file keeps its original
        // count/byte bounds; ordinary events yield space first.
        let retainedDigestIDs = Set(capped.filter { $0.event == "usage_digest" }.suffix(14).map(\.id))
        capped.removeAll { $0.event == "usage_digest" && !retainedDigestIDs.contains($0.id) }
        while capped.count > maxRecordCount {
            let index = capped.firstIndex { $0.event != "usage_digest" } ?? capped.startIndex
            capped.remove(at: index)
        }

        // Encode once up front, then trim by subtracting each removed record's own
        // encoded size instead of re-encoding the entire buffer per removal.
        // JSONEncoder output is compact, so a removed record shrinks the file by its
        // encoded bytes plus one array separator.
        var totalBytes = encodedByteCount(capped)
        while !capped.isEmpty && totalBytes > maxFileBytes {
            let index = capped.firstIndex { $0.event != "usage_digest" } ?? capped.startIndex
            let removed = capped.remove(at: index)
            let removedBytes = (try? JSONEncoder().encode(removed).count) ?? 0
            let separatorBytes = capped.isEmpty ? 0 : 1
            totalBytes = max(0, totalBytes - removedBytes - separatorBytes)
        }

        return capped
    }

    private func encodedByteCount(_ records: [PendingAnalyticsCapture]) -> Int {
        (try? JSONEncoder().encode(BufferFile(version: 1, records: records)).count) ?? Int.max
    }
}
