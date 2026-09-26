import Foundation

/// What the Claude Code mod polls: `session.json` for state and the ghost
/// lines, plus one append-only JSONL file of utterances per meeting.
public struct LiveSession: Codable, Equatable {
    public enum State: String, Codable {
        case idle
        case recording
        case ended
    }

    public var state: State
    public var meetingId: String?
    public var title: String?
    public var source: String?
    public var model: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var updatedAt: Date
    public var utterancesPath: String?
    public var lineCount: Int
    public var audioSeconds: Double
    public var partial: [String: String]
    public var pid: Int32
}

public final class LiveOutput {
    /// Separate from the app's own Application Support folder on purpose: the
    /// helper never writes anywhere Transcripted reads.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptedLive", isDirectory: true)
    }

    public let root: URL
    private var session: LiveSession
    private var handle: FileHandle?
    private var lastSessionWrite = Date.distantPast
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public init(root: URL = LiveOutput.defaultRoot, model: String) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        session = LiveSession(
            state: .idle, meetingId: nil, title: nil, source: nil, model: model,
            startedAt: nil, endedAt: nil, updatedAt: Date(), utterancesPath: nil, lineCount: 0,
            audioSeconds: 0, partial: [:], pid: ProcessInfo.processInfo.processIdentifier
        )
        try writeSession(force: true)
    }

    public var sessionURL: URL { root.appendingPathComponent("session.json") }

    public func begin(meetingId: String, startedAt: Date, title: String?, source: String) throws {
        try? handle?.close()
        let url = root.appendingPathComponent("meetings/\(meetingId).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.handle = handle

        session.state = .recording
        session.meetingId = meetingId
        session.title = title
        session.source = source
        session.startedAt = startedAt
        session.endedAt = nil
        session.utterancesPath = url.path
        session.lineCount = Self.countLines(at: url)
        session.audioSeconds = 0
        session.partial = [:]
        try writeSession(force: true)
    }

    public func append(_ utterance: LiveUtterance) throws {
        guard let handle else { return }
        var line = try encoder.encode(utterance)
        line.append(0x0A)
        try handle.write(contentsOf: line)
        session.lineCount += 1
        session.partial[utterance.speaker] = nil
        try writeSession(force: true)
    }

    /// Ghost lines and the audio clock; written at most four times a second.
    public func update(partials: [String: String], audioSeconds: Double) throws {
        session.partial = partials.filter { !$0.value.isEmpty }
        session.audioSeconds = audioSeconds
        try writeSession(force: false)
    }

    /// Keeps `updatedAt` fresh so the mod can tell a live helper from a dead one.
    public func heartbeat() throws {
        try writeSession(force: Date().timeIntervalSince(lastSessionWrite) > 2)
    }

    public func end() throws {
        try? handle?.close()
        handle = nil
        session.state = .ended
        session.endedAt = Date()
        session.partial = [:]
        try writeSession(force: true)
    }

    public func shutdown() {
        try? handle?.close()
        handle = nil
        if session.state == .recording { session.endedAt = Date() }
        session.state = session.meetingId == nil ? .idle : .ended
        session.partial = [:]
        session.pid = 0
        try? writeSession(force: true)
    }

    private func writeSession(force: Bool) throws {
        let now = Date()
        guard force || now.timeIntervalSince(lastSessionWrite) >= 0.25 else { return }
        session.updatedAt = now
        try encoder.encode(session).write(to: sessionURL, options: .atomic)
        lastSessionWrite = now
    }

    private static func countLines(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }
}
