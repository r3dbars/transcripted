import Foundation

/// Test-only admission: HOME is not an isolation boundary for native defaults.
struct CallAppHintHarnessIsolation {
    let fixture: URL
    let container: URL
    let output: URL

    enum InvalidEnvironment: Error { case unowned }

    init(environment: [String: String], fileManager: FileManager = .default) throws {
        guard AutomatedLaunchEnvironment.isActive(environment: environment),
              environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1",
              let rootPath = environment["CALL_APP_HINT_RUN_ROOT"], rootPath.hasPrefix("/"),
              let nonce = environment["CALL_APP_HINT_RUN_ID"], !nonce.isEmpty else {
            throw InvalidEnvironment.unowned
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        guard root.lastPathComponent.hasPrefix("run."),
              root.resolvingSymlinksInPath() == root,
              (try? String(contentsOf: root.appendingPathComponent("owned-run"), encoding: .utf8)) == nonce else {
            throw InvalidEnvironment.unowned
        }
        fixture = root.appendingPathComponent("fixture", isDirectory: true)
        container = fixture.appendingPathComponent("container", isDirectory: true)
        output = root.appendingPathComponent("output", isDirectory: true)
        guard environment["TRANSCRIPTED_CONTAINER_DIR"] == container.path else { throw InvalidEnvironment.unowned }
        for url in [fixture, container, output] {
            var directory: ObjCBool = false
            guard url.resolvingSymlinksInPath() == url,
                  fileManager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
                throw InvalidEnvironment.unowned
            }
        }
    }

    @MainActor
    func withPreferences<T>(_ defaults: UserDefaults, body: () throws -> T) rethrows -> T {
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var masked = previous
        masked["observability-anonymous-analytics-enabled"] = false
        masked["observability-crash-reporting-enabled"] = false
        masked["transcriptSaveLocation"] = fixture.appendingPathComponent("library").path
        defaults.setVolatileDomain(masked, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        return try body()
    }
}
