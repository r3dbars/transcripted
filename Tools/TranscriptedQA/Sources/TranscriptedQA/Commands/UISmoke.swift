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
            "transcripted.menubar.utility.check-updates",
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
            "transcripted.settings.sidebar.dictations",
            "transcripted.settings.sidebar.people",
            "transcripted.settings.sidebar.connect-agent",
            "transcripted.settings.sidebar.settings-toggle",
        ]
        let homeIDs = [
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
            guard appInspector.performPressOrClick(identifier: check.triggerID) else {
                builder.add(.fail(
                    check.id,
                    check.title,
                    target: check.triggerID,
                    detail: "Could not open this sidebar surface."
                ))
                return builder.build()
            }
            guard waitUntil(timeout: timeout, description: check.title, condition: {
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

        let settingsTabIDs = [
            "transcripted.settings.tab.general",
            "transcripted.settings.tab.storage",
            "transcripted.settings.tab.beta",
            "transcripted.settings.tab.support",
            "transcripted.settings.tab.about",
        ]

        guard waitUntil(timeout: timeout, description: "settings tabs", condition: {
            let ids = Set(appInspector.snapshot(maxDepth: 12).compactMap(\.identifier))
            return settingsTabIDs.allSatisfy(ids.contains)
        }) else {
            builder.add(.fail(
                "settings-pages-toggle",
                "Settings area opens from the sidebar toggle",
                target: "Transcripted Settings",
                detail: "Settings tab strip did not appear after pressing the toggle.",
                observed: observedElements(for: settingsTabIDs, inspector: appInspector)
            ))
            return builder.build()
        }
        builder.add(.pass(
            "settings-pages-toggle",
            "Settings area opens from the sidebar toggle",
            target: "transcripted.settings.sidebar.settings-toggle"
        ))

        guard appInspector.performPressOrClick(identifier: "transcripted.settings.tab.general") else {
            builder.add(.fail(
                "settings-navigation",
                "Settings tabs navigate to General",
                target: "transcripted.settings.tab.general",
                detail: "Could not press the General settings tab."
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
            "Settings tabs navigate to General",
            target: "transcripted.settings.tab.general"
        ))
        builder.add(.pass(
            "settings-general",
            "General settings controls are visible",
            target: "General",
            observed: observedElements(for: generalIDs, inspector: appInspector)
        ))

        let consolidatedGeneralChecks: [(id: String, title: String, requiredIDs: [String])] = [
            (
                id: "settings-models-consolidated",
                title: "Models settings are exposed in General",
                requiredIDs: ["transcripted.settings.general.disclosure.transcription-model"]
            ),
            (
                id: "settings-shortcuts-consolidated",
                title: "Shortcut settings are exposed in General",
                requiredIDs: ["transcripted.settings.general.disclosure.keyboard-shortcuts"]
            ),
            (
                id: "settings-privacy-consolidated",
                title: "Privacy settings are exposed in General",
                requiredIDs: ["transcripted.settings.general.disclosure.privacy"]
            ),
        ]
        let generalSnapshotIDs = Set(appInspector.snapshot(maxDepth: 12).compactMap(\.identifier))
        for check in consolidatedGeneralChecks {
            if check.requiredIDs.allSatisfy(generalSnapshotIDs.contains) {
                builder.add(.pass(
                    check.id,
                    check.title,
                    target: "General",
                    observed: observedElements(for: check.requiredIDs, inspector: appInspector)
                ))
            } else {
                builder.add(.fail(
                    check.id,
                    check.title,
                    target: "General",
                    detail: "General did not expose the consolidated settings disclosure.",
                    observed: observedElements(for: check.requiredIDs, inspector: appInspector)
                ))
                return builder.build()
            }
        }

        let settingsPageChecks: [(id: String, title: String, triggerID: String, requiredIDs: [String])] = [
            (
                id: "settings-storage",
                title: "Storage settings tab is reachable",
                triggerID: "transcripted.settings.tab.storage",
                requiredIDs: ["transcripted.settings.page.storage"]
            ),
            (
                id: "settings-beta",
                title: "Beta settings tab is reachable",
                triggerID: "transcripted.settings.tab.beta",
                requiredIDs: ["transcripted.settings.page.beta"]
            ),
            (
                id: "settings-support",
                title: "Support settings tab is reachable",
                triggerID: "transcripted.settings.tab.support",
                requiredIDs: ["transcripted.settings.page.support"]
            ),
            (
                id: "settings-about",
                title: "About settings tab is reachable",
                triggerID: "transcripted.settings.tab.about",
                requiredIDs: ["transcripted.settings.page.about"]
            ),
        ]

        for check in settingsPageChecks {
            guard appInspector.performPressOrClick(identifier: check.triggerID) else {
                builder.add(.fail(
                    check.id,
                    check.title,
                    target: check.triggerID,
                    detail: "Could not open this settings tab."
                ))
                return builder.build()
            }
            guard waitUntil(timeout: timeout, description: check.title, condition: {
                let ids = Set(appInspector.snapshot(maxDepth: 12).compactMap(\.identifier))
                return check.requiredIDs.allSatisfy(ids.contains)
            }) else {
                builder.add(.fail(
                    check.id,
                    check.title,
                    target: check.triggerID,
                    detail: "Settings tab did not expose expected automation identifiers.",
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
            terminate(process: launched.process)
        }

        let appAX = AXUIElementCreateApplication(launched.process.processIdentifier)
        AXUIElementSetMessagingTimeout(appAX, 2)
        let appInspector = AXInspector(root: appAX)
        let onboardingMaxDepth = 24

        guard waitUntil(timeout: timeout, description: "onboarding AX tree", condition: {
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

        // The welcome step now carries the privacy pills inline, so one press
        // lands directly on the use-case choice.
        guard appInspector.performPressOrClick(identifier: navPrimaryID, maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-navigation",
                "Onboarding primary navigation advances to use-case choice",
                target: navPrimaryID,
                detail: "Could not press the onboarding primary button on the welcome step."
            ))
            return false
        }
        pauseForUITransition()

        let useCaseIDs = [
            "transcripted.onboarding.use-case.meetings",
            "transcripted.onboarding.use-case.dictation",
            navPrimaryID,
            "transcripted.onboarding.nav.back",
        ]
        guard let useCaseObserved = waitForObservedElements(useCaseIDs, inspector: appInspector, maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-use-case",
                "Onboarding exposes meeting and dictation use-case choices",
                target: "Transcripted onboarding",
                detail: "The use-case step did not expose the expected automation identifiers.",
                observed: observedElements(for: useCaseIDs, inspector: appInspector, maxDepth: onboardingMaxDepth)
            ))
            return false
        }
        builder.add(.pass(
            "onboarding-use-case",
            "Onboarding exposes meeting and dictation use-case choices",
            target: "Transcripted onboarding",
            observed: useCaseObserved
        ))

        guard appInspector.performPressOrClick(identifier: "transcripted.onboarding.use-case.dictation", maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-dictation-path",
                "Onboarding can choose the dictation setup path",
                target: "transcripted.onboarding.use-case.dictation",
                detail: "Could not select the dictation use-case card."
            ))
            return false
        }
        pauseForUITransition()

        guard appInspector.performPressOrClick(identifier: navPrimaryID, maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-dictation-path",
                "Onboarding can choose the dictation setup path",
                target: navPrimaryID,
                detail: "Could not continue from dictation use-case choice to permissions."
            ))
            return false
        }
        pauseForUITransition()

        let dictationPermissionIDs = [
            "transcripted.onboarding.permissions.microphone",
            "transcripted.onboarding.permissions.accessibility",
        ]
        guard let dictationObserved = waitForObservedElements(dictationPermissionIDs, inspector: appInspector, maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-dictation-permissions",
                "Dictation onboarding exposes required permission actions",
                target: "Transcripted onboarding",
                detail: "The dictation permission step did not expose microphone and accessibility actions.",
                observed: observedElements(for: dictationPermissionIDs, inspector: appInspector, maxDepth: onboardingMaxDepth)
            ))
            return false
        }
        builder.add(.pass(
            "onboarding-dictation-permissions",
            "Dictation onboarding exposes required permission actions",
            target: "Transcripted onboarding",
            observed: dictationObserved
        ))

        guard appInspector.performPressOrClick(identifier: "transcripted.onboarding.nav.back", maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-meeting-path",
                "Onboarding can return and choose the meetings setup path",
                target: "transcripted.onboarding.nav.back",
                detail: "Could not navigate back to the use-case choices."
            ))
            return false
        }
        pauseForUITransition()

        guard waitForObservedElements(useCaseIDs, inspector: appInspector, maxDepth: onboardingMaxDepth) != nil,
              appInspector.performPressOrClick(identifier: "transcripted.onboarding.use-case.meetings", maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-meeting-path",
                "Onboarding can return and choose the meetings setup path",
                target: "transcripted.onboarding.use-case.meetings",
                detail: "Could not select the meetings use-case card."
            ))
            return false
        }
        pauseForUITransition()

        guard appInspector.performPressOrClick(identifier: navPrimaryID, maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-meeting-path",
                "Onboarding can return and choose the meetings setup path",
                target: navPrimaryID,
                detail: "Could not continue from meetings use-case choice to permissions."
            ))
            return false
        }
        pauseForUITransition()

        let meetingPermissionIDs = [
            "transcripted.onboarding.permissions.microphone",
            "transcripted.onboarding.permissions.system-audio",
            "transcripted.onboarding.permissions.leave-dictation-shortcuts-off",
        ]
        guard let meetingObserved = waitForObservedElements(meetingPermissionIDs, inspector: appInspector, maxDepth: onboardingMaxDepth) else {
            builder.add(.fail(
                "onboarding-meeting-permissions",
                "Meeting onboarding exposes required permission actions",
                target: "Transcripted onboarding",
                detail: "The meeting permission step did not expose microphone, system audio, and shortcut preference actions.",
                observed: observedElements(for: meetingPermissionIDs, inspector: appInspector, maxDepth: onboardingMaxDepth)
            ))
            return false
        }
        builder.add(.pass(
            "onboarding-meeting-permissions",
            "Meeting onboarding exposes required permission actions",
            target: "Transcripted onboarding",
            observed: meetingObserved
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
        environment["HOME"] = isolatedHome.path
        environment["CFFIXED_USER_HOME"] = isolatedHome.path
        environment.removeValue(forKey: "__CFBundleIdentifier")
        environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
        environment["TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS"] = "1"
        environment["TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"] = "1"
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
        return waitForNode(timeout: timeout, inspector: AXInspector(root: systemUIServerAX), description: "Transcripted status item fallback", match: { node in
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

    private func waitUntil(timeout: TimeInterval, description: String, condition: () -> Bool) -> Bool {
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

private struct LaunchedApp {
    let process: Process
    let logURL: URL
}

private struct AXInspector {
    let root: AXUIElement

    func first(identifier: String, maxDepth: Int = 12, maxNodes: Int = 2_000) -> AXNode? {
        snapshotNodes(maxDepth: maxDepth, maxNodes: maxNodes).first { $0.observed.identifier == identifier }
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
        guard let frame = first(identifier: identifier, maxDepth: maxDepth, maxNodes: maxNodes)?.observed.frame else {
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
            rowNumber: 18,
            title: "Audit row 18: menu popover core actions are visible and scriptable",
            targets: [
                MenuBarAuditTarget("transcripted.menubar.primary.home"),
                MenuBarAuditTarget("transcripted.menubar.primary.recent-meetings", requiresEnabled: nil),
            ],
            minimumHitSize: 40
        ),
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
                MenuBarAuditTarget("transcripted.menubar.utility.connect-agent"),
                MenuBarAuditTarget("transcripted.menubar.utility.submit-feedback"),
                MenuBarAuditTarget("transcripted.menubar.utility.check-updates", requiresEnabled: nil),
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

struct UIAutomationSmokeReport: Codable, Equatable {
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
            appInspector.snapshot(maxDepth: 9).contains { $0.identifier == "transcripted.menubar.primary.home" }
        }) else {
            checks.append(.fail("menu-visible", "Menu bar popover is visible", target: "transcripted.menubar.primary.home", detail: "Home row did not appear."))
            return false
        }
        checks.append(.pass("menu-visible", "Menu bar popover is visible", target: "transcripted.menubar.primary.home"))

        guard appInspector.performPressOrClick(identifier: "transcripted.menubar.primary.home") else {
            checks.append(.fail("open-home", "Home opens from the menu bar", target: "transcripted.menubar.primary.home", detail: "Could not press the Home row."))
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

        guard waitUntil(timeout: timeout, condition: {
            appInspector.snapshot(maxDepth: 12).contains { $0.identifier == "transcripted.settings.tab.general" }
        }) else {
            checks.append(.fail("settings-tabs", "Settings tabs are visible", target: "transcripted.settings.tab.general", detail: "Settings tab strip did not appear."))
            return false
        }

        guard appInspector.performPressOrClick(identifier: "transcripted.settings.tab.general") else {
            checks.append(.fail("settings-general", "General settings tab opens", target: "transcripted.settings.tab.general", detail: "Could not press the General settings tab."))
            return false
        }

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
