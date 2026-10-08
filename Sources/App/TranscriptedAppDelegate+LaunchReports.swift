// TranscriptedAppDelegate+LaunchReports.swift
// Launch UI smoke and first-run reliability reports for automated launches

import SwiftUI
import AppKit
import AVFoundation
import Carbon
import Combine
import Darwin
import TranscriptedCore
import UniformTypeIdentifiers

private struct FirstRunReliabilitySmokeReport: Codable {
    let appLaunched: Bool
    let statusItemExists: Bool
    let popoverConfigured: Bool
    let permissionsOnboardingCompleted: Bool
    let selectedModel: String
    let actualModelState: String
    let cachedModelDirectory: String?
    let launchToInteractiveMs: Double?
    let menuContent: MenuBarContentSmokeSnapshot
    let runtime: FirstRunReliabilityRuntimeState
    let helper: FirstRunReliabilityHelperReport
    let syntheticModel: FirstRunReliabilitySyntheticModelReport?
}

private struct FirstRunReliabilityRuntimeState: Codable {
    let homePath: String
    let containerPath: String?
    let appSupportPath: String
    let captureLibraryPath: String
    let meetingsPath: String
    let dictationsPath: String
    let writingPath: String
    let cachePath: String
    let logsPath: String
    let temporaryPath: String
    let mcpManifestPath: String
    let mcpManifestExists: Bool
    let systemAudioPermissionKnown: Bool
    let systemAudioPermissionGranted: Bool
    let appSupportWritable: Bool
    let captureLibraryWritable: Bool
    let cacheWritable: Bool
}

private struct FirstRunReliabilityHelperReport: Codable {
    let action: String
    let backupPath: String?
    let bundledBinaryExists: Bool
    let bundledBinaryPath: String?
    let configuredCommandPathAfter: String?
    let configuredCommandPathBefore: String?
    let configIsReadableAfter: Bool
    let configIsReadableBefore: Bool
    let configPath: String
    let error: String?
    let installedBinaryExistsAfter: Bool
    let installedBinaryExistsBefore: Bool
    let installedBinaryMatchesBundledAfter: Bool
    let installedBinaryMatchesBundledBefore: Bool
    let installedBinaryPath: String
    let refreshed: Bool?
    let selfTestDictationFileCount: Int?
    let selfTestMeetingFileCount: Int?
    let selfTestOK: Bool?
    let stateAfter: String
    let stateBefore: String
}

private struct FirstRunReliabilitySyntheticModelReport: Codable {
    let requestedState: String
    let action: FirstRunReliabilitySyntheticAction
    let card: FirstRunReliabilitySyntheticCard
}

private struct FirstRunReliabilitySyntheticAction: Codable {
    let isEnabled: Bool
    let subtitle: String
    let symbolName: String
    let title: String
}

private struct FirstRunReliabilitySyntheticCard: Codable {
    let detail: String
    let progress: Double?
    let status: String
    let title: String
    let tone: String
}

private enum FirstRunReliabilitySmokeAction: String {
    case installHelper = "install-helper"
    case refreshHelper = "refresh-helper"
    case reportOnly = "report-only"
}

