import AppKit
import ApplicationServices
import ArgumentParser
import Foundation
import TranscriptedCaptureKit

struct ImportedAudioNativeSmoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imported-audio-native-smoke",
        abstract: "Drive the native audio import picker, select a real audio file, and validate the saved meeting artifact when local models are available."
    )

    @Option(name: .long, help: "Path to the built Transcripted.app bundle.")
    var app: String = "build/Transcripted.app"

    @Option(name: .long, help: "Existing audio file to select. Defaults to a generated spoken AIFF fixture.")
    var audioFile: String?

    @Option(name: .long, help: "Write a local JSON evidence report to this path.")
    var report: String?

    @Option(name: .long, help: "Seconds to wait for each UI action.")
    var timeout: Double = 12

    @Option(name: .long, help: "Seconds to wait for the imported transcript to be saved.")
    var importTimeout: Double = 360

    @Flag(name: .long, help: "Allow a pre-existing Transcripted process. By default this is INCOMPLETE because duplicate instances are ambiguous.")
    var allowExistingInstance = false

    @Flag(name: .long, help: "Ask macOS to show the Accessibility permission prompt if access is missing.")
    var promptForAccessibility = false

    @Flag(name: .long, help: "Keep the launched app running after the smoke.")
    var keepRunning = false

    @Flag(name: .long, help: "Keep generated fixture and isolated capture-library evidence after the smoke.")
    var preserveEvidence = false

    func run() throws {
        let runner = ImportedAudioNativeSmokeRunner(
            appBundlePath: app,
            audioFilePath: audioFile,
            reportPath: report,
            timeout: timeout,
            importTimeout: importTimeout,
            allowExistingInstance: allowExistingInstance,
            promptForAccessibility: promptForAccessibility,
            keepRunning: keepRunning,
            preserveEvidence: preserveEvidence
        )
        let smokeReport = runner.run()
        smokeReport.printText()
        try smokeReport.writeIfRequested()

        if smokeReport.exitCode != 0 {
            throw ExitCode(smokeReport.exitCode)
        }
    }
}

private final class ImportedAudioNativeSmokeRunner {
    private let appBundleURL: URL
    private let audioFileURL: URL?
    private let reportPath: String?
    private let timeout: TimeInterval
    private let importTimeout: TimeInterval
    private let allowExistingInstance: Bool
    private let promptForAccessibility: Bool
    private let keepRunning: Bool
    private let preserveEvidence: Bool
    private let fileManager: FileManager
    private let runID = UUID().uuidString

    init(
        appBundlePath: String,
        audioFilePath: String?,
        reportPath: String?,
        timeout: Double,
        importTimeout: Double,
        allowExistingInstance: Bool,
        promptForAccessibility: Bool,
        keepRunning: Bool,
        preserveEvidence: Bool,
        fileManager: FileManager = .default
    ) {
        self.appBundleURL = URL(fileURLWithPath: appBundlePath).standardizedFileURL
        self.audioFileURL = audioFilePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        self.reportPath = reportPath
        self.timeout = max(2, timeout)
        self.importTimeout = max(30, importTimeout)
        self.allowExistingInstance = allowExistingInstance
        self.promptForAccessibility = promptForAccessibility
        self.keepRunning = keepRunning
        self.preserveEvidence = preserveEvidence
        self.fileManager = fileManager
    }

    func run() -> ImportedAudioNativeSmokeReport {
        var checks: [UIAutomationSmokeCheck] = []
        let evidenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("transcripted-imported-audio-native-smoke-\(runID)", isDirectory: true)
        let captureLibrary = evidenceRoot.appendingPathComponent("captures", isDirectory: true)
        let meetingsDir = captureLibrary.appendingPathComponent("meetings", isDirectory: true)

        func add(_ check: UIAutomationSmokeCheck) {
            checks.append(check)
        }

        defer {
            if !preserveEvidence {
                try? fileManager.removeItem(at: evidenceRoot)
            }
        }

        guard fileManager.fileExists(atPath: appBundleURL.path) else {
            add(.fail("app-bundle", "Built app bundle exists", target: appBundleURL.path, detail: "Run bash build.sh --no-open first, or pass --app."))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: nil, selectedAudioPath: nil, transcriptPath: nil)
        }

