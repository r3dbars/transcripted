import Foundation

enum LiveMeetingTrack: String, Codable, Sendable, CaseIterable {
    case microphone
    case system
}

struct LiveMeetingTranscriptSegment: Sendable, Equatable {
    let sequence: Int
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let source: LiveMeetingTrack
    let text: String
    let provisional: Bool = true

    var payload: [String: Any] {
        ["sequence": sequence, "start_seconds": startSeconds, "end_seconds": endSeconds,
         "source": source.rawValue, "text": text, "provisional": true]
    }
}

/// A bounded, disposable preview. It never writes a canonical transcript.
struct LiveMeetingTranscriptState {
    private(set) var segments: [LiveMeetingTranscriptSegment] = []
    private(set) var latestSequence = 0
    let maximumSegments: Int
    let maximumCharacters: Int

    init(maximumSegments: Int = 100, maximumCharacters: Int = 24_000) {
        self.maximumSegments = max(1, maximumSegments)
        self.maximumCharacters = max(1, maximumCharacters)
    }

    mutating func append(text: String, startSeconds: TimeInterval, endSeconds: TimeInterval, source: LiveMeetingTrack) {
        var trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(min(2_000, maximumCharacters)))
        guard !trimmed.isEmpty, startSeconds.isFinite, endSeconds.isFinite else { return }
        if let previous = segments.last(where: { $0.source == source }), startSeconds < previous.endSeconds {
            trimmed = Self.removingOverlap(previous: previous.text, current: trimmed)
        }
        guard !trimmed.isEmpty else { return }
        latestSequence += 1
        segments.append(LiveMeetingTranscriptSegment(sequence: latestSequence, startSeconds: max(0, startSeconds),
            endSeconds: max(max(0, startSeconds), endSeconds), source: source, text: trimmed))
        while segments.count > maximumSegments || segments.reduce(0, { $0 + $1.text.count }) > maximumCharacters {
            segments.removeFirst()
        }
    }

    mutating func clear() {
        segments.removeAll()
        // Keep sequence monotonic when sharing is disabled and enabled again.
    }

    func window(afterSequence: Int, limit: Int) -> [LiveMeetingTranscriptSegment] {
        Array(segments.lazy.filter { $0.sequence > max(0, afterSequence) }.prefix(min(max(1, limit), 50)))
    }

    /// Only overlapping audio from the same track may remove a repeated prefix.
    /// Two matching words are required, so separate short replies survive.
    private static func removingOverlap(previous: String, current: String) -> String {
        let earlier = previous.split(whereSeparator: \.isWhitespace)
        let later = current.split(whereSeparator: \.isWhitespace)
        let maximum = min(8, min(earlier.count, later.count))
        guard maximum >= 2 else { return current }
        func normalized(_ token: Substring) -> String {
            token.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        for count in stride(from: maximum, through: 2, by: -1) {
            let suffix = earlier.suffix(count).map(normalized)
            let prefix = later.prefix(count).map(normalized)
            if !suffix.contains(""), suffix == prefix {
                return later.dropFirst(count).joined(separator: " ")
            }
        }
        return current
    }
}

struct LiveMeetingAudioWindow: Sendable {
    let sessionID: UUID
    let source: LiveMeetingTrack
    let startSeconds: TimeInterval
    let samples: [Float]
    var endSeconds: TimeInterval { startSeconds + Double(samples.count) / 16_000 }
}

/// Called only off the real-time audio thread. The preview can fall behind,
/// but retains at most six four-second windows and one partial per track.
final class LiveMeetingAudioInbox: @unchecked Sendable {
    private struct Track {
        var samples: [Float] = []
        var startSeconds: TimeInterval = 0
    }
    private let lock = NSLock()
    private var sessionID: UUID?
    private var previewEpoch: UInt64 = 0
    private var origin: TimeInterval = 0
    private var accepting = false
    private var tracks: [LiveMeetingTrack: Track] = [:]
    private var ready: [LiveMeetingAudioWindow] = []
    private var droppedWindows = 0
    private let windowSamples: Int
    private let overlapSamples: Int
    private let maximumWindows: Int

    init(windowSamples: Int = 64_000, overlapSamples: Int = 8_000, maximumWindows: Int = 6) {
        self.windowSamples = max(16_000, windowSamples)
        self.overlapSamples = min(max(0, overlapSamples), max(16_000, windowSamples) / 2)
        self.maximumWindows = max(1, maximumWindows)
    }

    func begin(sessionID: UUID, origin: TimeInterval, previewEpoch: UInt64) {
        lock.withLock {
            self.sessionID = sessionID
            self.previewEpoch = previewEpoch
            self.origin = origin
            accepting = true
            tracks.removeAll()
            ready.removeAll()
            droppedWindows = 0
        }
    }

    func append(samples: [Float], source: LiveMeetingTrack, capturedAt: TimeInterval, expectedEpoch: UInt64) {
        guard !samples.isEmpty, samples.count <= 160_000, capturedAt.isFinite else { return }
        lock.withLock {
            // Conversion can outlive a sharing toggle. Reject the producer's
            // old admission lease while holding the same lock as begin/cancel.
            guard accepting, previewEpoch == expectedEpoch, let sessionID else { return }
            var track = tracks[source] ?? Track()
            let bufferStart = max(0, capturedAt - origin - Double(samples.count) / 16_000)
            if track.samples.isEmpty { track.startSeconds = bufferStart }
            // A route outage is a real timeline gap, not contiguous speech.
            if !track.samples.isEmpty,
               bufferStart - (track.startSeconds + Double(track.samples.count) / 16_000) > 0.75 {
                enqueuePartial(track, sessionID: sessionID, source: source)
                track = Track(samples: [], startSeconds: bufferStart)
            }
            track.samples.append(contentsOf: samples)
            while track.samples.count >= windowSamples {
                enqueue(LiveMeetingAudioWindow(sessionID: sessionID, source: source,
                    startSeconds: track.startSeconds, samples: Array(track.samples.prefix(windowSamples))))
                let stride = windowSamples - overlapSamples
                track.samples.removeFirst(stride)
                track.startSeconds += Double(stride) / 16_000
            }
            tracks[source] = track
        }
    }

    func finish() {
        lock.withLock {
            accepting = false
            guard let sessionID else { return }
            for source in LiveMeetingTrack.allCases {
                if let track = tracks[source] { enqueuePartial(track, sessionID: sessionID, source: source) }
            }
            tracks.removeAll()
        }
    }

    func cancel() {
        lock.withLock {
            accepting = false
            sessionID = nil
            tracks.removeAll()
            ready.removeAll()
        }
    }

    func take() -> LiveMeetingAudioWindow? {
        lock.withLock {
            guard !ready.isEmpty else { return nil }
            let index = ready.indices.min { ready[$0].startSeconds < ready[$1].startSeconds }!
            return ready.remove(at: index)
        }
    }

    var dropCount: Int { lock.withLock { droppedWindows } }
    var pendingWindowCount: Int { lock.withLock { ready.count } }

    private func enqueuePartial(_ track: Track, sessionID: UUID, source: LiveMeetingTrack) {
        guard track.samples.count >= 8_000, track.samples.count > overlapSamples else { return }
        enqueue(LiveMeetingAudioWindow(sessionID: sessionID, source: source,
            startSeconds: track.startSeconds, samples: track.samples))
    }

    private func enqueue(_ window: LiveMeetingAudioWindow) {
        if ready.count >= maximumWindows {
            ready.removeFirst()
            droppedWindows += 1
        }
        ready.append(window)
    }
}
