import AppKit
import ApplicationServices
import ArgumentParser
import Foundation

struct UISmoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui-smoke",
        abstract: "Launch a built Transcripted.app and validate core UI surfaces through macOS Accessibility."
    )

    @Option(name: .long, help: "Path to the built Transcripted.app bundle.")
    var app: String = "build/Transcripted.app"

    @Option(name: .long, help: "Write a local JSON evidence report to this path.")
    var report: String?

    @Option(name: .long, help: "Seconds to wait for each UI surface.")
    var timeout: Double = 12

    @Flag(name: .long, help: "Allow a pre-existing Transcripted process. By default this is INCOMPLETE because duplicate status items are ambiguous.")
    var allowExistingInstance = false

    @Flag(name: .long, help: "Ask macOS to show the Accessibility permission prompt if access is missing.")
    var promptForAccessibility = false

    @Flag(name: .long, help: "Leave the launched app running after the smoke.")
    var keepRunning = false

    func run() throws {
        let runner = UIAutomationSmokeRunner(
            appBundlePath: app,
            reportPath: report,
            timeout: timeout,
            allowExistingInstance: allowExistingInstance,
            promptForAccessibility: promptForAccessibility,
            keepRunning: keepRunning
        )
        let smokeReport = runner.run()
        smokeReport.printText()
        try smokeReport.writeIfRequested()

        if smokeReport.exitCode != 0 {
            throw ExitCode(smokeReport.exitCode)
        }
    }
}

private final class UIAutomationSmokeRunner {
    private let appBundleURL: URL
    private let reportPath: String?
    private let timeout: TimeInterval
    private let allowExistingInstance: Bool
    private let promptForAccessibility: Bool
    private let keepRunning: Bool
    private let fileManager: FileManager
    private let runID = UUID().uuidString

    init(
        appBundlePath: String,
        reportPath: String?,
        timeout: Double,
        allowExistingInstance: Bool,
        promptForAccessibility: Bool,
        keepRunning: Bool,
        fileManager: FileManager = .default
    ) {
        self.appBundleURL = URL(fileURLWithPath: appBundlePath).standardizedFileURL
        self.reportPath = reportPath
        self.timeout = max(2, timeout)
        self.allowExistingInstance = allowExistingInstance
        self.promptForAccessibility = promptForAccessibility
        self.keepRunning = keepRunning
        self.fileManager = fileManager
    }

    func run() -> UIAutomationSmokeReport {
        var builder = UIAutomationSmokeReportBuilder(
            runID: runID,
            appBundlePath: appBundleURL.path,
            reportPath: reportPath
        )

        guard fileManager.fileExists(atPath: appBundleURL.path) else {
            builder.add(.fail(
                "app-bundle",
                "Built app bundle exists",
                target: appBundleURL.path,
                detail: "Run bash build.sh --no-open first, or pass --app."
            ))
            return builder.build()
        }

        let executableURL = appBundleURL.appendingPathComponent("Contents/MacOS/Transcripted")
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            builder.add(.fail(
                "app-executable",
                "Built app executable exists",
                target: executableURL.path,
                detail: "Transcripted.app is missing Contents/MacOS/Transcripted."
            ))
            return builder.build()
        }
        builder.add(.pass("app-bundle", "Built app bundle exists", target: appBundleURL.path))

        let existing = existingTranscriptedInstances()
        if !existing.isEmpty && !allowExistingInstance {
            builder.add(.incomplete(
                "existing-instance",
                "No existing Transcripted process is running",
                target: "com.justinbetker.draft",
                detail: "Quit Transcripted first, or pass --allow-existing-instance. Duplicate menu bar items make AX targeting ambiguous."
            ))
            return builder.build()
        }
        if existing.isEmpty {
            builder.add(.pass("existing-instance", "No existing Transcripted process is running", target: "com.justinbetker.draft"))
        } else {
            builder.add(.pass(
                "existing-instance",
                "Existing Transcripted processes were explicitly allowed",
                target: "\(existing.count) existing process(es)"
            ))
        }

