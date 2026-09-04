import Foundation

public struct LabReportStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL = LabPaths.reportsRoot()) {
        self.rootDirectory = rootDirectory
    }

    @discardableResult
    public func save(_ report: LabRunReport, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let filename = "\(formatter.string(from: report.startedAt))-\(report.id.uuidString.lowercased()).json"
        let url = rootDirectory.appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    public func loadAll(fileManager: FileManager = .default) throws -> [LabRunReport] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(LabRunReport.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    public func load(id: UUID, fileManager: FileManager = .default) throws -> LabRunReport {
        if let report = try loadAll(fileManager: fileManager).first(where: { $0.id == id }) {
            return report
        }
        throw LabRunnerError.reportNotFound(id.uuidString)
    }

    public func delete(id: UUID, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
        for url in try fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "json",
                  url.lastPathComponent.contains(id.uuidString.lowercased()) else { continue }
            try fileManager.removeItem(at: url)
        }
    }
}

public enum LabReportComparator {
    public static func compare(baseline: LabRunReport, candidate: LabRunReport) -> LabRunComparison {
        let baselineMetrics = Dictionary(uniqueKeysWithValues: baseline.metrics.map { ($0.key, $0) })
        let deltas = candidate.metrics.compactMap { metric -> LabMetricDelta? in
            guard let prior = baselineMetrics[metric.key], prior.unit == metric.unit else { return nil }
            let delta = metric.value - prior.value
            let percent = prior.value == 0 ? nil : delta / abs(prior.value) * 100
            return LabMetricDelta(
                key: metric.key,
                label: metric.label,
                baseline: prior.value,
                candidate: metric.value,
                delta: delta,
                percentChange: percent,
                unit: metric.unit
            )
        }.sorted { $0.label < $1.label }
        let baselineFailures = Set(baseline.scorecard.hardGateFailures)
        let candidateFailures = Set(candidate.scorecard.hardGateFailures)
        return LabRunComparison(
            baselineID: baseline.id,
            candidateID: candidate.id,
            scoreDelta: scoreDelta(baseline.scorecard.overallScore, candidate.scorecard.overallScore),
            metricDeltas: deltas,
            newHardGateFailures: Array(candidateFailures.subtracting(baselineFailures)).sorted(),
            resolvedHardGateFailures: Array(baselineFailures.subtracting(candidateFailures)).sorted()
        )
    }

    private static func scoreDelta(_ baseline: Int?, _ candidate: Int?) -> Int? {
        guard let baseline, let candidate else { return nil }
        return candidate - baseline
    }
}