        let executableURL = appBundleURL.appendingPathComponent("Contents/MacOS/Transcripted")
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            add(.fail("app-executable", "Built app executable exists", target: executableURL.path, detail: "Transcripted.app is missing Contents/MacOS/Transcripted."))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: nil, selectedAudioPath: nil, transcriptPath: nil)
        }
        add(.pass("app-bundle", "Built app bundle exists", target: appBundleURL.path))

        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.justinbetker.draft")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !existing.isEmpty && !allowExistingInstance {
            add(.incomplete(
                "existing-instance",
                "No existing Transcripted process is running",
                target: "com.justinbetker.draft",
                detail: "Quit Transcripted first, or pass --allow-existing-instance. Duplicate app instances make picker targeting ambiguous."
            ))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: nil, selectedAudioPath: nil, transcriptPath: nil)
        }
        add(.pass("existing-instance", existing.isEmpty ? "No existing Transcripted process is running" : "Existing Transcripted processes were explicitly allowed", target: "com.justinbetker.draft"))

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: promptForAccessibility] as CFDictionary) else {
            add(.incomplete(
                "accessibility-permission",
                "Automation runner has Accessibility access",
                target: "macOS Accessibility",
                detail: "Grant Accessibility to the terminal or Codex runner, then rerun. This is INCOMPLETE, not product proof."
            ))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: nil, selectedAudioPath: nil, transcriptPath: nil)
        }
        add(.pass("accessibility-permission", "Automation runner has Accessibility access", target: "macOS Accessibility"))

        let selectedAudio: URL
        do {
            try fileManager.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
            selectedAudio = try prepareAudioFixture(in: evidenceRoot)
            add(.pass("audio-fixture", "Selectable audio file exists", target: selectedAudio.lastPathComponent))
        } catch {
            add(.fail("audio-fixture", "Selectable audio file exists", target: evidenceRoot.path, detail: error.localizedDescription))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: nil, selectedAudioPath: nil, transcriptPath: nil)
        }

        let isolatedHome: URL
        do {
            isolatedHome = try prepareIsolatedHome(evidenceRoot: evidenceRoot, captureLibrary: captureLibrary)
            add(.pass("isolated-home", "Isolated app home and capture library are writable", target: isolatedHome.path))
        } catch {
            add(.fail("isolated-home", "Isolated app home and capture library are writable", target: evidenceRoot.path, detail: error.localizedDescription))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: nil, selectedAudioPath: selectedAudio.path, transcriptPath: nil)
        }

        let launched: LaunchedApp
        do {
            launched = try launchApp(executableURL: executableURL, isolatedHome: isolatedHome, captureLibrary: captureLibrary)
            add(.pass("launch-app", "Transcripted launches from built app", target: executableURL.path))
        } catch {
            add(.fail("launch-app", "Transcripted launches from built app", target: executableURL.path, detail: error.localizedDescription))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: nil, selectedAudioPath: selectedAudio.path, transcriptPath: nil)
        }

        defer {
            if !keepRunning {
                terminate(process: launched.process)
            }
        }

        let appAX = AXUIElementCreateApplication(launched.process.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 2)
        let appInspector = AXInspector(root: appAX)

        guard waitUntil(timeout: timeout, condition: {
            launched.process.isRunning && !appInspector.snapshot(maxDepth: 2, maxNodes: 20).isEmpty
        }) else {
            add(.fail("launch-ax-tree", "Transcripted AX tree is readable", target: executableURL.path, detail: "App launched, but AX tree was not readable before timeout."))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: launched.logURL.path, selectedAudioPath: selectedAudio.path, transcriptPath: nil)
        }

        guard openGeneralSettings(appInspector: appInspector, checks: &checks) else {
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: launched.logURL.path, selectedAudioPath: selectedAudio.path, transcriptPath: nil)
        }

        guard appInspector.performPressOrClick(identifier: "transcripted.settings.general.transcribe-audio-file", maxDepth: 12) else {
            add(.fail("open-native-picker", "General import action opens the native file picker", target: "transcripted.settings.general.transcribe-audio-file", detail: "Could not press the Transcribe Audio File control."))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: launched.logURL.path, selectedAudioPath: selectedAudio.path, transcriptPath: nil)
        }

        guard waitForNativePicker(appInspector: appInspector) else {
            add(.fail("native-picker-visible", "Native NSOpenPanel is visible", target: "NSOpenPanel", detail: "The native audio picker did not appear after pressing Transcribe Audio File."))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: launched.logURL.path, selectedAudioPath: selectedAudio.path, transcriptPath: nil)
        }
        add(.pass("native-picker-visible", "Native NSOpenPanel is visible", target: "NSOpenPanel"))

        let startedAt = Date()
        guard selectAudioInNativePicker(selectedAudio, appInspector: appInspector) else {
            add(.incomplete(
                "native-picker-selection",
                "Automation selects the audio file in the native picker",
                target: selectedAudio.lastPathComponent,
                detail: "The native picker did not dismiss after path selection. This is picker automation proof incomplete, not a product import pass."
            ))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: launched.logURL.path, selectedAudioPath: selectedAudio.path, transcriptPath: nil)
        }
        add(.pass("native-picker-selection", "Automation sent the selected audio path to the native picker", target: selectedAudio.lastPathComponent))

        if let transcript = waitForImportedTranscript(in: meetingsDir, startedAt: startedAt) {
            add(.pass("imported-transcript-saved", "Imported audio creates a saved meeting Markdown file", target: transcript.lastPathComponent))
            checks.append(contentsOf: validateImportedTranscript(transcript, meetingsDir: meetingsDir))
            return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: launched.logURL.path, selectedAudioPath: selectedAudio.path, transcriptPath: transcript.path)
        }

        add(.incomplete(
            "imported-transcript-saved",
            "Imported audio creates a saved meeting Markdown file",
            target: meetingsDir.path,
            detail: "The native picker path was driven, but no saved meeting Markdown appeared before \(Int(importTimeout))s. This leaves real transcription/model completion unproven; see the app log in the report."
        ))
        return buildReport(checks: checks, evidenceRoot: evidenceRoot, captureLibrary: captureLibrary, appLogPath: launched.logURL.path, selectedAudioPath: selectedAudio.path, transcriptPath: nil)
    }

    private func openGeneralSettings(appInspector: AXInspector, checks: inout [UIAutomationSmokeCheck]) -> Bool {
        guard let statusItem = waitForNode(inspector: appInspector, match: { node in
            node.observed.identifier == "transcripted.status-item.button"
        }) else {
            checks.append(.fail("status-item", "Transcripted status item is visible to AX", target: "transcripted.status-item.button", detail: "The status item was not found."))
            return false
        }
        checks.append(.pass("status-item", "Transcripted status item is visible to AX", target: "transcripted.status-item.button", observed: [statusItem.observed]))

        guard AXInspector.performPress(statusItem.element) else {
            checks.append(.fail("open-menu", "Status item opens the menu bar popover", target: "transcripted.status-item.button", detail: "AXPress was not available or did not succeed."))
            return false
        }

        guard waitUntil(timeout: timeout, condition: {
            appInspector.snapshot(maxDepth: 9).contains { $0.identifier == "transcripted.menubar.utility.open-transcripted" }
        }) else {
            checks.append(.fail("menu-visible", "Menu bar popover is visible", target: "transcripted.menubar.utility.open-transcripted", detail: "Open Transcripted row did not appear."))
            return false
        }
        checks.append(.pass("menu-visible", "Menu bar popover is visible", target: "transcripted.menubar.utility.open-transcripted"))

        guard appInspector.performPressOrClick(identifier: "transcripted.menubar.utility.open-transcripted") else {
            checks.append(.fail("open-home", "Home opens from the menu bar", target: "transcripted.menubar.utility.open-transcripted", detail: "Could not press the Open Transcripted row."))
            return false
        }

        guard waitUntil(timeout: timeout, condition: {
            appInspector.snapshot(maxDepth: 12).contains { $0.identifier == "transcripted.settings.sidebar.settings-toggle" }
        }) else {
            checks.append(.fail("settings-home", "Home settings surface is visible", target: "transcripted.settings.sidebar.settings-toggle", detail: "Settings Home did not appear."))
            return false
        }

        guard appInspector.performPressOrClick(identifier: "transcripted.settings.sidebar.settings-toggle") else {
            checks.append(.fail("settings-pages-toggle", "Settings area opens from the sidebar toggle", target: "transcripted.settings.sidebar.settings-toggle", detail: "Could not press the Settings toggle."))
            return false
        }

        // The settings area is one combined scrolling page — no tab strip to
        // wait for or click; the import control appears directly.
        guard waitUntil(timeout: timeout, condition: {
            appInspector.snapshot(maxDepth: 12).contains { $0.identifier == "transcripted.settings.general.transcribe-audio-file" }
        }) else {
            checks.append(.fail("settings-general", "General import control is visible", target: "transcripted.settings.general.transcribe-audio-file", detail: "General page did not expose the Transcribe Audio File control."))
            return false
        }
        checks.append(.pass("settings-general", "General import control is visible", target: "transcripted.settings.general.transcribe-audio-file"))
        return true
    }

    private func prepareAudioFixture(in evidenceRoot: URL) throws -> URL {
        if let audioFileURL {
            guard fileManager.fileExists(atPath: audioFileURL.path) else {
                throw SmokeError("Audio file does not exist: \(audioFileURL.path)")
            }
            return audioFileURL
        }

        let fixture = evidenceRoot.appendingPathComponent("Native Imported Audio Proof.aiff", isDirectory: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-o", fixture.path,
            "Transcripted native imported audio smoke. This selected audio should become a saved meeting note."
        ]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fileManager.fileExists(atPath: fixture.path) else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? "unknown say error"
            throw SmokeError("Failed to generate spoken audio with /usr/bin/say: \(stderr)")
        }
        return fixture
    }

    private func prepareIsolatedHome(evidenceRoot: URL, captureLibrary: URL) throws -> URL {
        let home = evidenceRoot.appendingPathComponent("home", isDirectory: true)
        let preferencesDirectory = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try fileManager.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: captureLibrary.appendingPathComponent("meetings", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: captureLibrary.appendingPathComponent("dictations", isDirectory: true), withIntermediateDirectories: true)

        let preferencesURL = preferencesDirectory.appendingPathComponent("com.justinbetker.draft.plist", isDirectory: false)
        let plist: [String: Any] = [
            "permissionsOnboardingCompleted": true,
            "forcePermissionsOnboarding": false,
            "observability-anonymous-analytics-enabled": false,
            "observability-crash-reporting-enabled": false,
            "transcriptSaveLocation": captureLibrary.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: preferencesURL, options: .atomic)
        return home
    }

    private func launchApp(executableURL: URL, isolatedHome: URL, captureLibrary: URL) throws -> LaunchedApp {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-permissionsOnboardingCompleted", "YES",
            "-forcePermissionsOnboarding", "NO",
            "-observability-anonymous-analytics-enabled", "NO",
            "-observability-crash-reporting-enabled", "NO",
            "-transcriptSaveLocation", captureLibrary.path,
        ]

        let logsDirectory = isolatedHome.appendingPathComponent("Library/Application Support/Transcripted/logs", isDirectory: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = isolatedHome.path
        environment["CFFIXED_USER_HOME"] = isolatedHome.path
        environment.removeValue(forKey: "__CFBundleIdentifier")
        environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
        environment["TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS"] = "1"
        environment["TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"] = "1"
        process.environment = environment

        let logURL = logsDirectory.appendingPathComponent("imported-audio-native-smoke-app.log", isDirectory: false)
        fileManager.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        try process.run()
        return LaunchedApp(process: process, logURL: logURL)
    }

    private func waitForNativePicker(appInspector: AXInspector) -> Bool {
        waitUntil(timeout: timeout, condition: {
            isNativePickerVisible(appInspector: appInspector)
        })
    }

    private func isNativePickerVisible(appInspector: AXInspector) -> Bool {
        appInspector.snapshot(maxDepth: 8, maxNodes: 1_000).contains { observed in
            observed.title == "Transcribe" || observed.title == "Cancel" || observed.role == "AXSheet"
        }
    }

    private func selectAudioInNativePicker(_ audioURL: URL, appInspector: AXInspector) -> Bool {
        _ = AXUIElementPerformAction(appInspector.root, kAXRaiseAction as CFString)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(audioURL.path, forType: .string)

        sendKey(keyCode: 5, flags: [.maskCommand, .maskShift]) // Cmd-Shift-G
        Thread.sleep(forTimeInterval: 0.5)
        sendKey(keyCode: 9, flags: [.maskCommand]) // Cmd-V
        Thread.sleep(forTimeInterval: 0.2)
        sendKey(keyCode: 36, flags: []) // Return: accept path
        Thread.sleep(forTimeInterval: 1.0)

        if let transcribeButton = waitForNode(inspector: appInspector, match: { node in
            node.observed.title == "Transcribe"
        }) {
            _ = AXInspector.performPress(transcribeButton.element)
        } else {
            sendKey(keyCode: 36, flags: []) // Return: press Transcribe
        }

        return waitUntil(timeout: timeout, condition: {
            !isNativePickerVisible(appInspector: appInspector)
        })
    }

    private func sendKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(40_000)
        up?.post(tap: .cghidEventTap)
    }

    private func waitForImportedTranscript(in meetingsDir: URL, startedAt: Date) -> URL? {
        let deadline = Date().addingTimeInterval(importTimeout)
        repeat {
            if let transcript = newestTranscript(in: meetingsDir, after: startedAt) {
                return transcript
            }
            Thread.sleep(forTimeInterval: 2)
        } while Date() < deadline
        return nil
    }

    private func newestTranscript(in meetingsDir: URL, after startedAt: Date) -> URL? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: meetingsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "md" && !$0.lastPathComponent.hasSuffix(".summary.md") }
            .compactMap { url -> (URL, Date)? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return date >= startedAt.addingTimeInterval(-2) ? (url, date) : nil
            }
            .sorted { $0.1 > $1.1 }
            .first?
            .0
    }

    private func validateImportedTranscript(_ transcriptURL: URL, meetingsDir: URL) -> [UIAutomationSmokeCheck] {
        var checks: [UIAutomationSmokeCheck] = []
        let target = transcriptURL.lastPathComponent

        guard let markdown = try? String(contentsOf: transcriptURL, encoding: .utf8),
              let document = CaptureMarkdownParser.parseFrontmatter(from: markdown) else {
            return [.fail("imported-frontmatter", "Saved imported transcript has frontmatter", target: target, detail: "Could not parse YAML frontmatter.")]
        }

        if document.values["capture_type"] == "meeting" {
            checks.append(.pass("imported-capture-type", "Saved imported transcript is a meeting capture", target: target))
        } else {
            checks.append(.fail("imported-capture-type", "Saved imported transcript is a meeting capture", target: target, detail: "Expected capture_type=meeting, got \(document.values["capture_type"] ?? "nil")."))
        }

        let sources = document.values["sources"] ?? ""
        if sources.contains("system_audio") {
            checks.append(.pass("imported-sources", "Saved imported transcript records single-file audio as system audio", target: sources))
        } else {
            checks.append(.fail("imported-sources", "Saved imported transcript records single-file audio as system audio", target: target, detail: "Expected sources to include system_audio, got \(sources)."))
        }

        let retainedAudioDir = meetingsDir
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent)_audio", isDirectory: true)
        let retainedFiles = (try? fileManager.contentsOfDirectory(at: retainedAudioDir, includingPropertiesForKeys: nil)) ?? []
        if retainedFiles.contains(where: { ["wav", "m4a", "aiff", "aif", "mp3", "aac"].contains($0.pathExtension.lowercased()) }) {
            checks.append(.pass("imported-retained-audio", "Saved imported transcript has retained audio beside the Markdown", target: retainedAudioDir.lastPathComponent))
        } else {
            checks.append(.fail("imported-retained-audio", "Saved imported transcript has retained audio beside the Markdown", target: retainedAudioDir.path, detail: "No retained audio file was found."))
        }

        let validatorFailures = TranscriptValidator(directory: meetingsDir)
            .validate()
            .filter { $0.status == .fail }
        if validatorFailures.isEmpty {
            checks.append(.pass("imported-transcript-validator", "TranscriptedQA validates the saved imported transcript", target: target))
        } else {
            let detail = validatorFailures.map { "\($0.check): \($0.detail ?? $0.target)" }.joined(separator: "; ")
            checks.append(.fail("imported-transcript-validator", "TranscriptedQA validates the saved imported transcript", target: target, detail: detail))
        }

        return checks
    }

    private func waitForNode(inspector: AXInspector, match: @escaping (AXNode) -> Bool) -> AXNode? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let node = inspector.snapshotNodes(maxDepth: 12).first(where: match) {
                return node
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return nil
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    private func terminate(process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func buildReport(
        checks: [UIAutomationSmokeCheck],
        evidenceRoot: URL,
        captureLibrary: URL,
        appLogPath: String?,
        selectedAudioPath: String?,
        transcriptPath: String?
    ) -> ImportedAudioNativeSmokeReport {
        ImportedAudioNativeSmokeReport(
            runID: runID,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appBundlePath: appBundleURL.path,
            evidenceRoot: evidenceRoot.path,
            captureLibraryPath: captureLibrary.path,
            appLogPath: appLogPath,
            selectedAudioPath: selectedAudioPath,
            transcriptPath: transcriptPath,
            reportPath: reportPath,
            checks: checks
        )
    }
}

struct ImportedAudioNativeSmokeReport: Codable, Equatable {
    let runID: String
    let generatedAt: String
    let appBundlePath: String
    let evidenceRoot: String
    let captureLibraryPath: String
    let appLogPath: String?
    let selectedAudioPath: String?
    let transcriptPath: String?
    let reportPath: String?
    let checks: [UIAutomationSmokeCheck]

    var status: UIAutomationSmokeStatus {
        if checks.contains(where: { $0.status == .fail }) { return .fail }
        if checks.contains(where: { $0.status == .incomplete }) { return .incomplete }
        return .pass
    }

    var exitCode: Int32 {
        switch status {
        case .pass: return 0
        case .fail: return 1
        case .incomplete: return 3
        }
    }

    func printText() {
        let passed = checks.filter { $0.status == .pass }.count
        let flagged = checks.count - passed
        switch status {
        case .pass:
            print("PASS: tested \(passed)/\(checks.count) imported-audio native checks. Native picker selection produced a saved imported meeting.")
        case .fail:
            print("FAIL: tested \(passed)/\(checks.count) imported-audio native checks. \(flagged) flagged.")
        case .incomplete:
            print("INCOMPLETE: tested \(passed)/\(checks.count) imported-audio native checks. \(flagged) flagged.")
        }

        for check in checks where check.status != .pass {
            print("\(check.status.rawValue): \(check.title) - \(check.detail ?? check.target)")
        }
        if let reportPath {
            print("Report: \(reportPath)")
        }
        print("Evidence root: \(evidenceRoot)")
        print("Capture library: \(captureLibraryPath)")
        if let selectedAudioPath {
            print("Selected audio: \(selectedAudioPath)")
        }
        if let transcriptPath {
            print("Transcript: \(transcriptPath)")
        }
        if let appLogPath {
            print("App log: \(appLogPath)")
        }
    }

    func writeIfRequested() throws {
        guard let reportPath, !reportPath.isEmpty else { return }
        let url = URL(fileURLWithPath: reportPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

private struct SmokeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