        guard isAccessibilityTrusted(prompt: promptForAccessibility) else {
            builder.add(.incomplete(
                "accessibility-permission",
                "Automation runner has Accessibility access",
                target: "macOS Accessibility",
                detail: "Grant Accessibility to the terminal or Codex runner, then rerun. This is INCOMPLETE, not product proof."
            ))
            return builder.build()
        }
        builder.add(.pass("accessibility-permission", "Automation runner has Accessibility access", target: "macOS Accessibility"))

        let isolatedHome: URL
        do {
            isolatedHome = try prepareIsolatedHome()
        } catch {
            builder.add(.fail(
                "isolated-home",
                "Isolated app home is writable",
                target: fileManager.temporaryDirectory.path,
                detail: error.localizedDescription
            ))
            return builder.build()
        }
        builder.isolatedHomePath = isolatedHome.path
        builder.add(.pass("isolated-home", "Isolated app home is writable", target: isolatedHome.path))

        var launchedProcess: Process?
        do {
            launchedProcess = try launchApp(executableURL: executableURL, isolatedHome: isolatedHome, builder: &builder)
        } catch {
            builder.add(.fail(
                "launch-app",
                "Transcripted launches from built app",
                target: executableURL.path,
                detail: error.localizedDescription
            ))
            return builder.build()
        }

        defer {
            if !keepRunning, let launchedProcess {
                terminate(process: launchedProcess)
            }
        }

        guard let process = launchedProcess else {
            builder.add(.fail("launch-app", "Transcripted launches from built app", target: executableURL.path, detail: "Process did not start."))
            return builder.build()
        }

