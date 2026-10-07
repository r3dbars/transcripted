import Foundation

/// The shared speaker DB that `meeting-series` uses for fresh_db == false meetings.
/// It lives at `<workRoot>/shared-db` and carries voices from one series meeting to
/// the next. A run may keep it only when it is the same series, in the same work
/// root, with the same diarizer and voiceprint settings, and the meetings already in
/// it are exactly the finished ones, in series order with no gap. Anything else
/// starts it empty, or a meeting silently matches voices it should never have heard.
enum LabSharedSpeakerDB {
    static let markerFileName = "lab-shared-db.json"

    /// What the DB was built with. Any difference means the DB can't be reused.
    struct Config: Codable, Equatable {
        var set: String
        var workRoot: String
        /// fresh_db == false meetings, in series order.
        var sharedMeetings: [String]
        var backend: String
        var speakerDBFile: String
        /// Every --embedder-* flag and its value, as given.
        var embedderArgs: [String]
    }

    /// Written into the shared DB folder; `applied` grows as meetings finish.
    struct Marker: Codable, Equatable {
        var config: Config
        var applied: [String]
    }

    enum Decision: Equatable {
        case resumed
        case reset(reason: String)
    }

    static func directory(workRoot: URL) -> URL {
        workRoot.appendingPathComponent("shared-db", isDirectory: true)
    }

    /// The --embedder-* flags and values from a meeting-series command line.
    static func embedderArgs(_ args: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < args.count {
            if args[index].hasPrefix("--embedder-") {
                out.append(args[index])
                if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                    out.append(args[index + 1])
                    index += 1
                }
            }
            index += 1
        }
        return out
    }

    /// Decides whether this run resumes the shared DB, empties it when not, and
    /// leaves a marker for `config`. Call once, before the first meeting runs.
    /// `finished` is the shared meetings that already have a lab_result.json.
    static func prepare(
        workRoot: URL,
        config: Config,
        finished: Set<String>,
        force: Bool,
        fileManager: FileManager = .default
    ) throws -> Decision {
        let dir = directory(workRoot: workRoot)
        let markerURL = dir.appendingPathComponent(markerFileName)
        let marker = (try? Data(contentsOf: markerURL)).flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }
        let decision = resumeDecision(marker: marker, config: config, finished: finished, force: force)
        if case .reset = decision {
            guard try reset(dir, workRoot: workRoot, fileManager: fileManager) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: dir.path])
            }
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let applied = decision == .resumed ? (marker?.applied ?? []) : []
        try writeMarker(Marker(config: config, applied: applied), to: markerURL)
        return decision
    }

    private static func resumeDecision(marker: Marker?, config: Config, finished: Set<String>, force: Bool) -> Decision {
        if force { return .reset(reason: "--force") }
        if finished.isEmpty { return .reset(reason: "no series meeting has finished yet") }
        guard let marker else { return .reset(reason: "no marker says what built it") }
        guard marker.config == config else {
            return .reset(reason: "built with a different set, work root, diarizer, or voiceprint")
        }
        // The DB must hold exactly the finished meetings, as the first N in series order.
        let prefix = Array(config.sharedMeetings.prefix(marker.applied.count))
        guard marker.applied == prefix, Set(marker.applied) == finished else {
            return .reset(reason: "its meetings don't match the finished ones in series order")
        }
        return .resumed
    }

    /// Records that `meeting` has run against the shared DB.
    static func recordApplied(_ meeting: String, workRoot: URL, fileManager: FileManager = .default) {
        let markerURL = directory(workRoot: workRoot).appendingPathComponent(markerFileName)
        guard let data = try? Data(contentsOf: markerURL),
              var marker = try? JSONDecoder().decode(Marker.self, from: data) else { return }
        if !marker.applied.contains(meeting) { marker.applied.append(meeting) }
        try? writeMarker(marker, to: markerURL)
    }

    private static func writeMarker(_ marker: Marker, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: url, options: .atomic)
    }

    /// Removes `directory` only when it sits inside `workRoot` (the root this run
    /// owns). Returns false, deleting nothing, for any path outside it.
    @discardableResult
    static func reset(_ directory: URL, workRoot: URL, fileManager: FileManager = .default) throws -> Bool {
        let root = workRoot.standardizedFileURL.resolvingSymlinksInPath().path
        // Resolve the parent so a not-yet-created target still compares like for like.
        let target = directory.standardizedFileURL
        let resolved = target.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(target.lastPathComponent).path
        guard resolved.hasPrefix(root + "/") else { return false }
        if fileManager.fileExists(atPath: resolved) {
            try fileManager.removeItem(atPath: resolved)
        }
        return true
    }
}

