import Darwin
import Foundation

/// Resolve bundled models from this executable before looking for an installed
/// app. A packaged helper must keep working when its entire .app is relocated.
enum CLIModelPaths {
    static var executableURL: URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
    }

    static func bundledResourceDirectories(
        executableURL: URL? = executableURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var directories: [URL] = []
        if let executableURL {
            let helperDirectory = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            let contents = helperDirectory.deletingLastPathComponent()
            if helperDirectory.lastPathComponent == "Helpers",
               contents.lastPathComponent == "Contents",
               contents.deletingLastPathComponent().pathExtension == "app" {
                directories.append(contents.appendingPathComponent("Resources", isDirectory: true))
            }
        }
        directories += [
            URL(fileURLWithPath: "/Applications/Transcripted.app/Contents/Resources", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications/Transcripted.app/Contents/Resources", isDirectory: true),
        ]
        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
