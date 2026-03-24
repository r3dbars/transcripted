import Foundation
import AppKit

/// Exports diagnostic bundles for bug reports.
/// Collects app logs, system info, and crash reports into a ZIP
/// that users can attach to GitHub issues.
class DiagnosticExporter {

    /// System info for diagnostic context
    static var systemInfo: String {
        let process = ProcessInfo.processInfo
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        return """
        App: Transcripted v\(version) (\(build))
        macOS: \(process.operatingSystemVersionString)
        Hardware: \(hardwareModel)
        Memory: \(process.physicalMemory / (1024 * 1024 * 1024)) GB
        Uptime: \(Int(process.systemUptime / 3600))h \(Int(process.systemUptime.truncatingRemainder(dividingBy: 3600) / 60))m
        Locale: \(Locale.current.identifier)
        """
    }

    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    /// Export a diagnostic bundle as a ZIP file.
    /// Shows a save panel and writes: logs, system info, recent crash reports.
    @MainActor
    static func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Save Diagnostic Report"
        panel.nameFieldStringValue = "Transcripted-Diagnostics-\(DateFormattingHelper.formatFilename(Date())).zip"
        panel.allowedContentTypes = [.zip]

        guard panel.runModal() == .OK, let saveURL = panel.url else { return }

        Task.detached(priority: .userInitiated) {
            do {
                try createDiagnosticZip(at: saveURL)
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([saveURL])
                }
            } catch {
                AppLogger.app.error("Failed to create diagnostic export", ["error": error.localizedDescription])
            }
        }
    }

    /// Create the diagnostic ZIP at the given URL
    private static func createDiagnosticZip(at outputURL: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("transcripted-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. System info
        let infoPath = tempDir.appendingPathComponent("system-info.txt")
        try systemInfo.write(to: infoPath, atomically: true, encoding: .utf8)

        // 2. App logs (last 500 lines)
        let logSource = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Transcripted/app.jsonl")
        if FileManager.default.fileExists(atPath: logSource.path) {
            let logDest = tempDir.appendingPathComponent("app.jsonl")
            let logData = try String(contentsOf: logSource, encoding: .utf8)
            let lines = logData.components(separatedBy: "\n")
            let recentLines = lines.suffix(500).joined(separator: "\n")
            try recentLines.write(to: logDest, atomically: true, encoding: .utf8)
        }

        // 3. Recent crash reports (last 3)
        let crashDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        if let crashFiles = try? FileManager.default.contentsOfDirectory(at: crashDir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.lastPathComponent.contains("Transcripted") })
            .sorted(by: { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return aDate > bDate
            })
            .prefix(3) {
            for crashFile in crashFiles {
                let dest = tempDir.appendingPathComponent(crashFile.lastPathComponent)
                try? FileManager.default.copyItem(at: crashFile, to: dest)
            }
        }

        // 4. UserDefaults snapshot (non-sensitive keys only)
        let defaults = UserDefaults.standard
        let safeKeys = [
            "hasCompletedOnboarding", "enableObsidianFormat", "transcriptSaveLocation",
            "autoDetectEnabled", "qwenEnabled", "selectedMicDevice"
        ]
        var settings: [String: String] = [:]
        for key in safeKeys {
            if let value = defaults.object(forKey: key) {
                settings[key] = "\(value)"
            }
        }
        let settingsData = try JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted)
        try settingsData.write(to: tempDir.appendingPathComponent("settings.json"))

        // Create ZIP using ditto (preserves structure)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", tempDir.path, outputURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DiagnosticExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "ditto failed with status \(process.terminationStatus)"])
        }
    }

    /// One-click bug report: exports diagnostics to Desktop, opens pre-filled GitHub issue,
    /// and reveals the zip so the user can drag it into the issue.
    @MainActor
    static func reportIssue() {
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let filename = "Transcripted-Diagnostics-\(DateFormattingHelper.formatFilename(Date())).zip"
        let zipURL = desktopURL.appendingPathComponent(filename)

        Task.detached(priority: .userInitiated) {
            // Export diagnostics
            var zipCreated = false
            do {
                try createDiagnosticZip(at: zipURL)
                zipCreated = true
            } catch {
                AppLogger.app.error("Failed to create diagnostic export for bug report", ["error": error.localizedDescription])
            }

            await MainActor.run {
                // Open GitHub issue with system info pre-filled
                let issueURL = gitHubIssueURL()
                NSWorkspace.shared.open(issueURL)

                // Reveal the zip on Desktop so user can drag-and-drop into the issue
                if zipCreated {
                    NSWorkspace.shared.activateFileViewerSelecting([zipURL])
                }
            }
        }
    }

    /// Generate a pre-filled GitHub issue URL with system info
    static func gitHubIssueURL(title: String = "", body: String = "") -> URL {
        guard var components = URLComponents(string: "https://github.com/r3dbars/transcripted/issues/new") else {
            return URL(string: "https://github.com/r3dbars/transcripted/issues/new")!
        }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "template", value: "bug_report.md"),
        ]
        if !title.isEmpty {
            queryItems.append(URLQueryItem(name: "title", value: title))
        }
        let fullBody = """
        \(body)

        ---
        **Diagnostic Info**
        ```
        \(systemInfo)
        ```
        > Attach the diagnostic zip from your Desktop if available.
        """
        queryItems.append(URLQueryItem(name: "body", value: fullBody))
        components.queryItems = queryItems
        return components.url ?? URL(string: "https://github.com/r3dbars/transcripted/issues/new")!
    }
}
