import Foundation

final class FirstRunReliabilitySmokeRunner {
    private let appBundleURL: URL
    private let reportPath: String?
    let timeout: TimeInterval
    let fileManager: FileManager
    private let runID = UUID().uuidString

    init(
        appBundlePath: String,
        reportPath: String?,
        timeout: Double,
        fileManager: FileManager = .default
    ) {
        self.appBundleURL = URL(fileURLWithPath: appBundlePath).standardizedFileURL
        self.reportPath = reportPath
        self.timeout = max(5, timeout)
        self.fileManager = fileManager
    }

    func run(generatedAt: Date = Date()) -> FirstRunReliabilitySmokeReport {
        let evidenceRoot = resolvedEvidenceRoot()
        var scenarios: [FirstRunReliabilityScenario] = []
        let executableURL = appBundleURL.appendingPathComponent("Contents/MacOS/Transcripted", isDirectory: false)

        guard NativeSmokeIsolation.isAllowed() else {
            scenarios.append(FirstRunReliabilityScenario(
                id: "native-smoke-isolation",
                status: .warn,
                detail: NativeSmokeIsolation.blockedMessage,
                reportPaths: [],
                logPaths: [],
                isolatedHomePaths: [],
                containerPaths: [],
                launches: []
            ))
            return buildReport(scenarios: scenarios, evidenceRoot: evidenceRoot, generatedAt: generatedAt)
        }

        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            scenarios.append(
                FirstRunReliabilityScenario(
                    id: "harness-bootstrap",
                    status: .fail,
                    detail: "Packaged app executable is missing: \(executableURL.path)",
                    reportPaths: [],
                    logPaths: [],
                    isolatedHomePaths: [],
                    containerPaths: [],
                    launches: []
                )
            )
            return buildReport(
                scenarios: scenarios,
                evidenceRoot: evidenceRoot,
                generatedAt: generatedAt
            )
        }

        do {
            try fileManager.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        } catch {
            scenarios.append(
                FirstRunReliabilityScenario(
                    id: "harness-bootstrap",
                    status: .fail,
                    detail: "Failed to prepare first-run evidence root: \(error.localizedDescription)",
                    reportPaths: [],
                    logPaths: [],
                    isolatedHomePaths: [],
                    containerPaths: [],
                    launches: []
                )
            )
            return buildReport(
                scenarios: scenarios,
                evidenceRoot: evidenceRoot,
                generatedAt: generatedAt
            )
        }

        let onboardingWorkspace = makeWorkspace(id: "zero-state", evidenceRoot: evidenceRoot)
        scenarios.append(runZeroStateAndRestartScenario(executableURL: executableURL, workspace: onboardingWorkspace))

        scenarios.append(runPermissionsMatrixScenario(executableURL: executableURL, evidenceRoot: evidenceRoot))

        let staleCacheWorkspace = makeWorkspace(id: "stale-model-cache", evidenceRoot: evidenceRoot)
        scenarios.append(runStaleModelCacheScenario(executableURL: executableURL, workspace: staleCacheWorkspace))

        let cachedModelWorkspace = makeWorkspace(id: "cached-model", evidenceRoot: evidenceRoot)
        scenarios.append(runCachedModelScenario(executableURL: executableURL, workspace: cachedModelWorkspace))

        let blockedDestinationWorkspace = makeWorkspace(id: "destination-unwritable", evidenceRoot: evidenceRoot)
        scenarios.append(runUnwritableDestinationScenario(executableURL: executableURL, workspace: blockedDestinationWorkspace))

        let helperWorkspace = makeWorkspace(id: "helper-install", evidenceRoot: evidenceRoot)
        scenarios.append(runHelperInstallScenario(executableURL: executableURL, workspace: helperWorkspace))

        let repairWorkspace = makeWorkspace(id: "helper-repair", evidenceRoot: evidenceRoot)
        scenarios.append(runHelperRepairScenario(executableURL: executableURL, workspace: repairWorkspace))