/// Promise checks for the shared-DB reset, run by `autoeval-self-test`.
func runMeetingLabSharedDBSelfTests() {
    func fail(_ what: String) -> Never { die("meeting-lab self-test failed: \(what)") }

    let fm = FileManager.default
    let scratch = fm.temporaryDirectory.appendingPathComponent("MeetingLabSharedDB-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: scratch) }
    do {
        let workRoot = scratch.appendingPathComponent("runs/set", isDirectory: true)
        let shared = LabSharedSpeakerDB.directory(workRoot: workRoot)
        let learned = shared.appendingPathComponent("speakers.sqlite")
        let config = LabSharedSpeakerDB.Config(
            set: "set", workRoot: workRoot.path, sharedMeetings: ["m1", "m2", "m3", "m4"],
            backend: "pyannote", speakerDBFile: "speakers.sqlite", embedderArgs: []
        )

        /// Simulates a run built with `builtWith` that got through `applied`, then
        /// calls prepare the way the next run would, and reports whether the
        /// learned voices survived.
        func rerun(
            applied: [String],
            builtWith: LabSharedSpeakerDB.Config = config,
            now: LabSharedSpeakerDB.Config = config,
            finished: Set<String>,
            force: Bool = false
        ) throws -> (decision: LabSharedSpeakerDB.Decision, kept: Bool) {
            _ = try LabSharedSpeakerDB.prepare(workRoot: workRoot, config: builtWith, finished: [], force: true)
            try fm.createDirectory(at: shared, withIntermediateDirectories: true)
            try Data("learned voices".utf8).write(to: learned)
            for meeting in applied { LabSharedSpeakerDB.recordApplied(meeting, workRoot: workRoot) }
            let decision = try LabSharedSpeakerDB.prepare(workRoot: workRoot, config: now, finished: finished, force: force)
            return (decision, fm.fileExists(atPath: learned.path))
        }

        var outcome = try rerun(applied: ["m1", "m2"], finished: ["m1", "m2"])
        guard outcome.decision == .resumed, outcome.kept else {
            fail("resuming a half-done series threw away the shared DB it needs")
        }
        // The resumed DB must still be resumable after more meetings finish.
        LabSharedSpeakerDB.recordApplied("m3", workRoot: workRoot)
        guard try LabSharedSpeakerDB.prepare(workRoot: workRoot, config: config, finished: ["m1", "m2", "m3"], force: false) == .resumed,
              fm.fileExists(atPath: learned.path) else {
            fail("a second resume lost track of the meetings already in the DB")
        }

        outcome = try rerun(applied: ["m1", "m2"], finished: [])
        guard outcome.decision != .resumed, !outcome.kept else {
            fail("a fresh series run kept a shared DB left by an earlier run")
        }
        outcome = try rerun(applied: ["m1", "m2", "m3", "m4"], finished: ["m1", "m2", "m3", "m4"], force: true)
        guard outcome.decision != .resumed, !outcome.kept else {
            fail("a --force rerun kept the voices the last run learned")
        }
        // m2 failed and its result was deleted to retry it, but m3 and m4 already ran.
        outcome = try rerun(applied: ["m1", "m2", "m3", "m4"], finished: ["m1", "m3", "m4"])
        guard outcome.decision != .resumed, !outcome.kept else {
            fail("retrying a mid-series meeting kept voices from meetings after it")
        }
        var otherEmbedder = config
        otherEmbedder.embedderArgs = ["--embedder-id", "redimnet"]
        otherEmbedder.speakerDBFile = "speakers_redimnet.sqlite"
        outcome = try rerun(applied: ["m1"], now: otherEmbedder, finished: ["m1"])
        guard outcome.decision != .resumed, !outcome.kept else {
            fail("a run with different voiceprint settings resumed a DB built with other ones")
        }
        var otherBackend = config
        otherBackend.backend = "nemotron"
        outcome = try rerun(applied: ["m1"], now: otherBackend, finished: ["m1"])
        guard outcome.decision != .resumed, !outcome.kept else {
            fail("a run with a different diarizer resumed a DB built with another one")
        }
        var otherWorkRoot = config
        otherWorkRoot.workRoot = scratch.appendingPathComponent("runs/other").path
        outcome = try rerun(applied: ["m1"], now: otherWorkRoot, finished: ["m1"])
        guard outcome.decision != .resumed, !outcome.kept else {
            fail("a run with a different --work resumed a DB it did not build")
        }
        // A DB with no marker (an older build, or a copy) can't be trusted.
        try fm.removeItem(at: shared)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("learned voices".utf8).write(to: learned)
        guard try LabSharedSpeakerDB.prepare(workRoot: workRoot, config: config, finished: ["m1"], force: false) != .resumed,
              !fm.fileExists(atPath: learned.path) else {
            fail("resumed a shared DB that has no marker saying what built it")
        }

        guard LabSharedSpeakerDB.embedderArgs(["--series", "s", "--embedder-id", "x", "--force", "--embedder-dim", "192"])
                == ["--embedder-id", "x", "--embedder-dim", "192"] else {
            fail("embedder settings were not captured from the command line")
        }

        let outside = scratch.appendingPathComponent("elsewhere/shared-db", isDirectory: true)
        let outsideFile = outside.appendingPathComponent("speakers.sqlite")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("not ours".utf8).write(to: outsideFile)
        guard try !LabSharedSpeakerDB.reset(outside, workRoot: workRoot), fm.fileExists(atPath: outsideFile.path) else {
            fail("reset deleted a directory outside the run's work root")
        }
        let escape = workRoot.appendingPathComponent("../../elsewhere/shared-db", isDirectory: true)
        guard try !LabSharedSpeakerDB.reset(escape, workRoot: workRoot), fm.fileExists(atPath: outsideFile.path) else {
            fail("reset followed .. out of the run's work root")
        }
        guard try !LabSharedSpeakerDB.reset(workRoot, workRoot: workRoot), fm.fileExists(atPath: workRoot.path) else {
            fail("reset deleted the work root itself")
        }
    } catch {
        fail("fixture: \(error)")
    }
}
