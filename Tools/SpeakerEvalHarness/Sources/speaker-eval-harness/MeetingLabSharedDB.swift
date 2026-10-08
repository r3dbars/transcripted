import Foundation

/// The shared speaker DB that `meeting-series` uses for fresh_db == false meetings.
/// It lives at `<workRoot>/shared-db` and carries voices from one series meeting to
/// the next. A run may keep it only when it was built with this exact setup, no
/// meeting was interrupted mid-run, and the meetings already in it are exactly the
/// finished ones, in series order with no gap. A brand-new run (nothing finished)
/// or `--force` starts it empty. Any other mismatch stops the run and asks for
/// `--force`, instead of running the rest of the series on an empty DB.
enum LabSharedSpeakerDB {
    static let markerFileName = "lab-shared-db.json"

    /// What the DB was built with. Any difference means the DB can't be reused.
    struct Config: Codable, Equatable {
        var set: String
        var workRoot: String
        /// fresh_db == false meetings, in series order.
        var sharedMeetings: [String]
        var speakerDBFile: String
        /// Every meeting-series flag and value except --only, --limit and --force,
        /// grouped per flag and sorted (see `fingerprintArgs`).
        var runArgs: [String]
        /// sha256 of the files those flags (or the lab knobs env var) point at.
        var fileHashes: [String: String]
    }

    /// Written into the shared DB folder. `inProgress` is set while a shared
    /// meeting runs; `applied` grows as each one finishes.
    struct Marker: Codable, Equatable {
        var config: Config
        var applied: [String]
        var inProgress: String?
    }

    enum Decision: Equatable {
        case resumed
        case reset(reason: String)
    }

    /// The DB can't be resumed, but some series meetings already finished and would
    /// be skipped, so running on would build the rest of the series on an empty DB.
    struct ResumeRefused: Error, CustomStringConvertible {
        let reason: String
        var description: String {
            "the shared speaker DB can't be resumed (\(reason)), and finished meetings would be skipped. Rerun with --force to start the series over."
        }
    }

    /// A shared meeting asked to run when it isn't the next one in series order.
    struct OutOfOrder: Error, CustomStringConvertible {
        let meeting: String
        let applied: [String]
        var description: String {
            "\(meeting) isn't the next shared meeting in series order (already in the DB: \(applied)). Run the series in order, or rerun with --force."
        }
    }

    static func directory(workRoot: URL) -> URL {
        workRoot.appendingPathComponent("shared-db", isDirectory: true)
    }