        scenarios.append(runHelperRefreshScenario(executableURL: executableURL, workspace: helperWorkspace))
        scenarios.append(runHelperReadySecondLaunchScenario(executableURL: executableURL, workspace: helperWorkspace))

        let syntheticWorkspace = makeWorkspace(id: "synthetic-models", evidenceRoot: evidenceRoot)
        scenarios.append(runSyntheticModelMatrixScenario(executableURL: executableURL, workspace: syntheticWorkspace))

        return buildReport(
            scenarios: scenarios,
            evidenceRoot: evidenceRoot,
            generatedAt: generatedAt
        )
    }

    private func buildReport(
        scenarios: [FirstRunReliabilityScenario],
        evidenceRoot: URL,
        generatedAt: Date
    ) -> FirstRunReliabilitySmokeReport {
        FirstRunReliabilitySmokeReport(
            runID: runID,
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            appBundlePath: appBundleURL.path,
            evidenceRootPath: evidenceRoot.path,
            reportPath: reportPath,
            scenarios: scenarios
        )
    }

    private func runZeroStateAndRestartScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        let first = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "zero-state-first",
            options: FirstRunLaunchOptions(onboardingCompleted: false, forceOnboarding: true)
        )
        let second = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "zero-state-restart",
            options: FirstRunLaunchOptions(onboardingCompleted: false, forceOnboarding: true)
        )
        return buildScenario(
            id: "zero-state-and-restart",
            launches: [first, second],
            successDetail: "Two launches from the same empty isolated profile kept onboarding incomplete, model state idle, and the same cached system-audio permission flags across restart."
        ) { reports in
            guard reports.count == 2 else {
                return ["expected two successful launch reports"]
            }
            var failures = isolationFailures(in: reports[0], workspace: workspace)
            failures.append(contentsOf: isolationFailures(in: reports[1], workspace: workspace))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].permissionsOnboardingCompleted == false
                    && reports[1].permissionsOnboardingCompleted == false,
                message: "onboarding should stay incomplete across restart"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].actualModelState == "not_loaded"
                    && reports[1].actualModelState == "not_loaded",
                message: "zero-state launches should keep actual model state at not_loaded"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].helper.stateAfter == "notInstalled"
                    && reports[1].helper.stateAfter == "notInstalled",
                message: "helper should stay notInstalled in the empty profile"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].runtime.systemAudioPermissionKnown == reports[1].runtime.systemAudioPermissionKnown
                    && reports[0].runtime.systemAudioPermissionGranted == reports[1].runtime.systemAudioPermissionGranted,
                message: "zero-state restart should preserve the same cached system-audio permission flags"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].runtime.captureLibraryPath == reports[1].runtime.captureLibraryPath,
                message: "restart should keep the same isolated capture-library path"
            ))
            return failures
        }
    }

    private func runPermissionsMatrixScenario(
        executableURL: URL,
        evidenceRoot: URL
    ) -> FirstRunReliabilityScenario {
        let deniedWorkspace = makeWorkspace(id: "permissions-matrix-denied", evidenceRoot: evidenceRoot)
        let grantedWorkspace = makeWorkspace(id: "permissions-matrix-granted", evidenceRoot: evidenceRoot)
        let denied = launch(
            executableURL: executableURL,
            workspace: deniedWorkspace,
            tag: "permissions-denied",
            options: FirstRunLaunchOptions(
                onboardingCompleted: false,
                forceOnboarding: true,
                accountPreferenceOverrides: [
                    "systemAudioRecordingPermissionKnown": true,
                    "systemAudioRecordingPermissionGranted": false,
                ]
            )
        )
        let granted = launch(
            executableURL: executableURL,
            workspace: grantedWorkspace,
            tag: "permissions-granted",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                accountPreferenceOverrides: [
                    "systemAudioRecordingPermissionKnown": true,
                    "systemAudioRecordingPermissionGranted": true,
                ]
            )
        )
        return buildScenario(
            id: "permissions-state-matrix",
            launches: [denied, granted],
            successDetail: "The packaged app preserved incomplete and completed onboarding prefs while exercising cached denied and granted system-audio permission flags from separate isolated launch defaults."
        ) { reports in
            guard reports.count == 2 else {
                return ["expected denied and granted permission launch reports"]
            }
            let denied = reports[0]
            let granted = reports[1]
            var failures = isolationFailures(in: denied, workspace: deniedWorkspace)
            failures.append(contentsOf: isolationFailures(in: granted, workspace: grantedWorkspace))
            failures.append(contentsOf: expectedBooleanFailures(
                denied.runtime.systemAudioPermissionKnown && !denied.runtime.systemAudioPermissionGranted,
                message: "denied launch should report the cached known=true granted=false system-audio flags"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                granted.runtime.systemAudioPermissionKnown && granted.runtime.systemAudioPermissionGranted,
                message: "granted launch should report the cached known=true granted=true system-audio flags"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                denied.runtime.homePath != granted.runtime.homePath
                    && denied.runtime.containerPath != granted.runtime.containerPath,
                message: "cached permission-state coverage should launch denied and granted cases from separate isolated homes and containers"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                denied.permissionsOnboardingCompleted == false && granted.permissionsOnboardingCompleted,
                message: "permission matrix should preserve incomplete and completed onboarding states while covering cached permission-state restoration"
            ))
            return failures
        }
    }

    private func runStaleModelCacheScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        seedStaleModelCache(in: workspace.homeURL)
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "stale-model-cache",
            options: FirstRunLaunchOptions(onboardingCompleted: true, forceOnboarding: false)
        )
        return buildScenario(
            id: "stale-model-cache",
            launches: [outcome],
            successDetail: "Stale local-model cache folders stayed isolated and did not trick first run into reporting a reusable active model."
        ) { reports in
            guard let report = reports.first else {
                return ["expected stale-cache launch report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace)
            failures.append(contentsOf: expectedBooleanFailures(
                report.cachedModelDirectory == nil,
                message: "stale cache should not report an active cached model directory"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.actualModelState == "not_loaded",
                message: "stale cache should keep actual model state at not_loaded"
            ))
            return failures
        }
    }

    private func runCachedModelScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        seedActiveModelCache(in: workspace.homeURL)
        let first = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "cached-model-first",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                launchDefaultsOverrides: ["transcription-model-preference": "parakeet-tdt-v3"],
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTIVATE_CACHED_MODEL": "1",
                ]
            )
        )
        let restart = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "cached-model-restart",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                launchDefaultsOverrides: ["transcription-model-preference": "parakeet-tdt-v3"],
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTIVATE_CACHED_MODEL": "1",
                ]
            )
        )
        return buildScenario(
            id: "cached-model-detected",
            launches: [first, restart],
            successDetail: "A complete synthetic Parakeet cache stayed cached across two packaged-app launches from the same isolated profile without entering the download state."
        ) { reports in
            guard reports.count == 2 else {
                return ["expected cached-model first-launch and restart reports"]
            }
            var failures = isolationFailures(in: reports[0], workspace: workspace)
            failures.append(contentsOf: isolationFailures(in: reports[1], workspace: workspace))
            failures.append(contentsOf: expectedBooleanFailures(
                reports.allSatisfy { $0.actualModelState == "cached" },
                message: "active model cache should remain cached on first launch and restart without entering the download state"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports.allSatisfy {
                    $0.cachedModelDirectory?.hasSuffix("parakeet-tdt-0.6b-v3") == true
                },
                message: "both cached-model launches should report the synthetic Parakeet directory"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].runtime.homePath == reports[1].runtime.homePath
                    && reports[0].runtime.containerPath == reports[1].runtime.containerPath,
                message: "cached-model restart should reuse the same isolated home and container"
            ))
            return failures
        }
    }

    private func runUnwritableDestinationScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        let blockedParent = workspace.rootURL.appendingPathComponent("blocked-parent", isDirectory: true)
        try? fileManager.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blockedParent.path)
        let blockedContainer = blockedParent.appendingPathComponent("Transcripted", isDirectory: true)
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "destination-unwritable",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                containerURL: blockedContainer
            )
        )
        return buildScenario(
            id: "destination-unwritable",
            launches: [outcome],
            successDetail: "The harness caught the safe stand-in for full or read-only destinations: app-owned paths stayed isolated and write probes failed loudly."
        ) { reports in
            guard let report = reports.first else {
                return ["expected destination failure launch report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace, expectedContainerURL: blockedContainer)
            failures.append(contentsOf: expectedBooleanFailures(
                !report.runtime.appSupportWritable && !report.runtime.captureLibraryWritable && !report.runtime.cacheWritable,
                message: "blocked destination should report every app-owned store as unwritable"
            ))
            return failures
        }
    }

    private func runHelperInstallScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "helper-install",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTION": "install-helper",
                ]
            )
        )
        return buildScenario(
            id: "helper-install",
            launches: [outcome],
            successDetail: "The packaged app installed the bundled MCP helper into the isolated container, wrote an isolated Claude config, and passed the helper self-test."
        ) { reports in
            guard let report = reports.first else {
                return ["expected helper install launch report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace)
            failures.append(contentsOf: helperInstalledFailures(report))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.stateBefore == "notInstalled",
                message: "helper install should start from notInstalled"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.selfTestOK == true,
                message: "helper install should report a passing self-test"
            ))
            return failures
        }
    }

    private func runHelperRepairScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        seedMalformedClaudeConfig(in: workspace.homeURL)
        seedInstalledHelperStub(at: workspace.containerURL.appendingPathComponent("mcp/transcripted-mcp", isDirectory: false))
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "helper-repair",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTION": "install-helper",
                ]
            )
        )
        return buildScenario(
            id: "helper-repair",
            launches: [outcome],
            successDetail: "Malformed helper config was backed up, repaired, and replaced with the bundled helper inside the isolated harness."
        ) { reports in
            guard let report = reports.first else {
                return ["expected helper repair launch report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace)
            failures.append(contentsOf: helperInstalledFailures(report))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.stateBefore == "needsRepair",
                message: "repair scenario should start from needsRepair"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.backupPath != nil,
                message: "repair scenario should back up the unreadable Claude config"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.configIsReadableBefore == false && report.helper.configIsReadableAfter == true,
                message: "repair scenario should rewrite the unreadable Claude config"
            ))
            return failures
        }
    }

    private func runHelperRefreshScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        seedInstalledHelperStub(at: workspace.containerURL.appendingPathComponent("mcp/transcripted-mcp", isDirectory: false))
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "helper-refresh",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTION": "refresh-helper",
                ]
            )
        )
        return buildScenario(
            id: "helper-refresh-after-update",
            launches: [outcome],
            successDetail: "A stale installed MCP helper was refreshed in place to match the bundled helper, which approximates an app-update replacement path."
        ) { reports in
            guard let report = reports.first else {
                return ["expected helper refresh launch report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace)
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.stateBefore == "needsRepair",
                message: "refresh scenario should detect a stale helper as needsRepair before refresh"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.refreshed == true,
                message: "refresh scenario should report refreshed=true"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.installedBinaryMatchesBundledAfter,
                message: "refresh scenario should leave the installed helper matching the bundled helper"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.stateAfter == "installed",
                message: "refresh scenario should end in installed state"
            ))
            return failures
        }
    }

    private func runHelperReadySecondLaunchScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "helper-ready-second-launch",
            options: FirstRunLaunchOptions(onboardingCompleted: true, forceOnboarding: false)
        )
        return buildScenario(
            id: "ready-second-launch",
            launches: [outcome],
            successDetail: "A second launch after helper install and refresh stayed ready: the isolated helper remained installed, configured, and matched to the packaged build."
        ) { reports in
            guard let report = reports.first else {
                return ["expected second-launch readiness report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace)
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.stateBefore == "installed" && report.helper.stateAfter == "installed",
                message: "second launch should keep helper state installed before and after reporting"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.installedBinaryMatchesBundledAfter,
                message: "second launch should keep the installed helper aligned with the bundled helper"
            ))
            return failures
        }
    }

    private func runSyntheticModelMatrixScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        let failed = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "synthetic-failed",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_SYNTHETIC_MODEL_STATE": "failed:Synthetic setup failed",
                ]
            )
        )
        let resumed = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "synthetic-resumed",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_SYNTHETIC_MODEL_STATE": "downloading:0.73",
                ]
            )
        )
        let ready = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "synthetic-ready",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_SYNTHETIC_MODEL_STATE": "ready",
                ]
            )
        )
        return buildScenario(
            id: "synthetic-model-matrix",
            launches: [failed, resumed, ready],
            successDetail: "Synthetic model states covered failure, retry copy, resumed download progress, and ready-state copy without triggering a real model download."
        ) { reports in
            guard reports.count == 3 else {
                return ["expected three synthetic model launch reports"]
            }
            let failed = reports[0]
            let resumed = reports[1]
            let ready = reports[2]
            var failures = isolationFailures(in: failed, workspace: workspace)
            failures.append(contentsOf: isolationFailures(in: resumed, workspace: workspace))
            failures.append(contentsOf: isolationFailures(in: ready, workspace: workspace))
            failures.append(contentsOf: expectedBooleanFailures(
                failed.syntheticModel?.card.tone == "failed"
                    && failed.syntheticModel?.card.status == "Retry needed"
                    && failed.syntheticModel?.action.subtitle.contains("Try again") == true,
                message: "failed synthetic state should keep retry-focused first-run copy"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                resumed.syntheticModel?.card.tone == "working"
                    && resumed.syntheticModel?.card.status.contains("73%") == true
                    && resumed.syntheticModel?.card.progress.map { $0 > 0.5 } == true,
                message: "resumed synthetic state should show in-progress download copy and progress"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                ready.syntheticModel?.card.tone == "ready"
                    && ready.syntheticModel?.card.status == "Ready"
                    && ready.syntheticModel?.action.subtitle.isEmpty == true,
                message: "ready synthetic state should expose ready copy with no setup subtitle"
            ))
            return failures
        }
    }

    private func buildScenario(
        id: String,
        launches: [FirstRunReliabilityLaunchOutcome],
        successDetail: String,
        evaluate: ([FirstRunReliabilityAppReport]) -> [String]
    ) -> FirstRunReliabilityScenario {
        let reports = launches.compactMap(\.report)
        let launchFailures = launches.compactMap(\.failureDetail)
        let evaluationFailures = launchFailures.isEmpty ? evaluate(reports) : []
        let failures = launchFailures + evaluationFailures
        let detail = failures.isEmpty ? successDetail : failures.joined(separator: "; ")

        return FirstRunReliabilityScenario(
            id: id,
            status: failures.isEmpty ? .pass : .fail,
            detail: detail,
            reportPaths: launches.map(\.reportURL.path),
            logPaths: launches.map(\.logURL.path),
            isolatedHomePaths: Array(Set(launches.map(\.homeURL.path))).sorted(),
            containerPaths: Array(Set(launches.map(\.containerURL.path))).sorted(),
            launches: reports
        )
    }

    private func isolationFailures(
        in report: FirstRunReliabilityAppReport,
        workspace: FirstRunScenarioWorkspace,
        expectedContainerURL: URL? = nil
    ) -> [String] {
        let expectedContainerPath = FirstRunPathCheck.canonical((expectedContainerURL ?? workspace.containerURL).path)
        let expectedHomePath = FirstRunPathCheck.canonical(workspace.homeURL.path)
        var failures: [String] = []
        failures.append(contentsOf: expectedBooleanFailures(
            report.appLaunched && report.statusItemExists && report.popoverConfigured,
            message: "packaged app should launch far enough to configure the status item and popover"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            FirstRunPathCheck.canonical(report.runtime.homePath) == expectedHomePath,
            message: "report home path should stay inside the isolated HOME"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.runtime.containerPath.map(FirstRunPathCheck.canonical) == expectedContainerPath,
            message: "report container path should match the isolated Transcripted container"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            FirstRunPathCheck.canonical(report.runtime.appSupportPath) == expectedContainerPath,
            message: "app support root should resolve to the isolated Transcripted container"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            FirstRunPathCheck.isInside(report.runtime.captureLibraryPath, root: expectedContainerPath)
                && FirstRunPathCheck.isInside(report.runtime.cachePath, root: expectedContainerPath)
                && FirstRunPathCheck.isInside(report.runtime.logsPath, root: expectedContainerPath)
                && FirstRunPathCheck.isInside(report.runtime.temporaryPath, root: expectedContainerPath)
                && FirstRunPathCheck.isInside(report.runtime.mcpManifestPath, root: expectedContainerPath),
            message: "capture, cache, logs, tmp, and MCP manifest paths should stay inside the isolated container"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            FirstRunPathCheck.isInside(report.helper.configPath, root: expectedHomePath),
            message: "Claude helper config path should stay inside the isolated HOME"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            FirstRunPathCheck.isInside(report.helper.installedBinaryPath, root: expectedContainerPath),
            message: "installed helper path should stay inside the isolated Transcripted container"
        ))
        return failures
    }

    private func helperInstalledFailures(_ report: FirstRunReliabilityAppReport) -> [String] {
        var failures: [String] = []
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.error == nil,
            message: "helper action should finish without an error"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.bundledBinaryExists,
            message: "packaged app should include the bundled MCP helper"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.installedBinaryExistsAfter,
            message: "helper action should leave an installed helper binary"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.installedBinaryMatchesBundledAfter,
            message: "installed helper should match the bundled helper after the action"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.stateAfter == "installed",
            message: "helper action should leave the helper in installed state"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.configuredCommandPathAfter == report.helper.installedBinaryPath,
            message: "Claude config should point at the installed helper path"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.configIsReadableAfter,
            message: "Claude config should be readable after the helper action"
        ))
        return failures
    }

    private func expectedBooleanFailures(_ condition: Bool, message: String) -> [String] {
        condition ? [] : [message]
    }

    private func resolvedEvidenceRoot() -> URL {
        if let reportPath, !reportPath.isEmpty {
            return URL(fileURLWithPath: reportPath)
                .deletingLastPathComponent()
                .appendingPathComponent("packaged-app-first-run-reliability-\(runID)", isDirectory: true)
        }
        return fileManager.temporaryDirectory
            .appendingPathComponent("transcripted-first-run-reliability-\(runID)", isDirectory: true)
    }

    private func makeWorkspace(id: String, evidenceRoot: URL) -> FirstRunScenarioWorkspace {
        let rootURL = evidenceRoot.appendingPathComponent(id, isDirectory: true)
        return FirstRunScenarioWorkspace(
            rootURL: rootURL,
            homeURL: rootURL.appendingPathComponent("home", isDirectory: true),
            containerURL: rootURL.appendingPathComponent("container", isDirectory: true),
            reportsDirectoryURL: rootURL.appendingPathComponent("reports", isDirectory: true),
            logsDirectoryURL: rootURL.appendingPathComponent("logs", isDirectory: true)
        )
    }
}

enum FirstRunPathCheck {
    static func canonical(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    static func isInside(_ candidate: String, root: String) -> Bool {
        canonical(candidate).hasPrefix(canonical(root) + "/")
    }
}
