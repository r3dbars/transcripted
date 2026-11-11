import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main enum CaptureListFixturePathsTests {
    static func main() {
        do { try run() } catch Failure.promise(let name) {
            print("FAIL: \(name)")
            exit(1)
        } catch {
            print("FAIL: fixture filesystem setup or admission failed")
            exit(1)
        }
    }

    static func run() throws {
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let home = parent.appendingPathComponent("transcripted-capture-list-scroll.fixture", isDirectory: true)
        let container = home.appendingPathComponent("container", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: container, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let environment = [
            "HOME": home.path, "TMPDIR": home.path + "/",
            "TRANSCRIPTED_CAPTURE_LIST_FIXTURE_PARENT": parent.path,
            "TRANSCRIPTED_CONTAINER_DIR": container.path,
            "TRANSCRIPTED_AUTOMATED_HARNESS": "1", "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1"
        ]
        var count = 0
        func check(_ name: String, _ body: () throws -> Bool) throws {
            guard try body() else { throw Failure.promise(name) }
            count += 1
            print("PASS: \(name)")
        }
        func rejected(_ changes: [String: String] = [:]) -> Bool {
            do {
                _ = try CaptureListFixturePaths(environment: environment.merging(changes) { _, new in new })
                return false
            } catch { return true }
        }
        try check("explicit wrapper TMPDIR admits owned fixture when Foundation temp differs") {
            guard fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL != home else { return false }
            let paths = try CaptureListFixturePaths(environment: environment)
            return paths.home == home.standardizedFileURL &&
                paths.container == container.standardizedFileURL && paths.parent == parent.standardizedFileURL
        }
        try check("admitted directories are owned by the effective user") {
            let paths = try CaptureListFixturePaths(environment: environment)
            return try [paths.home, paths.container].allSatisfy {
                let attributes = try fm.attributesOfItem(atPath: $0.path)
                return (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid()
            }
        }
        try check("TMPDIR without trailing slash is admitted") {
            !rejected(["TMPDIR": home.path])
        }
        for key in environment.keys.sorted() {
            try check("missing \(key) is refused") { rejected([key: ""]) }
        }
        try check("wrong parent is refused") {
            rejected(["TRANSCRIPTED_CAPTURE_LIST_FIXTURE_PARENT": parent.deletingLastPathComponent().path])
        }
        try check("TMPDIR outside owned root is refused") { rejected(["TMPDIR": parent.path]) }
        try check("TMPDIR child is refused") { rejected(["TMPDIR": container.path]) }
        try check("relative HOME is refused") { rejected(["HOME": "transcripted-capture-list-scroll.relative"]) }
        try check("TMPDIR traversal back into HOME is refused") {
            rejected(["TMPDIR": home.path + "/container/.."])
        }
        try check("container traversal back into exact leaf is refused") {
            rejected(["TRANSCRIPTED_CONTAINER_DIR": home.path + "/container/../container"])
        }
        try check("mismatched container is refused") { rejected(["TRANSCRIPTED_CONTAINER_DIR": home.path]) }
        let unrelated = parent.appendingPathComponent("unrelated", isDirectory: true)
        try fm.moveItem(at: home, to: unrelated)
        try check("root without wrapper prefix is refused") {
            rejected(["HOME": unrelated.path, "TMPDIR": unrelated.path,
                      "TRANSCRIPTED_CONTAINER_DIR": unrelated.appendingPathComponent("container").path])
        }
        try fm.moveItem(at: unrelated, to: home)
        try fm.moveItem(at: home, to: unrelated)
        try fm.createSymbolicLink(at: home, withDestinationURL: unrelated)
        try check("symlink HOME is refused even when its target is owned") { rejected() }
        try fm.removeItem(at: home)
        try fm.moveItem(at: unrelated, to: home)
        let other = home.appendingPathComponent("other", isDirectory: true)
        try fm.moveItem(at: container, to: other)
        try fm.createSymbolicLink(at: container, withDestinationURL: other)
        try check("symlink container is refused even inside owned HOME") { rejected() }
        try fm.removeItem(at: container)
        try fm.moveItem(at: other, to: container)
        for (name, url, modes) in [("HOME", home, [0o755, 0o770, 0o1700]),
                                   ("container", container, [0o755, 0o777, 0o500]),
                                   ("parent", parent, [0o777, 0o770])] {
            for mode in modes {
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
                try check("unsafe \(name) mode \(String(mode, radix: 8)) is refused") { rejected() }
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
        }
        let captures = container.appendingPathComponent("captures", isDirectory: true)
        try fm.createDirectory(at: captures, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        try check("existing private captures leaf is admitted") { !rejected() }
        for leaf in [captures, captures.appendingPathComponent("meetings", isDirectory: true),
                     captures.appendingPathComponent("dictations", isDirectory: true)] {
            if leaf != captures {
                try fm.createDirectory(at: leaf, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: leaf.path)
            try check("unsafe \(leaf.lastPathComponent) permissions are refused") { rejected() }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leaf.path)
            try fm.removeItem(at: leaf)
            try fm.createSymbolicLink(at: leaf, withDestinationURL: other)
            try check("symlink \(leaf.lastPathComponent) leaf is refused") { rejected() }
            try fm.removeItem(at: leaf)
            try fm.createDirectory(at: leaf, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.removeItem(at: captures)
        try Data().write(to: captures)
        try check("regular file in place of captures is refused") { rejected() }
        try fm.removeItem(at: captures)
        try fm.removeItem(at: container)
        try Data().write(to: container)
        try check("regular file in place of container is refused") { rejected() }
        print("Fixture admission: \(count) promises passed")
    }

    enum Failure: Error { case promise(String) }
}
