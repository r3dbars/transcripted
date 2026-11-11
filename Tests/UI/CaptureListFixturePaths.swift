import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Filesystem admission only. Native UI still requires native-smoke-isolation.py;
/// a private HOME cannot isolate CFPreferences on the owner's account.
struct CaptureListFixturePaths {
    enum AdmissionError: Error { case environment, bounds, directory, ownership, permissions }

    let home: URL
    let parent: URL
    let container: URL
    var captures: URL { container.appendingPathComponent("captures", isDirectory: true) }
    var meetings: URL { captures.appendingPathComponent("meetings", isDirectory: true) }
    var dictations: URL { captures.appendingPathComponent("dictations", isDirectory: true) }

    init(environment: [String: String]) throws {
        guard environment["TRANSCRIPTED_AUTOMATED_HARNESS"] == "1",
              environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
            throw AdmissionError.environment
        }
        home = try Self.canonicalDirectory(environment["HOME"])
        parent = try Self.canonicalDirectory(environment["TRANSCRIPTED_CAPTURE_LIST_FIXTURE_PARENT"])
        container = try Self.canonicalDirectory(environment["TRANSCRIPTED_CONTAINER_DIR"])
        // Foundation caches/chooses its own temporary directory on macOS. The
        // wrapper's explicit TMPDIR, including its optional trailing slash, is
        // the contract; FileManager.temporaryDirectory is not that contract.
        let temporary = try Self.canonicalDirectory(environment["TMPDIR"])
        guard home.deletingLastPathComponent() == parent,
              home.lastPathComponent.hasPrefix("transcripted-capture-list-scroll."),
              temporary == home,
              container == home.appendingPathComponent("container", isDirectory: true) else {
            throw AdmissionError.bounds
        }
        let parentInfo = try Self.directoryInfo(parent)
        guard parentInfo.st_uid == geteuid() || parentInfo.st_uid == 0 else {
            throw AdmissionError.ownership
        }
        // System /tmp may be shared only when its sticky bit protects entries.
        guard parentInfo.st_mode & 0o022 == 0 || parentInfo.st_mode & 0o1000 != 0 else {
            throw AdmissionError.permissions
        }
        try Self.requirePrivateDirectory(home)
        try Self.requirePrivateDirectory(container)
        for leaf in [captures, meetings, dictations] {
            var info = stat()
            if lstat(leaf.path, &info) == 0 {
                try Self.requirePrivateDirectory(leaf)
            } else if errno != ENOENT {
                throw AdmissionError.directory
            }
        }
    }

    static func requirePrivateDirectory(_ url: URL) throws {
        _ = try canonicalDirectory(url.path)
        let info = try directoryInfo(url)
        guard info.st_uid == geteuid() else { throw AdmissionError.ownership }
        guard info.st_mode & 0o7777 == 0o700 else { throw AdmissionError.permissions }
    }

    private static func canonicalDirectory(_ path: String?) throws -> URL {
        guard let path, path.hasPrefix("/") else { throw AdmissionError.environment }
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw AdmissionError.bounds
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.resolvingSymlinksInPath().standardizedFileURL == url else {
            throw AdmissionError.bounds
        }
        return url
    }

    private static func directoryInfo(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw AdmissionError.directory
        }
        return info
    }
}