    /// The meeting-series flags that shape what the DB learns: everything except
    /// --only/--limit (which meetings run) and --force. Each flag stays with its
    /// value and the groups are sorted, so flag order doesn't matter.
    static func fingerprintArgs(_ args: [String]) -> [String] {
        let skippedWithValue: Set<String> = ["--only", "--limit"]
        var groups: [[String]] = []
        var index = 0
        while index < args.count {
            var group = [args[index]]
            if args[index].hasPrefix("--"), index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                group.append(args[index + 1])
                index += 1
            }
            index += 1
            if skippedWithValue.contains(group[0]) || group[0] == "--force" {
                // A value-less --force must not swallow the next flag's value.
                if group[0] == "--force", group.count == 2 { groups.append([group[1]]) }
                continue
            }
            groups.append(group)
        }
        return groups.sorted { $0.joined(separator: "\u{0}") < $1.joined(separator: "\u{0}") }.flatMap { $0 }
    }

    /// sha256 of the files whose contents change results: the --embedder-thresholds
    /// JSON and the TRANSCRIPTED_LAB_KNOBS_FILE knobs file. A file that can't be
    /// read hashes as "unreadable".
    static func fileHashes(args: [String], environment: [String: String]) -> [String: String] {
        var files: [String: String] = [:]
        if let index = args.firstIndex(of: "--embedder-thresholds"), index + 1 < args.count {
            files["--embedder-thresholds"] = args[index + 1]
        }
        if let knobs = environment["TRANSCRIPTED_LAB_KNOBS_FILE"], !knobs.isEmpty {
            files["TRANSCRIPTED_LAB_KNOBS_FILE"] = knobs
        }
        var hashes = files.mapValues { path in
            (try? sha256Hex(of: URL(fileURLWithPath: path))) ?? "unreadable"
        }
        // Env overrides that swap the diarizer preset or the embedder change what
        // the DB learns too; record their values as given.
        for key in ["TRANSCRIPTED_NEMOTRON_PRESET", "TRANSCRIPTED_NEMOTRON_EMBEDDER"] {
            if let value = environment[key], !value.isEmpty { hashes["env:" + key] = value }
        }
        return hashes
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
        let marker = readMarker(markerURL)
        let decision = resumeDecision(marker: marker, config: config, finished: finished, force: force)
        if case .reset(let reason) = decision, !force, !finished.isEmpty {
            throw ResumeRefused(reason: reason)
        }
        if case .reset = decision {
            guard try reset(dir, workRoot: workRoot, fileManager: fileManager) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: dir.path])
            }
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let applied = decision == .resumed ? (marker?.applied ?? []) : []
        try writeMarker(Marker(config: config, applied: applied, inProgress: nil), to: markerURL)
        return decision
    }

    private static func resumeDecision(marker: Marker?, config: Config, finished: Set<String>, force: Bool) -> Decision {
        if force { return .reset(reason: "--force") }
        if finished.isEmpty { return .reset(reason: "no series meeting has finished yet") }
        guard let marker else { return .reset(reason: "no marker says what built it") }
        if let interrupted = marker.inProgress {
            return .reset(reason: "\(interrupted) was interrupted mid-run and may have left voices in it")
        }
        guard marker.config == config else {
            return .reset(reason: "it was built with different settings, set, or work root")
        }
        let prefix = Array(config.sharedMeetings.prefix(marker.applied.count))
        guard marker.applied == prefix, Set(marker.applied) == finished else {
            return .reset(reason: "its meetings don't match the finished ones in series order")
        }
        return .resumed
    }

    /// Marks `meeting` as running against the shared DB. Call before the pipeline
    /// can write to it; `recordApplied` clears it. If the run dies in between, the
    /// next run sees it and won't resume.
    static func beginMeeting(_ meeting: String, workRoot: URL) throws {
        let markerURL = directory(workRoot: workRoot).appendingPathComponent(markerFileName)
        guard var marker = readMarker(markerURL) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: markerURL.path])
        }
        // Only the next unapplied meeting in series order may write to the DB, so
        // --only can't skip a meeting whose voices later ones need.
        let shared = marker.config.sharedMeetings
        guard marker.inProgress == nil,
              marker.applied == Array(shared.prefix(marker.applied.count)),
              marker.applied.count < shared.count, shared[marker.applied.count] == meeting else {
            throw OutOfOrder(meeting: meeting, applied: marker.applied)
        }
        marker.inProgress = meeting
        try writeMarker(marker, to: markerURL)
    }

    /// Records that `meeting` has finished against the shared DB.
    static func recordApplied(_ meeting: String, workRoot: URL) throws {
        let markerURL = directory(workRoot: workRoot).appendingPathComponent(markerFileName)
        guard var marker = readMarker(markerURL) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: markerURL.path])
        }
        if !marker.applied.contains(meeting) { marker.applied.append(meeting) }
        if marker.inProgress == meeting { marker.inProgress = nil }
        try writeMarker(marker, to: markerURL)
    }

    private static func readMarker(_ url: URL) -> Marker? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }
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
/// Every failed promise is listed before the command exits nonzero.
func runMeetingLabSharedDBSelfTests() {
    var failures: [String] = []
    func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

    let fm = FileManager.default
    let scratch = fm.temporaryDirectory.appendingPathComponent("MeetingLabSharedDB-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: scratch) }
    do {
        let workRoot = scratch.appendingPathComponent("runs/set", isDirectory: true)
        let shared = LabSharedSpeakerDB.directory(workRoot: workRoot)
        let learned = shared.appendingPathComponent("speakers.sqlite")
        let baseArgs = ["--series", "sim/set", "--backend", "pyannote"]
        let base = LabSharedSpeakerDB.Config(
            set: "set", workRoot: workRoot.path, sharedMeetings: ["m1", "m2", "m3", "m4"],
            speakerDBFile: "speakers.sqlite",
            runArgs: LabSharedSpeakerDB.fingerprintArgs(baseArgs), fileHashes: [:]
        )
        func config(args: [String], hashes: [String: String] = [:]) -> LabSharedSpeakerDB.Config {
            var changed = base
            changed.runArgs = LabSharedSpeakerDB.fingerprintArgs(args)
            changed.fileHashes = hashes
            return changed
        }

        enum Outcome: Equatable { case resumed, reset, refused }
        /// Builds a DB with `builtWith` that got through `applied` (and, if given,
        /// was killed during `interrupted`), then calls prepare the way the next run
        /// would. Returns what happened and whether the learned voices survived.
        func rerun(
            applied: [String],
            interrupted: String? = nil,
            builtWith: LabSharedSpeakerDB.Config = base,
            now: LabSharedSpeakerDB.Config = base,
            finished: Set<String>,
            force: Bool = false
        ) throws -> (outcome: Outcome, kept: Bool) {
            _ = try LabSharedSpeakerDB.prepare(workRoot: workRoot, config: builtWith, finished: [], force: true)
            try Data("learned voices".utf8).write(to: learned)
            for meeting in applied {
                try LabSharedSpeakerDB.beginMeeting(meeting, workRoot: workRoot)
                try LabSharedSpeakerDB.recordApplied(meeting, workRoot: workRoot)
            }
            if let interrupted { try LabSharedSpeakerDB.beginMeeting(interrupted, workRoot: workRoot) }
            let outcome: Outcome
            do {
                let decision = try LabSharedSpeakerDB.prepare(workRoot: workRoot, config: now, finished: finished, force: force)
                outcome = decision == .resumed ? .resumed : .reset
            } catch is LabSharedSpeakerDB.ResumeRefused {
                outcome = .refused
            }
            return (outcome, fm.fileExists(atPath: learned.path))
        }

        var result = try rerun(applied: ["m1", "m2"], finished: ["m1", "m2"])
        check(result == (.resumed, true), "resuming a half-done series threw away the shared DB it needs")
        try LabSharedSpeakerDB.beginMeeting("m3", workRoot: workRoot)
        try LabSharedSpeakerDB.recordApplied("m3", workRoot: workRoot)
        let second = try LabSharedSpeakerDB.prepare(workRoot: workRoot, config: base, finished: ["m1", "m2", "m3"], force: false)
        check(second == .resumed && fm.fileExists(atPath: learned.path),
              "a second resume lost track of the meetings already in the DB")

        // m1 and m2 are in the DB; --only m4 must not run without m3's voices.
        _ = try rerun(applied: ["m1", "m2"], finished: ["m1", "m2"])
        var outOfOrder = false
        do { try LabSharedSpeakerDB.beginMeeting("m4", workRoot: workRoot) }
        catch is LabSharedSpeakerDB.OutOfOrder { outOfOrder = true }
        check(outOfOrder, "a shared meeting ran out of series order (m4 before m3)")

        result = try rerun(applied: ["m1", "m2"], finished: [])
        check(result == (.reset, false), "a fresh series run kept a shared DB left by an earlier run")
        result = try rerun(applied: ["m1", "m2", "m3", "m4"], finished: ["m1", "m2", "m3", "m4"], force: true)
        check(result == (.reset, false), "a --force rerun kept the voices the last run learned")

        // m3 was killed after writing voices, before its lab_result.json.
        result = try rerun(applied: ["m1", "m2"], interrupted: "m3", finished: ["m1", "m2"])
        check(result.outcome != .resumed, "resumed on a DB holding a meeting that was interrupted mid-run")
        result = try rerun(applied: ["m1", "m2"], interrupted: "m3", finished: ["m1", "m2"], force: true)
        check(result == (.reset, false), "--force kept a DB holding an interrupted meeting")

        // Anything that can't resume while finished meetings exist must stop and ask
        // for --force, leaving the DB alone, not run the rest on an empty DB.
        result = try rerun(applied: ["m1", "m2", "m3", "m4"], finished: ["m1", "m3", "m4"])
        check(result == (.refused, true), "retrying a mid-series meeting without --force did not stop and ask for --force")
        result = try rerun(applied: ["m1"], now: config(args: baseArgs + ["--embedder-id", "redimnet"]), finished: ["m1"])
        check(result == (.refused, true), "different voiceprint settings without --force did not stop and ask for --force")
        result = try rerun(applied: ["m1"], now: config(args: ["--series", "sim/set", "--backend", "nemotron"]), finished: ["m1"])
        check(result == (.refused, true), "a different diarizer without --force did not stop and ask for --force")
        result = try rerun(applied: ["m1"], now: config(args: baseArgs + ["--calendar-naming"]), finished: ["m1"])
        check(result == (.refused, true), "turning on --calendar-naming did not invalidate the shared DB")
        result = try rerun(applied: ["m1"], builtWith: config(args: baseArgs, hashes: ["--embedder-thresholds": "aaa"]),
                           now: config(args: baseArgs, hashes: ["--embedder-thresholds": "bbb"]), finished: ["m1"])
        check(result == (.refused, true), "edited --embedder-thresholds contents did not invalidate the shared DB")
        var otherWorkRoot = base
        otherWorkRoot.workRoot = scratch.appendingPathComponent("runs/other").path
        result = try rerun(applied: ["m1"], now: otherWorkRoot, finished: ["m1"])
        check(result == (.refused, true), "a different --work without --force did not stop and ask for --force")

        // A DB with no marker (an older build, or a copy) can't be trusted.
        try fm.removeItem(at: shared)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("learned voices".utf8).write(to: learned)
        var refused = false
        do { _ = try LabSharedSpeakerDB.prepare(workRoot: workRoot, config: base, finished: ["m1"], force: false) }
        catch is LabSharedSpeakerDB.ResumeRefused { refused = true }
        check(refused && fm.fileExists(atPath: learned.path), "resumed or emptied a shared DB with no marker instead of asking for --force")

        // Fingerprint: which meetings run doesn't matter; everything else does, in any order.
        check(LabSharedSpeakerDB.fingerprintArgs(["--backend", "nemotron", "--only", "m2", "--limit", "3", "--force", "--calendar-naming"])
                == LabSharedSpeakerDB.fingerprintArgs(["--calendar-naming", "--backend", "nemotron"]),
              "--only/--limit/--force or flag order changed the shared-DB fingerprint")
        for flags in [["--separation", "lab"], ["--sep-threshold", "0.7"], ["--no-invite"], ["--speaker-hint", "oracle"],
                      ["--embedder-thresholds", "t.json"]] {
            check(LabSharedSpeakerDB.fingerprintArgs(baseArgs + flags) != LabSharedSpeakerDB.fingerprintArgs(baseArgs),
                  "\(flags[0]) was left out of the shared-DB fingerprint")
        }
        let thresholds = scratch.appendingPathComponent("thresholds.json")
        let knobs = scratch.appendingPathComponent("knobs.json")
        try Data("{\"match\":0.5}".utf8).write(to: thresholds)
        try Data("{\"k\":1}".utf8).write(to: knobs)
        let thresholdArgs = ["--embedder-thresholds", thresholds.path]
        let env = ["TRANSCRIPTED_LAB_KNOBS_FILE": knobs.path]
        let before = LabSharedSpeakerDB.fileHashes(args: thresholdArgs, environment: env)
        try Data("{\"match\":0.6}".utf8).write(to: thresholds)
        let afterThresholds = LabSharedSpeakerDB.fileHashes(args: thresholdArgs, environment: env)
        try Data("{\"k\":2}".utf8).write(to: knobs)
        let afterKnobs = LabSharedSpeakerDB.fileHashes(args: thresholdArgs, environment: env)
        check(!before.isEmpty && before != afterThresholds, "editing the --embedder-thresholds file didn't change its hash")
        check(afterThresholds != afterKnobs, "editing the lab knobs file didn't change its hash")

        let outside = scratch.appendingPathComponent("elsewhere/shared-db", isDirectory: true)
        let outsideFile = outside.appendingPathComponent("speakers.sqlite")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("not ours".utf8).write(to: outsideFile)
        check(try !LabSharedSpeakerDB.reset(outside, workRoot: workRoot) && fm.fileExists(atPath: outsideFile.path),
              "reset deleted a directory outside the run's work root")
        let escape = workRoot.appendingPathComponent("../../elsewhere/shared-db", isDirectory: true)
        check(try !LabSharedSpeakerDB.reset(escape, workRoot: workRoot) && fm.fileExists(atPath: outsideFile.path),
              "reset followed .. out of the run's work root")
        check(try !LabSharedSpeakerDB.reset(workRoot, workRoot: workRoot) && fm.fileExists(atPath: workRoot.path),
              "reset deleted the work root itself")
    } catch {
        failures.append("fixture: \(error)")
    }
    if !failures.isEmpty {
        die("meeting-lab self-test failed:\n  - " + failures.joined(separator: "\n  - "))
    }
}
