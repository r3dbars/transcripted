import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Secure local storage")
struct SecureLocalStorageTests {
    private func makeTempDirectoryURL() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("tilde-secure-storage-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func posixMode(of url: URL) throws -> Int16 {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return Int16(info.st_mode & 0o7777)
    }

    private func canOpenSecurely(_ file: URL) -> Bool {
        guard let handle = SecureLocalStorage.openFileForAppending(at: file) else { return false }
        try? handle.close()
        return true
    }

    @Test("Created directories are owner-only (0700)")
    func createsOwnerOnlyDirectory() throws {
        let root = makeTempDirectoryURL()
        let directory = root.appendingPathComponent("nested/logs", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(canOpenSecurely(directory.appendingPathComponent("diagnostics.log")))
        #expect(try posixMode(of: directory) == 0o700)
    }

    @Test("Created files are owner-only (0600)")
    func createsOwnerOnlyFile() throws {
        let root = makeTempDirectoryURL()
        let file = root.appendingPathComponent("traces.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(canOpenSecurely(file))
        #expect(try posixMode(of: file) == 0o600)
    }

    @Test("Existing world-readable files are tightened on next ensure (migration)")
    func tightensExistingLooseFile() throws {
        let root = makeTempDirectoryURL()
        let file = root.appendingPathComponent("legacy.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Simulate a file created by an earlier build at the default umask (world-readable).
        #expect(FileManager.default.createFile(
            atPath: file.path,
            contents: Data("old\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o644))]
        ))
        #expect(chmod(file.path, 0o4644) == 0)
        #expect(try posixMode(of: file) == 0o4644)

        #expect(canOpenSecurely(file))
        #expect(try posixMode(of: file) == 0o600)
        // Contents are preserved — tightening must not truncate an existing log.
        #expect(try String(contentsOf: file, encoding: .utf8) == "old\n")
    }

    @Test("Existing world-readable directories are tightened on next create (migration)")
    func tightensExistingLooseDirectory() throws {
        let root = makeTempDirectoryURL()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
        #expect(chmod(root.path, 0o1755) == 0)
        #expect(try posixMode(of: root) == 0o1755)

        #expect(canOpenSecurely(root.appendingPathComponent("diagnostics.log")))
        #expect(try posixMode(of: root) == 0o700)
    }

    @Test("Directory creation rejects a regular file")
    func rejectsFileAsDirectory() throws {
        let root = makeTempDirectoryURL()
        let directory = root.appendingPathComponent("logs", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: directory.path, contents: Data()))

        #expect(!canOpenSecurely(directory.appendingPathComponent("diagnostics.log")))
    }

    @Test("Directory creation rejects a symbolic link")
    func rejectsSymlinkAsDirectory() throws {
        let root = makeTempDirectoryURL()
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("logs", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(!canOpenSecurely(link.appendingPathComponent("diagnostics.log")))
        #expect(try posixMode(of: target) == 0o755)
    }

    @Test("Directory creation rejects a symbolic link in an earlier component")
    func rejectsSymlinkInDirectoryPath() throws {
        let root = makeTempDirectoryURL()
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        let directory = link.appendingPathComponent("nested/logs", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(!canOpenSecurely(directory.appendingPathComponent("diagnostics.log")))
        #expect(!FileManager.default.fileExists(
            atPath: target.appendingPathComponent("nested").path
        ))
    }

    @Test("File creation rejects a directory")
    func rejectsDirectoryAsFile() throws {
        let root = makeTempDirectoryURL()
        let file = root.appendingPathComponent("diagnostics.log")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

        #expect(!canOpenSecurely(file))
    }

    @Test("File creation rejects a symbolic link without changing its target")
    func rejectsSymlinkAsFile() throws {
        let root = makeTempDirectoryURL()
        let target = root.appendingPathComponent("target.log")
        let link = root.appendingPathComponent("diagnostics.log")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(
            atPath: target.path,
            contents: Data("private\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o644))]
        ))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(!canOpenSecurely(link))
        #expect(try String(contentsOf: target, encoding: .utf8) == "private\n")
        #expect(try posixMode(of: target) == 0o644)
    }

    @Test("Diagnostics refuse a symbolic-link log")
    func diagnosticsRejectSymlink() throws {
        let root = makeTempDirectoryURL()
        let target = root.appendingPathComponent("target.log")
        let link = root.appendingPathComponent("diagnostics.log")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("unchanged\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let log = DiagnosticsLog(logURL: link)
        log.record("must-not-write")
        log.flush()

        #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged\n")
    }

    @Test("Diagnostics refuse a symbolic-link parent")
    func diagnosticsRejectSymlinkParent() throws {
        let root = makeTempDirectoryURL()
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("logs", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let log = DiagnosticsLog(logURL: link.appendingPathComponent("diagnostics.log"))
        log.record("must-not-write")
        log.flush()

        #expect(!FileManager.default.fileExists(
            atPath: target.appendingPathComponent("diagnostics.log").path
        ))
    }

    @Test("Diagnostics append through the validated owner-only descriptor")
    func diagnosticsAppendSecurely() throws {
        let root = makeTempDirectoryURL()
        let file = root.appendingPathComponent("diagnostics.log")
        defer { try? FileManager.default.removeItem(at: root) }

        let log = DiagnosticsLog(logURL: file)
        log.record("first-safe-event")
        log.record("second-safe-event")
        log.flush()

        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("first-safe-event"))
        #expect(contents.contains("second-safe-event"))
        #expect(try posixMode(of: root) == 0o700)
        #expect(try posixMode(of: file) == 0o600)
    }

    @Test("History operations reject an owner-only FIFO without blocking")
    func historyOperationsRejectFIFO() throws {
        let root = makeTempDirectoryURL()
        let file = root.appendingPathComponent("history.v1.enc")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o700) == 0)
        #expect(mkfifo(file.path, 0o600) == 0)
        let start = ContinuousClock.now

        #expect(SecureLocalStorage.openExistingFileForReading(at: file) == nil)
        #expect(SecureLocalStorage.openFileForReadingAndAppending(at: file) == nil)
        switch SecureLocalStorage.openExistingOwnerOnlyFileForReadOnlyStatus(at: file) {
        case .rejected: break
        default: Issue.record("Status accepted an owner-only FIFO")
        }
        #expect(!SecureLocalStorage.removeOwnerOnlyFile(at: file))
        #expect(start.duration(to: .now) < .seconds(1))
        var info = stat()
        #expect(lstat(file.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFIFO)
    }

}
