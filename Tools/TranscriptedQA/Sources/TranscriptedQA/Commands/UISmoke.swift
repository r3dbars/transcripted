import AppKit
import ApplicationServices
import ArgumentParser
import Foundation
import TranscriptedCaptureKit

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

final class UIAutomationSmokeRunner {
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

        guard runOnboardingSmoke(executableURL: executableURL, builder: &builder) else {
            return builder.build()
        }

        let isolatedHome: URL
        do {
            isolatedHome = try prepareIsolatedHome(
                suffix: "main",
                onboardingCompleted: true,
                forceOnboarding: false
            )
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

        do {
            try seedSavedDictationFixture(in: isolatedHome)
        } catch {
            builder.add(.fail(
                "dictation-fixture",
                "Saved dictation fixture is writable",
                target: isolatedHome.path,
                detail: error.localizedDescription
            ))
            return builder.build()
        }

        var launchedProcess: Process?
        do {
            let launched = try launchApp(
                executableURL: executableURL,
                isolatedHome: isolatedHome,
                logFileName: "ui-smoke-app.log",
                launchReportFileName: "launch-ui-smoke.json",
                onboardingCompleted: true,
                forceOnboarding: false
            )
            launchedProcess = launched.process
            builder.appLogPath = launched.logURL.path
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
                terminateProcess(launchedProcess, gracePeriod: 3)
            }
        }

        guard let process = launchedProcess else {
            builder.add(.fail("launch-app", "Transcripted launches from built app", target: executableURL.path, detail: "Process did not start."))
            return builder.build()
        }

