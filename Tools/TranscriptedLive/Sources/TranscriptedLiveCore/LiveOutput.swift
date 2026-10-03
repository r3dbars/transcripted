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

public enum LiveOutputError: Error, CustomStringConvertible {
    case alreadyRunning(pid: Int32)

    public var description: String {
        switch self {
        case .alreadyRunning(let pid):
            return "another transcripted-live is already running (pid \(pid)); stop it first, since both would write the same session.json"
        }
    }
}

public final class LiveOutput {
    /// Separate from the app's own Application Support folder on purpose: the
    /// helper never writes anywhere Transcripted reads.
    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["TRANSCRIPTED_LIVE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptedLive", isDirectory: true)
    }

    public let root: URL
    private var session: LiveSession
    private var handle: FileHandle?
    private var lastSessionWrite = Date.distantPast
    private let now: () -> Date
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public convenience init(root: URL = LiveOutput.defaultRoot, model: String) throws {
        try self.init(root: root, model: model, now: { Date() })
    }

    init(root: URL, model: String, now: @escaping () -> Date) throws {
        self.root = root
        self.now = now
        try FileManager.default.createDirectory(at: root.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        if let pid = Self.runningHelperPid(sessionURL: root.appendingPathComponent("session.json")) {
            throw LiveOutputError.alreadyRunning(pid: pid)
        }
        session = LiveSession(
            state: .idle, meetingId: nil, title: nil, source: nil, model: model,
            startedAt: nil, endedAt: nil, updatedAt: now(), utterancesPath: nil, lineCount: 0,
            audioSeconds: 0, partial: [:], pid: ProcessInfo.processInfo.processIdentifier
        )
        try writeSession(force: true)
    }

    public var sessionURL: URL { root.appendingPathComponent("session.json") }

    public func begin(meetingId: String, startedAt: Date, title: String?, source: String) throws {
        try? handle?.close()
        // The helper always reads a recording from its first sample, so a
        // restart mid-meeting rewrites the file rather than doubling every line.
        let url = root.appendingPathComponent("meetings/\(meetingId).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        self.handle = handle

        session.state = .recording
        session.meetingId = meetingId
        session.title = title
        session.source = source
        session.startedAt = startedAt
        session.endedAt = nil
        session.utterancesPath = url.path
        session.lineCount = 0
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

    /// The idle heartbeat: at most one session.json write this often. The mod
    /// (claude-mod/hooks/register.tsx) counts a helper as alive for
    /// HELPER_ALIVE_MS = 10 s and a recording as stale after STALE_MS = 15 s,
    /// so keep this well under both. The two ship separately (the helper with
    /// the app, the mod through the marketplace); change them together.
    static let heartbeatSeconds: TimeInterval = 4

    /// Keeps `updatedAt` fresh so the mod can tell a live helper from a dead one.
    /// While recording, `update()` already writes up to four times a second.
    public func heartbeat() throws {
        let elapsed = now().timeIntervalSince(lastSessionWrite)
        // A negative gap means the wall clock jumped back; write rather than stall.
        guard elapsed >= Self.heartbeatSeconds || elapsed < 0 else { return }
        try writeSession(force: true)
    }

    public func end() throws {
        try? handle?.close()
        handle = nil
        session.state = .ended
        session.endedAt = now()
        session.partial = [:]
        try writeSession(force: true)
    }

    public func shutdown() {
        try? handle?.close()
        handle = nil
        if session.state == .recording { session.endedAt = now() }
        session.state = session.meetingId == nil ? .idle : .ended
        session.partial = [:]
        session.pid = 0
        try? writeSession(force: true)
    }

    private func writeSession(force: Bool) throws {
        let time = now()
        guard force || time.timeIntervalSince(lastSessionWrite) >= 0.25 else { return }
        session.updatedAt = time
        try encoder.encode(session).write(to: sessionURL, options: .atomic)
        lastSessionWrite = time
    }

    /// The pid in an existing session.json, if that process is still a
    /// transcripted-live (a crashed helper's pid may belong to something else now).
    static func runningHelperPid(sessionURL: URL) -> Int32? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sessionURL),
              let existing = try? decoder.decode(LiveSession.self, from: data),
              existing.pid > 0, existing.pid != getpid(), kill(existing.pid, 0) == 0 else {
            return nil
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(existing.pid, &path, UInt32(path.count)) > 0 else { return nil }
        return String(cString: path).hasSuffix("/transcripted-live") ? existing.pid : nil
    }

}
