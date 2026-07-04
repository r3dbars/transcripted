import Foundation

struct TimelineObservationFrame: Equatable {
    var capturedAt: Date
    var recognizedTextLines: [String]
    var appName: String?
    var windowTitle: String?
}

protocol TimelineObservationBuilding: Sendable {
    func buildObservations(from frames: [TimelineObservationFrame]) async throws -> [TimelineObservationSegment]
}

actor ObservationBuilder: TimelineObservationBuilding {
    var maxLinesPerFrame: Int
    var maxSegments: Int

    init(maxLinesPerFrame: Int = 8, maxSegments: Int = 5) {
        self.maxLinesPerFrame = maxLinesPerFrame
        self.maxSegments = max(2, maxSegments)
    }

    func buildObservations(from frames: [TimelineObservationFrame]) async throws -> [TimelineObservationSegment] {
        let sorted = frames.sorted { $0.capturedAt < $1.capturedAt }
        guard let first = sorted.first, let last = sorted.last else { return [] }

        let bucketCount = min(maxSegments, max(2, sorted.count))
        let bucketSize = max(1, Int(ceil(Double(sorted.count) / Double(bucketCount))))
        var segments: [TimelineObservationSegment] = []

        var index = 0
        while index < sorted.count {
            let upperBound = min(sorted.count, index + bucketSize)
            let slice = Array(sorted[index..<upperBound])
            let start = slice.first?.capturedAt ?? first.capturedAt
            let end = slice.last?.capturedAt ?? last.capturedAt
            let text = condensedText(for: slice)
            segments.append(
                TimelineObservationSegment(
                    startTs: start,
                    endTs: end > start ? end : start.addingTimeInterval(1),
                    observation: text.isEmpty ? "No readable screen text." : text,
                    appName: slice.last?.appName,
                    windowTitle: slice.last?.windowTitle
                )
            )
            index = upperBound
        }

        return segments
    }

    private func condensedText(for frames: [TimelineObservationFrame]) -> String {
        var previousLine: String?
        var lines: [String] = []
        for frame in frames {
            if let appName = frame.appName, !appName.isEmpty {
                lines.append("App: \(appName)")
            }
            if let windowTitle = frame.windowTitle, !windowTitle.isEmpty {
                lines.append("Window: \(windowTitle)")
            }
            for rawLine in frame.recognizedTextLines.prefix(maxLinesPerFrame) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                guard line != previousLine else { continue }
                lines.append(line)
                previousLine = line
            }
        }
        return Array(lines.prefix(maxLinesPerFrame * max(1, frames.count))).joined(separator: "\n")
    }
}