        let appAX = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 2)

        guard waitUntil(timeout: timeout, condition: {
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
        guard let statusItem = waitForNode(timeout: timeout, inspector: appInspector, match: { node in
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
            "transcripted.menubar.primary.start-dictation",
            "transcripted.menubar.primary.start-meeting",
            "transcripted.menubar.primary.paste-last-dictation",
            "transcripted.menubar.utility.check-updates",
            "transcripted.menubar.utility.open-transcripted",
            "transcripted.menubar.utility.settings",
            "transcripted.menubar.utility.quit",
        ]
        let menuMaxDepth = 12

        guard waitUntil(timeout: timeout, condition: {
            let ids = Set(appInspector.snapshot(maxDepth: menuMaxDepth).compactMap(\.identifier))
            return menuRequiredIDs.allSatisfy(ids.contains)
        }) else {
            let observedIDs = Set(appInspector.snapshot(maxDepth: menuMaxDepth).compactMap(\.identifier))
            let missingIDs = menuRequiredIDs.filter { !observedIDs.contains($0) }
            builder.add(.fail(
                "menu-identifiers",
                "Menu bar popover exposes core controls",
                target: "menubar",
                detail: "Missing menu bar automation identifiers: \(missingIDs.joined(separator: ", ")).",
                observed: observedElements(for: menuRequiredIDs, inspector: appInspector, maxDepth: menuMaxDepth)
            ))
            return builder.build()
        }

        let menuObserved = observedElements(for: menuRequiredIDs, inspector: appInspector, maxDepth: menuMaxDepth)
        let disabledMenuIDs = menuObserved
            .filter { ["transcripted.menubar.primary.start-dictation", "transcripted.menubar.primary.start-meeting", "transcripted.menubar.utility.open-transcripted", "transcripted.menubar.utility.settings", "transcripted.menubar.utility.quit"].contains($0.identifier ?? "") }
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

        let menuAuditRows = MenuBarAuditRow.manualProofTailRows
        let auditObserved = observedElements(
            for: menuAuditRows.flatMap { $0.targets.map(\.identifier) },
            inspector: appInspector
        )
        if let failure = MenuBarAuditRow.firstFailure(in: auditObserved, rows: menuAuditRows) {
            builder.add(.fail(
                failure.checkID,
                failure.title,
                target: failure.target,
                detail: failure.detail,
                observed: auditObserved
            ))
            return builder.build()
        }
        for row in menuAuditRows {
            builder.add(.pass(
                row.checkID,
                row.title,
                target: row.targetSummary,
                observed: auditObserved.filter { observed in
                    row.targets.contains { $0.identifier == observed.identifier }
                }
            ))
        }

        guard let openTranscriptedRow = appInspector.first(identifier: "transcripted.menubar.utility.open-transcripted"),
              AXInspector.performPress(openTranscriptedRow.element) else {
            builder.add(.fail(
                "open-home",
                "Home opens from the menu bar",
                target: "transcripted.menubar.utility.open-transcripted",
                detail: "Could not press the Open Transcripted row."
            ))
            return builder.build()
        }

        let settingsSidebarIDs = [
            "transcripted.settings.sidebar.home",
            "transcripted.settings.sidebar.dictations",
            "transcripted.settings.sidebar.people",
            "transcripted.settings.sidebar.connect-agent",
            "transcripted.settings.sidebar.settings-toggle",
        ]
        let homeIDs = [
            "transcripted.home.find.toggle",
        ]

        guard waitUntil(timeout: timeout, condition: {
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

        let primaryPageChecks: [(id: String, title: String, triggerID: String, requiredIDs: [String])] = [
            (
                id: "settings-dictations",
                title: "Dictations settings surface is visible",
                triggerID: "transcripted.settings.sidebar.dictations",
                requiredIDs: ["transcripted.settings.page.dictations"]
            ),
            (
                id: "settings-speakers",
                title: "Speakers settings surface is visible",
                triggerID: "transcripted.settings.sidebar.people",
                requiredIDs: ["transcripted.settings.page.people"]
            ),
            (
                id: "settings-agent",
                title: "Agent settings surface is visible",
                triggerID: "transcripted.settings.sidebar.connect-agent",
                requiredIDs: ["transcripted.settings.page.agent"]
            ),
        ]

        for check in primaryPageChecks {
            guard appInspector.selectRow(identifier: check.triggerID)
                    || appInspector.performPressOrClick(identifier: check.triggerID) else {
                builder.add(.fail(
                    check.id,
                    check.title,
                    target: check.triggerID,
                    detail: "Could not open this sidebar surface."
                ))
                return builder.build()
            }
            guard waitUntil(timeout: timeout, condition: {
                let ids = Set(appInspector.snapshot(maxDepth: 12).compactMap(\.identifier))
                return check.requiredIDs.allSatisfy(ids.contains)
            }) else {
                builder.add(.fail(
                    check.id,
                    check.title,
                    target: check.triggerID,
                    detail: "Surface did not expose expected automation identifiers.",
                    observed: observedElements(for: check.requiredIDs, inspector: appInspector)
                ))
                return builder.build()
            }
            builder.add(.pass(
                check.id,
                check.title,
                target: check.triggerID,
                observed: observedElements(for: check.requiredIDs, inspector: appInspector)
            ))
        }

        guard appInspector.performPressOrClick(identifier: "transcripted.settings.sidebar.settings-toggle") else {
            builder.add(.fail(
                "settings-pages-toggle",
                "Settings area opens from the sidebar toggle",
                target: "transcripted.settings.sidebar.settings-toggle",
                detail: "Could not press the Settings toggle."
            ))
            return builder.build()
        }

        // The settings area is one combined scrolling page (the old
        // General / Storage / About tab strip was removed): after the toggle,
        // all three section identifiers must be present in a single snapshot.
        let settingsSectionIDs = [
            "transcripted.settings.page.general",
            "transcripted.settings.page.storage",
            "transcripted.settings.page.about",
        ]

        guard waitUntil(timeout: timeout, condition: {
            let ids = Set(appInspector.snapshot(maxDepth: 12).compactMap(\.identifier))
            return settingsSectionIDs.allSatisfy(ids.contains)
        }) else {
            builder.add(.fail(
                "settings-pages-toggle",
                "Settings area opens from the sidebar toggle",
                target: "Transcripted Settings",
                detail: "Combined settings page did not expose its General/Storage/About section identifiers.",
                observed: observedElements(for: settingsSectionIDs, inspector: appInspector)
            ))
            return builder.build()
        }
        builder.add(.pass(
            "settings-pages-toggle",
            "Settings area opens from the sidebar toggle",
            target: "transcripted.settings.sidebar.settings-toggle"
        ))
        builder.add(.pass(
            "settings-general",
            "Combined settings page shows the General, Storage, and About sections",
            target: "transcripted.settings.page.general",
            observed: observedElements(for: settingsSectionIDs, inspector: appInspector)
        ))

        return builder.build()
    }

    private func runOnboardingSmoke(
        executableURL: URL,
        builder: inout UIAutomationSmokeReportBuilder
    ) -> Bool {
        let onboardingHome: URL
        do {
            onboardingHome = try prepareIsolatedHome(
                suffix: "onboarding",
                onboardingCompleted: false,
                forceOnboarding: true
            )
        } catch {
            builder.add(.fail(
                "onboarding-isolated-home",
                "First-run onboarding home is writable",
                target: fileManager.temporaryDirectory.path,
                detail: error.localizedDescription
            ))
            return false
        }
        builder.onboardingIsolatedHomePath = onboardingHome.path
        builder.add(.pass("onboarding-isolated-home", "First-run onboarding home is writable", target: onboardingHome.path))

        let launched: LaunchedApp
        do {
            launched = try launchApp(
                executableURL: executableURL,
                isolatedHome: onboardingHome,
                logFileName: "ui-smoke-onboarding-app.log",
                launchReportFileName: "launch-ui-smoke-onboarding.json",
                onboardingCompleted: false,
                forceOnboarding: true
            )
            builder.onboardingAppLogPath = launched.logURL.path
        } catch {
            builder.add(.fail(
                "onboarding-launch",
                "First-run onboarding launches from built app",
                target: executableURL.path,
                detail: error.localizedDescription
            ))
            return false
        }

        defer {
            terminateProcess(launched.process, gracePeriod: 3)
        }

        let appAX = AXUIElementCreateApplication(launched.process.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 2)
        let appInspector = AXInspector(root: appAX)
        let onboardingMaxDepth = 24

        guard waitUntil(timeout: timeout, condition: {
            launched.process.isRunning && !appInspector.snapshot(maxDepth: 4, maxNodes: 40).isEmpty
        }) else {
            builder.add(.fail(
                "onboarding-launch",
                "First-run onboarding launches from built app",
                target: executableURL.path,
                detail: launched.process.isRunning ? "App launched, but the first-run AX tree was not readable before timeout." : "App exited before onboarding was readable."
            ))
            return false
        }

        let navPrimaryID = "transcripted.onboarding.nav.primary"
        guard let welcomeObserved = waitForObservedElements([navPrimaryID], inspector: appInspector, maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-window",
                "First-run onboarding window is visible",
                target: navPrimaryID,
                detail: "The first-run onboarding primary button was not found.",
                observed: observedElements(for: [navPrimaryID], inspector: appInspector, maxDepth: onboardingMaxDepth)
            ))
            return false
        }
        builder.add(.pass(
            "onboarding-window",
            "First-run onboarding window is visible",
            target: "Transcripted onboarding",
            observed: welcomeObserved
        ))

        guard appInspector.performPressOrClick(identifier: navPrimaryID, maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-navigation",
                "Onboarding primary navigation advances to the permissions step",
                target: navPrimaryID,
                detail: "Could not press the onboarding primary button on the welcome step."
            ))
            return false
        }
        pauseForUITransition()

        // Three-step quiet onboarding (welcome -> permissions -> done): one
        // permissions screen exposes all four permission rows at once, no
        // use-case branching. Microphone gates the primary CTA, so the smoke
        // stops here rather than trying to advance past it in a sandboxed,
        // permission-less launch.
        let permissionIDs = [
            "transcripted.onboarding.permissions.microphone",
            "transcripted.onboarding.permissions.accessibility",
            "transcripted.onboarding.permissions.system-audio",
            "transcripted.onboarding.permissions.calendar",
        ]
        guard let permissionsObserved = waitForObservedElements(permissionIDs, inspector: appInspector, maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-permissions",
                "Onboarding exposes microphone, paste-back, system audio, and calendar permission actions",
                target: "Transcripted onboarding",
                detail: "The permissions step did not expose the expected automation identifiers.",
                observed: observedElements(for: permissionIDs, inspector: appInspector, maxDepth: onboardingMaxDepth)
            ))
            return false
        }
        builder.add(.pass(
            "onboarding-permissions",
            "Onboarding exposes microphone, paste-back, system audio, and calendar permission actions",
            target: "Transcripted onboarding",
            observed: permissionsObserved
        ))

        return true
    }

    private func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: prompt] as CFDictionary)
    }

    private func existingTranscriptedInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.justinbetker.draft")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    private func prepareIsolatedHome(
        suffix: String,
        onboardingCompleted: Bool,
        forceOnboarding: Bool
    ) throws -> URL {
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("transcripted-ui-smoke-\(runID)-\(suffix)", isDirectory: true)
        let preferencesDirectory = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try fileManager.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)

        let preferencesURL = preferencesDirectory.appendingPathComponent("com.justinbetker.draft.plist", isDirectory: false)
        let plist: [String: Any] = [
            "permissionsOnboardingCompleted": onboardingCompleted,
            "forcePermissionsOnboarding": forceOnboarding,
            "observability-anonymous-analytics-enabled": false,
            "observability-crash-reporting-enabled": false,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: preferencesURL, options: .atomic)
        return home
    }

    private func seedSavedDictationFixture(in isolatedHome: URL) throws {
        let dictationsDirectory = isolatedHome
            .appendingPathComponent("Library/Application Support/Transcripted/captures/dictations", isDirectory: true)
        try fileManager.createDirectory(at: dictationsDirectory, withIntermediateDirectories: true)

        let fixtureURL = dictationsDirectory.appendingPathComponent("Dictations_2099-12-31.md", isDirectory: false)
        let fixture = """
        ---
        title: "Dictations for December 31, 2099"
        date: 2099-12-31
        capture_type: dictation_day
        format_version: 1
        ---

        # Dictations for December 31, 2099

        ## 11:59 PM - UI smoke saved dictation

        Entry ID: `dictation-ui-smoke`
        Captured: 2099-12-31T23:59:00.000Z
        Source app: Transcripted QA
        Delivery: copied
        Words: 4
        Characters: 25

        UI smoke saved dictation.
        """
        try fixture.write(to: fixtureURL, atomically: true, encoding: .utf8)
    }

    private func launchApp(
        executableURL: URL,
        isolatedHome: URL,
        logFileName: String,
        launchReportFileName: String,
        onboardingCompleted: Bool,
        forceOnboarding: Bool
    ) throws -> LaunchedApp {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-permissionsOnboardingCompleted",
            onboardingCompleted ? "YES" : "NO",
            "-forcePermissionsOnboarding",
            forceOnboarding ? "YES" : "NO",
            "-observability-anonymous-analytics-enabled",
            "NO",
            "-observability-crash-reporting-enabled",
            "NO",
        ]

        let logsDirectory = isolatedHome.appendingPathComponent("Library/Application Support/Transcripted/logs", isDirectory: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        applyIsolatedLaunchEnvironment(&environment, isolatedHome: isolatedHome)
        environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT"] = logsDirectory
            .appendingPathComponent(launchReportFileName, isDirectory: false)
            .path
        process.environment = environment

        let logURL = logsDirectory.appendingPathComponent(logFileName, isDirectory: false)
        fileManager.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        try process.run()
        return LaunchedApp(process: process, logURL: logURL)
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
        return waitForNode(timeout: timeout, inspector: AXInspector(root: systemUIServerAX), match: { node in
            node.observed.identifier == "transcripted.status-item.button"
                || node.observed.title == "Transcripted"
                || node.observed.help == "Transcripted"
                || node.observed.description == "Transcripted"
        })
    }

    private func observedElements(for identifiers: [String], inspector: AXInspector, maxDepth: Int = 12) -> [AXObservedElement] {
        let nodes = inspector.snapshotNodes(maxDepth: maxDepth)
        return identifiers.map { identifier in
            nodes.first { $0.observed.identifier == identifier }?.observed
                ?? AXObservedElement(identifier: identifier, title: nil, role: nil, description: nil, help: nil, isEnabled: nil, frame: nil)
        }
    }

    private func waitForNode(
        timeout: TimeInterval,
        inspector: AXInspector,
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

    private func waitForObservedElements(
        _ identifiers: [String],
        inspector: AXInspector,
        maxDepth: Int = 12
    ) -> [AXObservedElement]? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let nodes = inspector.snapshotNodes(maxDepth: maxDepth)
            let observed = identifiers.compactMap { identifier in
                nodes.first { $0.observed.identifier == identifier }?.observed
            }
            if observed.count == identifiers.count {
                return observed
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

    private func pauseForUITransition() {
        Thread.sleep(forTimeInterval: 0.35)
    }

}

struct MenuBarAuditTarget: Equatable {
    let identifier: String
    let requiresEnabled: Bool?

    init(_ identifier: String, requiresEnabled: Bool? = true) {
        self.identifier = identifier
        self.requiresEnabled = requiresEnabled
    }
}

struct MenuBarAuditRow: Equatable {
    let rowNumber: Int
    let title: String
    let targets: [MenuBarAuditTarget]
    let minimumHitSize: Double

    var checkID: String { "menu-audit-row-\(rowNumber)" }
    var targetSummary: String { targets.map(\.identifier).joined(separator: ", ") }

    static let manualProofTailRows: [MenuBarAuditRow] = [
        MenuBarAuditRow(
            rowNumber: 25,
            title: "Audit row 25: Start Dictation menu action is visible, enabled, and 40pt",
            targets: [
                MenuBarAuditTarget("transcripted.menubar.primary.start-dictation"),
            ],
            minimumHitSize: 40
        ),
        MenuBarAuditRow(
            rowNumber: 27,
            title: "Audit row 27: Start Meeting menu action is visible, enabled, and 40pt",
            targets: [
                MenuBarAuditTarget("transcripted.menubar.primary.start-meeting"),
            ],
            minimumHitSize: 40
        ),
        MenuBarAuditRow(
            rowNumber: 29,
            title: "Audit row 29: Paste Last Dictation menu action is visible and 40pt",
            targets: [
                MenuBarAuditTarget("transcripted.menubar.primary.paste-last-dictation", requiresEnabled: nil),
            ],
            minimumHitSize: 40
        ),
        MenuBarAuditRow(
            rowNumber: 31,
            title: "Audit row 31: menu utility actions are visible, enabled, and 40pt",
            targets: [
                MenuBarAuditTarget("transcripted.menubar.utility.check-updates", requiresEnabled: nil),
                MenuBarAuditTarget("transcripted.menubar.utility.open-transcripted"),
                MenuBarAuditTarget("transcripted.menubar.utility.settings"),
                MenuBarAuditTarget("transcripted.menubar.utility.quit"),
            ],
            minimumHitSize: 40
        ),
    ]

    struct Failure: Equatable {
        let checkID: String
        let title: String
        let target: String
        let detail: String
    }

    static func firstFailure(in observed: [AXObservedElement], rows: [MenuBarAuditRow] = manualProofTailRows) -> Failure? {
        let observedByIdentifier = Dictionary(uniqueKeysWithValues: observed.compactMap { element -> (String, AXObservedElement)? in
            guard let identifier = element.identifier else { return nil }
            return (identifier, element)
        })

        for row in rows {
            for target in row.targets {
                guard let element = observedByIdentifier[target.identifier] else {
                    return Failure(
                        checkID: row.checkID,
                        title: row.title,
                        target: target.identifier,
                        detail: "Expected menu action identifier was missing from the AX tree."
                    )
                }
                if let requiresEnabled = target.requiresEnabled, element.isEnabled != requiresEnabled {
                    return Failure(
                        checkID: row.checkID,
                        title: row.title,
                        target: target.identifier,
                        detail: "Expected AXEnabled=\(requiresEnabled), got \(String(describing: element.isEnabled))."
                    )
                }
                guard let frame = element.frame else {
                    return Failure(
                        checkID: row.checkID,
                        title: row.title,
                        target: target.identifier,
                        detail: "Expected a readable AX frame for hit-target proof."
                    )
                }
                if frame.width < row.minimumHitSize || frame.height < row.minimumHitSize {
                    return Failure(
                        checkID: row.checkID,
                        title: row.title,
                        target: target.identifier,
                        detail: "Expected at least \(Int(row.minimumHitSize))x\(Int(row.minimumHitSize))pt hit target, got \(Int(frame.width))x\(Int(frame.height))pt."
                    )
                }
            }
        }
        return nil
    }
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

struct UIAutomationSmokeReport: Codable, Equatable, ReportWritable {
    let runID: String
    let status: UIAutomationSmokeStatus
    let exitCode: Int32
    let generatedAt: String
    let appBundlePath: String
    let isolatedHomePath: String?
    let onboardingIsolatedHomePath: String?
    let appLogPath: String?
    let onboardingAppLogPath: String?
    let reportPath: String?
    let checks: [UIAutomationSmokeCheck]

    func printText() {
        let passed = checks.filter { $0.status == .pass }.count
        let flagged = checks.count - passed
        switch status {
        case .pass:
            print("PASS: tested \(passed)/\(checks.count) UI checks. Onboarding, menu bar, Home, Settings, and navigation are scriptable.")
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
        if let onboardingAppLogPath {
            print("Onboarding app log: \(onboardingAppLogPath)")
        }
    }
}

struct UIAutomationSmokeReportBuilder {
    let runID: String
    let appBundlePath: String
    let reportPath: String?
    var isolatedHomePath: String?
    var onboardingIsolatedHomePath: String?
    var appLogPath: String?
    var onboardingAppLogPath: String?
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
            onboardingIsolatedHomePath: onboardingIsolatedHomePath,
            appLogPath: appLogPath,
            onboardingAppLogPath: onboardingAppLogPath,
            reportPath: reportPath,
            checks: checks
        )
    }
}