extension TranscriptedAppDelegate {
    func writeLaunchUISmokeReportIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let reportPath = environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT"],
              !reportPath.isEmpty else {
            return
        }
        guard AutomatedLaunchEnvironment.isActive(environment: environment) else { return }
        Task { @MainActor in
            defer { scheduleLaunchUISmokeTerminationIfRequested(environment: environment) }
            var report = menuPanelController.launchUISmokeReport(
                statusItemExists: statusItem != nil,
                popoverConfigured: popover != nil,
                onboardingCompleted: true,
                launchToInteractiveMs: Self.processStartToNowMilliseconds()
            )
            report.meetingOverlayDurationUpdates = await meetingOverlayDurationSmokeUpdates()
            let reportURL = URL(fileURLWithPath: reportPath, isDirectory: false)
            do {
                try FileManager.default.createDirectory(
                    at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: reportURL, options: .atomic)
            } catch {
                NSLog("Failed to write launch UI smoke report: \(error.localizedDescription)")
            }
        }
    }

    /// Drives the actual controller's setup and view-push path without capture,
    /// windows, or a timer. Queued main barriers drain Combine's receive(on:).
    private func meetingOverlayDurationSmokeUpdates() async -> [Int] {
        let ticks = PassthroughSubject<TimeInterval, Never>()
        let controller = MeetingOverlayController()
        var updates: [Int] = []
        controller.setup(meetingSession: appState.meetingSession, durationPublisher: ticks.eraseToAnyPublisher())
        controller.onContentPush = { updates.append(Int($0)) }
        await drainMainQueueForLaunchReport()
        updates.removeAll()
        for tick in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4, 1.99, 2.0, 2.2, 5.0] {
            ticks.send(tick)
        }
        await drainMainQueueForLaunchReport()
        controller.onContentPush = nil
        return updates
    }

    private func drainMainQueueForLaunchReport() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func writeFirstRunReliabilityReportIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard let reportPath = environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_REPORT"],
              !reportPath.isEmpty else {
            return
        }
        defer {
            scheduleFirstRunReliabilityTerminationIfRequested(environment: environment)
        }

        if environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTIVATE_CACHED_MODEL"] == "1",
           ModelCacheInventory.activeParakeetModelDirectory() != nil {
            await appState.sttRouter.prefetchSelectedModelFilesForExistingInstall()
        }

        let fileManager = FileManager.default
        let homePath = environment["CFFIXED_USER_HOME"]
            ?? environment["HOME"]
            ?? fileManager.homeDirectoryForCurrentUser.path
        let appSupportURL = fileManager.transcriptedAppSupportDir
        let captureLibraryURL = fileManager.transcriptedCaptureLibraryDir
        let meetingsURL = fileManager.meetingSupportDir
        let dictationsURL = fileManager.dictationSupportDir
        let writingURL = fileManager.writingSupportDir
        let cacheURL = fileManager.transcriptedCacheDir
        let logsURL = fileManager.transcriptedLogsDir
        let temporaryURL = fileManager.transcriptedTemporaryDir
        let manifestURL = fileManager.transcriptedMCPDirectoriesManifestURL
        let helperReport = await runFirstRunReliabilityHelperAction(environment: environment)
        let syntheticModel = syntheticModelReport(
            rawState: environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_SYNTHETIC_MODEL_STATE"]
        )

        let menuReport = menuPanelController.launchUISmokeReport(
            statusItemExists: statusItem != nil,
            popoverConfigured: popover != nil,
            onboardingCompleted: PermissionsOnboardingPreferences.hasCompleted(),
            launchToInteractiveMs: Self.processStartToNowMilliseconds()
        )
        let report = FirstRunReliabilitySmokeReport(
            appLaunched: true,
            statusItemExists: statusItem != nil,
            popoverConfigured: popover != nil,
            permissionsOnboardingCompleted: PermissionsOnboardingPreferences.hasCompleted(),
            selectedModel: appState.sttRouter.selectedModel.rawValue,
            actualModelState: appState.sttRouter.modelDownloadState.diagnosticName,
            cachedModelDirectory: ModelCacheInventory.activeParakeetModelDirectory()?.path,
            launchToInteractiveMs: Self.processStartToNowMilliseconds(),
            menuContent: menuReport.content,
            runtime: FirstRunReliabilityRuntimeState(
                homePath: homePath,
                containerPath: environment["TRANSCRIPTED_CONTAINER_DIR"],
                appSupportPath: appSupportURL.path,
                captureLibraryPath: captureLibraryURL.path,
                meetingsPath: meetingsURL.path,
                dictationsPath: dictationsURL.path,
                writingPath: writingURL.path,
                cachePath: cacheURL.path,
                logsPath: logsURL.path,
                temporaryPath: temporaryURL.path,
                mcpManifestPath: manifestURL.path,
                mcpManifestExists: fileManager.fileExists(atPath: manifestURL.path),
                systemAudioPermissionKnown: TranscriptedPermissionAccess.systemAudioRecordingStatus() != .unknown,
                systemAudioPermissionGranted: TranscriptedPermissionAccess.systemAudioRecordingGranted(),
                appSupportWritable: firstRunReliabilityCanWrite(to: appSupportURL),
                captureLibraryWritable: firstRunReliabilityCanWrite(to: captureLibraryURL),
                cacheWritable: firstRunReliabilityCanWrite(to: cacheURL)
            ),
            helper: helperReport,
            syntheticModel: syntheticModel
        )
        let reportURL = URL(fileURLWithPath: reportPath, isDirectory: false)

        do {
            try fileManager.createDirectory(
                at: reportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch {
            NSLog("Failed to write first-run reliability report: \(error.localizedDescription)")
        }
    }

    /// Wall-clock milliseconds from the kernel's process-start time to now.
    /// Measured from `kinfo_proc.p_starttime` so it captures the true
    /// launch-to-interactive latency including pre-`main` dyld/runtime setup,
    /// not just the time since the app delegate began running. Returns nil if
    /// the syscall fails or the clock reads backwards. CI-smoke only.
    private static func processStartToNowMilliseconds() -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let status = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, UInt32(buffer.count), &info, &size, nil, 0)
        }
        guard status == 0 else { return nil }

        var now = timeval()
        guard gettimeofday(&now, nil) == 0 else { return nil }

        let start = info.kp_proc.p_starttime
        let startMs = Double(start.tv_sec) * 1000.0 + Double(start.tv_usec) / 1000.0
        let nowMs = Double(now.tv_sec) * 1000.0 + Double(now.tv_usec) / 1000.0
        let elapsed = nowMs - startMs
        return elapsed >= 0 ? elapsed : nil
    }

    private func scheduleLaunchUISmokeTerminationIfRequested(environment: [String: String]) {
        guard environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_TERMINATE_AFTER_REPORT"] == "1" else { return }

        let delay = environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_TERMINATE_DELAY_SECONDS"]
            .flatMap(Double.init)
            .map { max(0, $0) } ?? 5

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Darwin.exit(0)
        }
    }

    private func scheduleFirstRunReliabilityTerminationIfRequested(environment: [String: String]) {
        guard environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_TERMINATE_AFTER_REPORT"] == "1" else { return }

        let delay = environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_TERMINATE_DELAY_SECONDS"]
            .flatMap(Double.init)
            .map { max(0, $0) } ?? 0.1

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Darwin.exit(0)
        }
    }

    private func firstRunReliabilityCanWrite(to directoryURL: URL) -> Bool {
        let probeURL = directoryURL.appendingPathComponent(".first-run-smoke-\(UUID().uuidString)", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data().write(to: probeURL, options: [.atomic])
            try FileManager.default.removeItem(at: probeURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: probeURL)
            return false
        }
    }

    private func runFirstRunReliabilityHelperAction(
        environment: [String: String]
    ) async -> FirstRunReliabilityHelperReport {
        let action = FirstRunReliabilitySmokeAction(
            rawValue: environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTION"] ?? FirstRunReliabilitySmokeAction.reportOnly.rawValue
        ) ?? .reportOnly

        return await Task.detached(priority: .utility) {
            let before = ClaudeDesktopIntegrationInstaller.currentStatus()
            let bundledPath = before.bundledBinaryURL?.path
            let stateName: (ClaudeDesktopIntegrationStatus.State) -> String = { state in
                switch state {
                case .notInstalled:
                    return "notInstalled"
                case .installed:
                    return "installed"
                case .needsRepair:
                    return "needsRepair"
                }
            }
            var backupPath: String?
            var refreshed: Bool?
            var selfTest: TranscriptedMCPSelfTest?
            var errorMessage: String?

            do {
                switch action {
                case .reportOnly:
                    break
                case .installHelper:
                    let result = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop()
                    backupPath = result.backupURL?.path
                    selfTest = result.selfTest
                case .refreshHelper:
                    refreshed = try ClaudeDesktopIntegrationInstaller.refreshInstalledHelperIfNeeded()
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            let after = ClaudeDesktopIntegrationInstaller.currentStatus()
            return FirstRunReliabilityHelperReport(
                action: action.rawValue,
                backupPath: backupPath,
                bundledBinaryExists: after.bundledBinaryExists,
                bundledBinaryPath: bundledPath,
                configuredCommandPathAfter: after.configuredCommandPath,
                configuredCommandPathBefore: before.configuredCommandPath,
                configIsReadableAfter: after.configIsReadable,
                configIsReadableBefore: before.configIsReadable,
                configPath: after.configURL.path,
                error: errorMessage,
                installedBinaryExistsAfter: after.installedBinaryExists,
                installedBinaryExistsBefore: before.installedBinaryExists,
                installedBinaryMatchesBundledAfter: after.installedBinaryMatchesBundled,
                installedBinaryMatchesBundledBefore: before.installedBinaryMatchesBundled,
                installedBinaryPath: after.installedBinaryURL.path,
                refreshed: refreshed,
                selfTestDictationFileCount: selfTest?.dictationFileCount,
                selfTestMeetingFileCount: selfTest?.meetingFileCount,
                selfTestOK: selfTest?.ok,
                stateAfter: stateName(after.state),
                stateBefore: stateName(before.state)
            )
        }.value
    }

    private func syntheticModelReport(
        rawState: String?
    ) -> FirstRunReliabilitySyntheticModelReport? {
        guard let rawState,
              let state = parseSyntheticModelState(rawState) else {
            return nil
        }

        let action = FirstRunExperience.dictationAction(for: state)
        let card = FirstRunExperience.modelCard(for: state)
        let tone: String
        switch card.tone {
        case .ready:
            tone = "ready"
        case .working:
            tone = "working"
        case .failed:
            tone = "failed"
        }
        return FirstRunReliabilitySyntheticModelReport(
            requestedState: rawState,
            action: FirstRunReliabilitySyntheticAction(
                isEnabled: action.isEnabled,
                subtitle: action.subtitle,
                symbolName: action.symbolName,
                title: action.title
            ),
            card: FirstRunReliabilitySyntheticCard(
                detail: card.detail,
                progress: card.progress,
                status: card.status,
                title: card.title,
                tone: tone
            )
        )
    }

    private func parseSyntheticModelState(_ rawValue: String) -> ParakeetModelState? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "not-loaded" {
            return .notLoaded
        }
        if trimmed == "cached" {
            return .cached
        }
        if trimmed == "loading" {
            return .loading
        }
        if trimmed == "ready" {
            return .ready
        }
        if trimmed.hasPrefix("downloading:") {
            let progressValue = String(trimmed.dropFirst("downloading:".count))
            guard let progress = Double(progressValue) else { return nil }
            return .downloading(progress: progress)
        }
        if trimmed.hasPrefix("failed") {
            let message: String
            if let separator = trimmed.firstIndex(of: ":") {
                message = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                message = "Synthetic failure"
            }
            return .failed(message)
        }
        return nil
    }
}