        let appAX = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 2)

        guard waitUntil(timeout: timeout, description: "app AX tree", condition: {
            process.isRunning && !AXInspector(root: appAX).snapshot(maxDepth: 2, maxNodes: 20).isEmpty
        }) else {
            builder.add(.fail(
                "launch-app",
                "Transcripted launches from built app",
                target: executableURL.path,
                detail: process.isRunning ? "App launched, but AX tree was not readable before timeout." : "App exited before AX tree was readable."
            ))
            return builder.build()
        }
        builder.add(.pass("launch-app", "Transcripted launches from built app", target: executableURL.path))

        let appInspector = AXInspector(root: appAX)
        guard let statusItem = waitForNode(timeout: timeout, inspector: appInspector, description: "Transcripted status item", match: { node in
            node.observed.identifier == "transcripted.status-item.button"
        }) ?? systemUIServerStatusItem() else {
            builder.add(.fail(
                "status-item",
                "Transcripted status item is visible to AX",
                target: "transcripted.status-item.button",
                detail: "The menu bar status item was not found."
            ))
            return builder.build()
        }
        builder.add(.pass(
            "status-item",
            "Transcripted status item is visible to AX",
            target: "transcripted.status-item.button",
            observed: [statusItem.observed]
        ))

        guard AXInspector.performPress(statusItem.element) else {
            builder.add(.fail(
                "open-menu",
                "Status item opens the menu bar popover",
                target: "transcripted.status-item.button",
                detail: "AXPress was not available or did not succeed."
            ))
            return builder.build()
        }

        let menuRequiredIDs = [
            "transcripted.menubar.primary.home",
            "transcripted.menubar.primary.start-dictation",
            "transcripted.menubar.primary.start-meeting",
            "transcripted.menubar.primary.paste-last-dictation",
            "transcripted.menubar.primary.recent-meetings",
            "transcripted.menubar.utility.connect-agent",
            "transcripted.menubar.utility.submit-feedback",
            "transcripted.menubar.utility.settings",
            "transcripted.menubar.utility.quit",
        ]

        guard waitUntil(timeout: timeout, description: "menu rows", condition: {
            let ids = Set(appInspector.snapshot(maxDepth: 9).compactMap(\.identifier))
            return menuRequiredIDs.allSatisfy(ids.contains)
        }) else {
            builder.add(.fail(
                "menu-identifiers",
                "Menu bar popover exposes core controls",
                target: "menubar",
                detail: "Missing one or more menu bar automation identifiers.",
                observed: observedElements(for: menuRequiredIDs, inspector: appInspector)
            ))
            return builder.build()
        }

        let menuObserved = observedElements(for: menuRequiredIDs, inspector: appInspector)
        let disabledMenuIDs = menuObserved
            .filter { ["transcripted.menubar.primary.home", "transcripted.menubar.primary.start-dictation", "transcripted.menubar.primary.start-meeting", "transcripted.menubar.utility.settings", "transcripted.menubar.utility.quit"].contains($0.identifier ?? "") }
            .filter { $0.isEnabled != true }
            .compactMap(\.identifier)
        if !disabledMenuIDs.isEmpty {
            builder.add(.fail(
                "menu-enabled",
                "Core menu bar controls are enabled",
                target: disabledMenuIDs.joined(separator: ", "),
                detail: "Expected visible controls to be AXEnabled=true.",
                observed: menuObserved
            ))
            return builder.build()
        }
        builder.add(.pass(
            "menu-identifiers",
            "Menu bar popover exposes core controls",
            target: "menubar",
            observed: menuObserved
        ))
        builder.add(.pass("menu-enabled", "Core menu bar controls are enabled", target: "menubar", observed: menuObserved))

        guard let homeRow = appInspector.first(identifier: "transcripted.menubar.primary.home"),
              AXInspector.performPress(homeRow.element) else {
            builder.add(.fail(
                "open-home",
                "Home opens from the menu bar",
                target: "transcripted.menubar.primary.home",
                detail: "Could not press the Home row."
            ))
            return builder.build()
        }

        let settingsSidebarIDs = [
            "transcripted.settings.sidebar.home",
            "transcripted.settings.sidebar.general",
            "transcripted.settings.sidebar.storage",
            "transcripted.settings.sidebar.connect-agent",
            "transcripted.settings.sidebar.beta",
            "transcripted.settings.sidebar.support",
            "transcripted.settings.sidebar.about",
        ]
        let homeIDs = [
            "transcripted.home.mode.meetings",
            "transcripted.home.mode.dictation",
            "transcripted.home.mode.speakers",
            "transcripted.home.stats.view",
        ]

        guard waitUntil(timeout: timeout, description: "settings Home", condition: {
            let ids = Set(appInspector.snapshot(maxDepth: 12).compactMap(\.identifier))
            return settingsSidebarIDs.allSatisfy(ids.contains) && homeIDs.allSatisfy(ids.contains)
        }) else {
            builder.add(.fail(
                "settings-home",
                "Home settings surface is visible",
                target: "Transcripted Settings",
                detail: "Settings Home did not expose expected sidebar and Home controls.",
                observed: observedElements(for: settingsSidebarIDs + homeIDs, inspector: appInspector)
            ))
            return builder.build()
        }
        builder.add(.pass(
            "settings-home",
            "Home settings surface is visible",
            target: "Transcripted Settings",
            observed: observedElements(for: settingsSidebarIDs + homeIDs, inspector: appInspector)
        ))

        guard appInspector.performPressOrClick(identifier: "transcripted.settings.sidebar.general") else {
            builder.add(.fail(
                "settings-navigation",
                "Settings sidebar navigates to General",
                target: "transcripted.settings.sidebar.general",
                detail: "Could not press the General sidebar row."
            ))
            return builder.build()
        }

        let generalIDs = [
            "transcripted.settings.general.launch-at-login",
            "transcripted.settings.general.show-in-dock",
            "transcripted.settings.general.dictation-sounds",
            "transcripted.settings.general.cleanup-pasted-text",
            "transcripted.settings.general.confirm-meeting-quits",
            "transcripted.settings.general.transcribe-audio-file",
        ]

        guard waitUntil(timeout: timeout, description: "General settings", condition: {
            let ids = Set(appInspector.snapshot(maxDepth: 12).compactMap(\.identifier))
            return generalIDs.allSatisfy(ids.contains)
        }) else {
            builder.add(.fail(
                "settings-general",
                "General settings controls are visible",
                target: "General",
                detail: "General page did not expose expected controls.",
                observed: observedElements(for: generalIDs, inspector: appInspector)
            ))
            return builder.build()
        }
        builder.add(.pass(
            "settings-navigation",
            "Settings sidebar navigates to General",
            target: "transcripted.settings.sidebar.general"
        ))
        builder.add(.pass(
            "settings-general",
            "General settings controls are visible",
            target: "General",
            observed: observedElements(for: generalIDs, inspector: appInspector)
        ))

        return builder.build()
    }

    private func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: prompt] as CFDictionary)
    }

    private func existingTranscriptedInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.justinbetker.draft")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    private func prepareIsolatedHome() throws -> URL {
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("transcripted-ui-smoke-\(runID)", isDirectory: true)
        let preferencesDirectory = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try fileManager.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)

        let preferencesURL = preferencesDirectory.appendingPathComponent("com.justinbetker.draft.plist", isDirectory: false)
        let plist: [String: Any] = [
            "permissionsOnboardingCompleted": true,
            "forcePermissionsOnboarding": false,
            "observability-anonymous-analytics-enabled": false,
            "observability-crash-reporting-enabled": false,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: preferencesURL, options: .atomic)
        return home
    }

    private func launchApp(
        executableURL: URL,
        isolatedHome: URL,
        builder: inout UIAutomationSmokeReportBuilder
    ) throws -> Process {
        let process = Process()
        process.executableURL = executableURL

        let logsDirectory = isolatedHome.appendingPathComponent("Library/Application Support/Transcripted/logs", isDirectory: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = isolatedHome.path
        environment["CFFIXED_USER_HOME"] = isolatedHome.path
        environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
        environment["TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS"] = "1"
        environment["TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"] = "1"
        environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT"] = logsDirectory
            .appendingPathComponent("launch-ui-smoke.json", isDirectory: false)
            .path
        process.environment = environment

        let logURL = logsDirectory.appendingPathComponent("ui-smoke-app.log", isDirectory: false)
        fileManager.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }
        builder.appLogPath = logURL.path

        try process.run()
        return process
    }

    private func systemUIServerElement() -> AXUIElement? {
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemuiserver")
        guard let systemUIServer = candidates.first else { return nil }
        let element = AXUIElementCreateApplication(systemUIServer.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 2)
        return element
    }

    private func systemUIServerStatusItem() -> AXNode? {
        guard let systemUIServerAX = systemUIServerElement() else { return nil }
        return waitForNode(timeout: timeout, inspector: AXInspector(root: systemUIServerAX), description: "Transcripted status item fallback", match: { node in
            node.observed.identifier == "transcripted.status-item.button"
                || node.observed.title == "Transcripted"
                || node.observed.help == "Transcripted"
                || node.observed.description == "Transcripted"
        })
    }

    private func observedElements(for identifiers: [String], inspector: AXInspector) -> [AXObservedElement] {
        let nodes = inspector.snapshotNodes(maxDepth: 12)
        return identifiers.map { identifier in
            nodes.first { $0.observed.identifier == identifier }?.observed
                ?? AXObservedElement(identifier: identifier, title: nil, role: nil, description: nil, help: nil, isEnabled: nil, frame: nil)
        }
    }

    private func waitForNode(
        timeout: TimeInterval,
        inspector: AXInspector,
        description: String,
        match: @escaping (AXNode) -> Bool
    ) -> AXNode? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let node = inspector.snapshotNodes(maxDepth: 12).first(where: match) {
                return node
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return nil
    }

    private func waitUntil(timeout: TimeInterval, description: String, condition: () -> Bool) -> Bool {
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
}

