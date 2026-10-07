import Foundation

/// The shared speaker DB that `meeting-series` uses for fresh_db == false meetings.
/// It lives at `<workRoot>/shared-db` and carries voices from one series meeting to
/// the next. A resumed run must keep it; any other run must start it empty, or the
/// first meeting silently matches voices the last run learned.
enum LabSharedSpeakerDB {
    static func directory(workRoot: URL) -> URL {
        workRoot.appendingPathComponent("shared-db", isDirectory: true)
    }

    /// True when this run starts the shared DB from empty. The only run that keeps
    /// it is a plain resume: no `--force`, and some shared-DB meeting already has a
    /// lab_result.json from the run that built the DB.
    static func shouldReset(force: Bool, finishedSharedMeetings: Int) -> Bool {
        force || finishedSharedMeetings == 0
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

    guard LabSharedSpeakerDB.shouldReset(force: false, finishedSharedMeetings: 0) else {
        fail("a fresh series run kept a shared DB left by an earlier run")
    }
    guard LabSharedSpeakerDB.shouldReset(force: true, finishedSharedMeetings: 3) else {
        fail("a --force rerun kept the voices the last run learned")
    }
    guard !LabSharedSpeakerDB.shouldReset(force: false, finishedSharedMeetings: 2) else {
        fail("resuming a half-done series threw away the shared DB it needs")
    }

    let fm = FileManager.default
    let scratch = fm.temporaryDirectory.appendingPathComponent("MeetingLabSharedDB-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: scratch) }
    do {
        let workRoot = scratch.appendingPathComponent("runs/set", isDirectory: true)
        let shared = LabSharedSpeakerDB.directory(workRoot: workRoot)
        let learned = shared.appendingPathComponent("speakers.sqlite")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("learned voices".utf8).write(to: learned)
        let outside = scratch.appendingPathComponent("elsewhere/shared-db", isDirectory: true)
        let outsideFile = outside.appendingPathComponent("speakers.sqlite")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("not ours".utf8).write(to: outsideFile)

        guard try LabSharedSpeakerDB.reset(shared, workRoot: workRoot), !fm.fileExists(atPath: learned.path) else {
            fail("reset left the previous run's speaker DB in place")
        }
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
