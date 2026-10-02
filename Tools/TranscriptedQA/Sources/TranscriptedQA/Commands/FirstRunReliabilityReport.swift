import Foundation

struct FirstRunReliabilitySmokeReport: Codable, Equatable, ReportWritable {
    struct Summary: Codable, Equatable {
        let passed: Int
        let failed: Int
        let warnings: Int
    }

    let runID: String
    let generatedAt: String
    let appBundlePath: String
    let evidenceRootPath: String
    let reportPath: String?
    let scenarios: [FirstRunReliabilityScenario]

    var summary: Summary {
        Summary(
            passed: scenarios.filter { $0.status == .pass }.count,
            failed: scenarios.filter { $0.status == .fail }.count,
            warnings: scenarios.filter { $0.status == .warn }.count
        )
    }

    var status: ValidationStatus {
        if summary.failed > 0 { return .fail }
        if summary.warnings > 0 { return .warn }
        return .pass
    }

    var privacySweepPaths: [String] {
        scenarios
            .flatMap { $0.reportPaths + $0.logPaths }
            .sorted()
    }
}

struct FirstRunReliabilityScenario: Codable, Equatable {
    let id: String
    let status: ValidationStatus
    let detail: String
    let reportPaths: [String]
    let logPaths: [String]
    let isolatedHomePaths: [String]
    let containerPaths: [String]
    let launches: [FirstRunReliabilityAppReport]

    var primaryEvidencePath: String? {
        reportPaths.first ?? logPaths.first
    }
}

struct FirstRunReliabilityAppReport: Codable, Equatable {
    let appLaunched: Bool
    let statusItemExists: Bool
    let popoverConfigured: Bool
    let permissionsOnboardingCompleted: Bool
    let selectedModel: String
    let actualModelState: String
    let cachedModelDirectory: String?
    let launchToInteractiveMs: Double?
    let menuContent: FirstRunReliabilityMenuContentSnapshot
    let runtime: FirstRunReliabilityRuntimeState
    let helper: FirstRunReliabilityHelperState
    let syntheticModel: FirstRunReliabilitySyntheticModelState?
}

struct FirstRunReliabilityMenuContentSnapshot: Codable, Equatable {
    let header: FirstRunReliabilityMenuHeaderSnapshot
    let updateCallout: FirstRunReliabilityActionRowSnapshot
    let primaryActions: [String: FirstRunReliabilityActionRowSnapshot]
    let utilityActions: [String: FirstRunReliabilityActionRowSnapshot]
}

struct FirstRunReliabilityMenuHeaderSnapshot: Codable, Equatable {
    let statusText: String
    let detailText: String
    let warningText: String
    let isReady: Bool
}

struct FirstRunReliabilityActionRowSnapshot: Codable, Equatable {
    let title: String
    let detail: String
    let trailingText: String
    let automationIdentifier: String
    let isVisible: Bool
    let isEnabled: Bool
}

struct FirstRunReliabilityRuntimeState: Codable, Equatable {
    let homePath: String
    let containerPath: String?
    let appSupportPath: String
    let captureLibraryPath: String
    let meetingsPath: String
    let dictationsPath: String
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

struct FirstRunReliabilityHelperState: Codable, Equatable {
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

struct FirstRunReliabilitySyntheticModelState: Codable, Equatable {
    let requestedState: String
    let action: FirstRunReliabilitySyntheticActionState
    let card: FirstRunReliabilitySyntheticCardState
}

struct FirstRunReliabilitySyntheticActionState: Codable, Equatable {
    let isEnabled: Bool
    let subtitle: String
    let symbolName: String
    let title: String
}

struct FirstRunReliabilitySyntheticCardState: Codable, Equatable {
    let detail: String
    let progress: Double?
    let status: String
    let title: String
    let tone: String
}