private struct AXInspector {
    let root: AXUIElement

    func first(identifier: String) -> AXNode? {
        snapshotNodes(maxDepth: 12).first { $0.observed.identifier == identifier }
    }

    func performPress(identifier: String, maxDepth: Int = 12, maxNodes: Int = 2_000) -> Bool {
        var queue: [(element: AXUIElement, depth: Int, ancestors: [AXUIElement])] = [(root, 0, [])]
        var visited = Set<CFHashCode>()
        var visitedCount = 0

        while !queue.isEmpty, visitedCount < maxNodes {
            let (element, depth, ancestors) = queue.removeFirst()
            let key = CFHash(element)
            if visited.contains(key) { continue }
            visited.insert(key)
            visitedCount += 1

            if observedElement(for: element).identifier == identifier {
                for candidate in [element] + ancestors.reversed() {
                    if Self.performPress(candidate) {
                        return true
                    }
                }
                return false
            }

            guard depth < maxDepth else { continue }
            for child in children(of: element) {
                queue.append((child, depth + 1, ancestors + [element]))
            }
        }

        return false
    }

    func performPressOrClick(identifier: String, maxDepth: Int = 12, maxNodes: Int = 2_000) -> Bool {
        if performPress(identifier: identifier, maxDepth: maxDepth, maxNodes: maxNodes) {
            return true
        }
        guard let frame = first(identifier: identifier)?.observed.frame else {
            return false
        }
        return Self.performClick(frame: frame)
    }

    func snapshot(maxDepth: Int = 10, maxNodes: Int = 2_000) -> [AXObservedElement] {
        snapshotNodes(maxDepth: maxDepth, maxNodes: maxNodes).map(\.observed)
    }

    func snapshotNodes(maxDepth: Int = 10, maxNodes: Int = 2_000) -> [AXNode] {
        var output: [AXNode] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = Set<CFHashCode>()

        while !queue.isEmpty, output.count < maxNodes {
            let (element, depth) = queue.removeFirst()
            let key = CFHash(element)
            if visited.contains(key) { continue }
            visited.insert(key)

            output.append(AXNode(element: element, observed: observedElement(for: element)))
            guard depth < maxDepth else { continue }

            for child in children(of: element) {
                queue.append((child, depth + 1))
            }
        }

        return output
    }

    static func performPress(_ element: AXUIElement) -> Bool {
        var actionsValue: CFArray?
        let actionError = AXUIElementCopyActionNames(element, &actionsValue)
        let actions = (actionsValue as? [String]) ?? []
        guard actionError == .success, actions.contains(kAXPressAction as String) else {
            return false
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func performClick(frame: AXFrame) -> Bool {
        let point = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        let attributes = [
            kAXWindowsAttribute as String,
            kAXChildrenAttribute as String,
            kAXVisibleChildrenAttribute as String,
            kAXMenuBarAttribute as String,
            "AXChildrenInNavigationOrder",
            "AXExtrasMenuBar",
            "AXContents",
        ]

        var children: [AXUIElement] = []
        for attribute in attributes {
            children.append(contentsOf: elements(from: value(element, attribute)))
        }
        return children
    }

    private func observedElement(for element: AXUIElement) -> AXObservedElement {
        AXObservedElement(
            identifier: string(element, kAXIdentifierAttribute as String),
            title: string(element, kAXTitleAttribute as String),
            role: string(element, kAXRoleAttribute as String),
            description: string(element, kAXDescriptionAttribute as String),
            help: string(element, kAXHelpAttribute as String),
            isEnabled: bool(element, kAXEnabledAttribute as String),
            frame: frame(element)
        )
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        if let value = value(element, attribute) as? Bool {
            return value
        }
        if let value = value(element, attribute) as? NSNumber {
            return value.boolValue
        }
        return nil
    }

    private func frame(_ element: AXUIElement) -> AXFrame? {
        var origin = CGPoint.zero
        var size = CGSize.zero

        if let positionValue = value(element, kAXPositionAttribute as String),
           CFGetTypeID(positionValue) == AXValueGetTypeID() {
            AXValueGetValue((positionValue as! AXValue), .cgPoint, &origin)
        } else {
            return nil
        }

        if let sizeValue = value(element, kAXSizeAttribute as String),
           CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            AXValueGetValue((sizeValue as! AXValue), .cgSize, &size)
        } else {
            return nil
        }

        return AXFrame(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    private func elements(from value: CFTypeRef?) -> [AXUIElement] {
        guard let value else { return [] }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return [value as! AXUIElement]
        }
        return (value as? [AXUIElement]) ?? []
    }
}

private struct AXNode {
    let element: AXUIElement
    let observed: AXObservedElement
}

struct AXObservedElement: Codable, Equatable {
    let identifier: String?
    let title: String?
    let role: String?
    let description: String?
    let help: String?
    let isEnabled: Bool?
    let frame: AXFrame?
}

struct AXFrame: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum UIAutomationSmokeStatus: String, Codable {
    case pass = "PASS"
    case fail = "FAIL"
    case incomplete = "INCOMPLETE"
}

struct UIAutomationSmokeCheck: Codable, Equatable {
    let id: String
    let title: String
    let status: UIAutomationSmokeStatus
    let target: String
    let detail: String?
    let observed: [AXObservedElement]

    static func pass(_ id: String, _ title: String, target: String, observed: [AXObservedElement] = []) -> UIAutomationSmokeCheck {
        UIAutomationSmokeCheck(id: id, title: title, status: .pass, target: target, detail: nil, observed: observed)
    }

    static func fail(_ id: String, _ title: String, target: String, detail: String, observed: [AXObservedElement] = []) -> UIAutomationSmokeCheck {
        UIAutomationSmokeCheck(id: id, title: title, status: .fail, target: target, detail: detail, observed: observed)
    }

    static func incomplete(_ id: String, _ title: String, target: String, detail: String, observed: [AXObservedElement] = []) -> UIAutomationSmokeCheck {
        UIAutomationSmokeCheck(id: id, title: title, status: .incomplete, target: target, detail: detail, observed: observed)
    }
}

struct UIAutomationSmokeReport: Codable, Equatable {
    let runID: String
    let status: UIAutomationSmokeStatus
    let exitCode: Int32
    let generatedAt: String
    let appBundlePath: String
    let isolatedHomePath: String?
    let appLogPath: String?
    let reportPath: String?
    let checks: [UIAutomationSmokeCheck]

    func printText() {
        let passed = checks.filter { $0.status == .pass }.count
        let flagged = checks.count - passed
        switch status {
        case .pass:
            print("PASS: tested \(passed)/\(checks.count) UI checks. Menu bar, Home, Settings, and navigation are scriptable.")
        case .fail:
            print("FAIL: tested \(passed)/\(checks.count) UI checks. \(flagged) flagged.")
        case .incomplete:
            print("INCOMPLETE: tested \(passed)/\(checks.count) UI checks. \(flagged) flagged.")
        }

        for check in checks where check.status != .pass {
            print("\(check.status.rawValue): \(check.title) - \(check.detail ?? check.target)")
        }
        if let reportPath {
            print("Report: \(reportPath)")
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

struct UIAutomationSmokeReportBuilder {
    let runID: String
    let appBundlePath: String
    let reportPath: String?
    var isolatedHomePath: String?
    var appLogPath: String?
    private var checks: [UIAutomationSmokeCheck] = []

    init(runID: String, appBundlePath: String, reportPath: String?) {
        self.runID = runID
        self.appBundlePath = appBundlePath
        self.reportPath = reportPath
    }

    mutating func add(_ check: UIAutomationSmokeCheck) {
        checks.append(check)
    }

    func build(generatedAt: Date = Date()) -> UIAutomationSmokeReport {
        let status: UIAutomationSmokeStatus
        if checks.contains(where: { $0.status == .fail }) {
            status = .fail
        } else if checks.contains(where: { $0.status == .incomplete }) {
            status = .incomplete
        } else {
            status = .pass
        }

        let exitCode: Int32
        switch status {
        case .pass:
            exitCode = 0
        case .fail:
            exitCode = 1
        case .incomplete:
            exitCode = 3
        }

        return UIAutomationSmokeReport(
            runID: runID,
            status: status,
            exitCode: exitCode,
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            appBundlePath: appBundlePath,
            isolatedHomePath: isolatedHomePath,
            appLogPath: appLogPath,
            reportPath: reportPath,
            checks: checks
        )
    }
}
