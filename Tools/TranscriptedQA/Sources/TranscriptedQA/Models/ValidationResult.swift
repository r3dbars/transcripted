import Foundation

enum ValidationStatus: String, Codable, Equatable {
    case pass = "PASS"
    case fail = "FAIL"
    case warn = "WARN"
}

enum ValidationScope: String, Codable, Equatable {
    case localData = "local_data"
    case sharedContract = "shared_contract"
    case runtimeHealth = "runtime_health"
    case mixed = "mixed"
}

struct ValidationContext: Codable, Equatable {
    let command: String?
    let generatedAt: String
    let meetingsDir: String?
    let stateDir: String?
    let logPath: String?
}

struct ValidationResult: Codable, Equatable {
    let check: String
    let status: ValidationStatus
    let target: String
    let detail: String?

    init(check: String, status: ValidationStatus, target: String, detail: String? = nil) {
        self.check = check
        self.status = status
        self.target = target
        self.detail = detail
    }

    static func pass(_ check: String, target: String) -> ValidationResult {
        ValidationResult(check: check, status: .pass, target: target)
    }

    static func fail(_ check: String, target: String, detail: String) -> ValidationResult {
        ValidationResult(check: check, status: .fail, target: target, detail: detail)
    }

    static func warn(_ check: String, target: String, detail: String) -> ValidationResult {
        ValidationResult(check: check, status: .warn, target: target, detail: detail)
    }

    var textLine: String {
        let statusStr = status.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)
        let checkStr = check.padding(toLength: 36, withPad: " ", startingAt: 0)
        if let detail = detail {
            return "\(statusStr)  \(checkStr)  \(target)  \(detail)"
        }
        return "\(statusStr)  \(checkStr)  \(target)"
    }

    var resultKey: String {
        "\(check)|\(target)|\(detail ?? "")"
    }
}

struct ValidationFingerprint: Codable, Equatable {
    let id: String
    let summary: String
    let scope: ValidationScope
    let repoFixCandidate: Bool
    let targets: [String]
    let checks: [String]
    let occurrenceCount: Int
    let suggestedNextStep: String
}

struct ValidationAutomationSummary: Codable, Equatable {
    enum OverallStatus: String, Codable, Equatable {
        case green = "green"
        case warningsOnly = "warnings_only"
        case localDataDrift = "local_data_drift"
        case repoFixCandidate = "repo_fix_candidate"
        case mixedFailures = "mixed_failures"
    }

    let overallStatus: OverallStatus
    let repoFixCandidate: Bool
    let suggestedNextStep: String
    let failureFingerprints: [ValidationFingerprint]
    let topFailures: [ValidationResult]
    let warningCount: Int

    init(results: [ValidationResult]) {
        let failedResults = results.filter { $0.status == .fail }
        let warningResults = results.filter { $0.status == .warn }
        let failureFingerprints = ValidationFingerprintBuilder(results: results).build()

        self.failureFingerprints = failureFingerprints
        self.topFailures = Array(failedResults.prefix(10))
        self.warningCount = warningResults.count

        if failedResults.isEmpty {
            if warningResults.isEmpty {
                overallStatus = .green
                repoFixCandidate = false
                suggestedNextStep = "No action needed. The artifact sweep is green."
            } else {
                overallStatus = .warningsOnly
                repoFixCandidate = false
                suggestedNextStep = "No blocking failures. Review warnings, but no repo repair is needed yet."
            }
            return
        }

        let hasRepoFixCandidate = failureFingerprints.contains { $0.repoFixCandidate }
        let allLocalData = !failureFingerprints.isEmpty && failureFingerprints.allSatisfy { $0.scope == .localData }

        if allLocalData {
            overallStatus = .localDataDrift
            repoFixCandidate = false
            suggestedNextStep = failureFingerprints.first?.suggestedNextStep
                ?? "Clean up or quarantine the stale local artifacts before changing repo code."
        } else if hasRepoFixCandidate {
            overallStatus = .repoFixCandidate
            repoFixCandidate = true
            suggestedNextStep = failureFingerprints.first(where: { $0.repoFixCandidate })?.suggestedNextStep
                ?? "Reproduce the failure on clean fixtures or recent output before patching repo code."
        } else {
            overallStatus = .mixedFailures
            repoFixCandidate = false
            suggestedNextStep = "Triage the failure fingerprints one by one. Do not patch repo code until the failure is reproduced outside the current local library."
        }
    }
}

struct ValidationReport: Codable, Equatable {
    let context: ValidationContext?
    let results: [ValidationResult]
    let summary: Summary
    let automation: ValidationAutomationSummary

    struct Summary: Codable, Equatable {
        let passed: Int
        let failed: Int
        let warnings: Int
    }

    init(results: [ValidationResult], context: ValidationContext? = nil) {
        self.context = context
        self.results = results
        self.summary = Summary(
            passed: results.filter { $0.status == .pass }.count,
            failed: results.filter { $0.status == .fail }.count,
            warnings: results.filter { $0.status == .warn }.count
        )
        self.automation = ValidationAutomationSummary(results: results)
    }

    var exitCode: Int32 {
        summary.failed > 0 ? 1 : 0
    }

    func printText() {
        for result in results {
            print(result.textLine)
        }
        print("\nSummary: \(summary.passed) passed, \(summary.failed) failed, \(summary.warnings) warnings")
        if summary.failed > 0 || summary.warnings > 0 {
            print("Automation: \(automation.overallStatus.rawValue)")
            if !automation.failureFingerprints.isEmpty {
                print("Fingerprints:")
                for fingerprint in automation.failureFingerprints.prefix(5) {
                    print("- \(fingerprint.id): \(fingerprint.summary)")
                }
            }
            print("Next step: \(automation.suggestedNextStep)")
        }
    }

    func printJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(self)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            } else {
                FileHandle.standardError.write(Data("Error: Failed to encode JSON report as UTF-8\n".utf8))
                Foundation.exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("Error: Failed to encode JSON report: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}

private struct ValidationFingerprintBuilder {
    let results: [ValidationResult]

    func build() -> [ValidationFingerprint] {
        let failedResults = results.filter { $0.status == .fail }
        guard !failedResults.isEmpty else { return [] }

        var fingerprints: [ValidationFingerprint] = []
        var usedKeys = Set<String>()

        let emptyUtteranceResults = failedResults.filter { $0.check == "artifact/json-utterances-present" }
        let missingMarkdownResults = failedResults.filter { $0.check == "artifact/md-match" }
        let staleIndexResults = failedResults.filter { $0.check == "index/markdown-on-disk" }

        let emptyUtteranceBases = Dictionary(uniqueKeysWithValues: emptyUtteranceResults.compactMap { result in
            baseNameFromJSONTarget(result.target).map { ($0, result) }
        })
        let missingMarkdownBases = Dictionary(uniqueKeysWithValues: missingMarkdownResults.compactMap { result in
            baseNameFromJSONTarget(result.target).map { ($0, result) }
        })
        let staleIndexBases = Dictionary(uniqueKeysWithValues: staleIndexResults.compactMap { result in
            missingMarkdownBaseName(from: result.detail).map { ($0, result) }
        })

        let fullDriftBases = Set(emptyUtteranceBases.keys)
            .intersection(missingMarkdownBases.keys)
            .intersection(staleIndexBases.keys)
            .sorted()

        for base in fullDriftBases {
            guard let emptyResult = emptyUtteranceBases[base],
                  let missingResult = missingMarkdownBases[base],
                  let indexResult = staleIndexBases[base] else { continue }

            let matched = [emptyResult, missingResult, indexResult]
            markUsed(matched, usedKeys: &usedKeys)
            fingerprints.append(
                ValidationFingerprint(
                    id: "stale_legacy_sidecar_missing_markdown_index_drift/\(sanitizeFingerprintComponent(base))",
                    summary: "\(base) has an empty legacy JSON sidecar, no matching Markdown file, and a stale transcripted.json entry.",
                    scope: .localData,
                    repoFixCandidate: false,
                    targets: uniqueSortedStrings(["\(base).json", "transcripted.json"]),
                    checks: uniqueSortedStrings(matched.map(\.check)),
                    occurrenceCount: matched.count,
                    suggestedNextStep: "Quarantine or delete the stale \(base).json sidecar and remove the dead transcripted.json entry for \(base) before changing repo code."
                )
            )
        }

        for result in staleIndexResults where !usedKeys.contains(result.resultKey) {
            let base = missingMarkdownBaseName(from: result.detail) ?? result.target
            markUsed([result], usedKeys: &usedKeys)
            fingerprints.append(
                ValidationFingerprint(
                    id: "stale_index_missing_markdown/\(sanitizeFingerprintComponent(base))",
                    summary: "transcripted.json still points at \(base).md, but that Markdown file is missing on disk.",
                    scope: .localData,
                    repoFixCandidate: false,
                    targets: [result.target],
                    checks: [result.check],
                    occurrenceCount: 1,
                    suggestedNextStep: "Remove or repair the stale transcripted.json entry for \(base) instead of patching the repo first."
                )
            )
        }

        for result in missingMarkdownResults where !usedKeys.contains(result.resultKey) {
            let base = baseNameFromJSONTarget(result.target) ?? result.target
            markUsed([result], usedKeys: &usedKeys)
            fingerprints.append(
                ValidationFingerprint(
                    id: "orphaned_json_sidecar_missing_markdown/\(sanitizeFingerprintComponent(base))",
                    summary: "\(result.target) has no matching Markdown transcript.",
                    scope: .localData,
                    repoFixCandidate: false,
                    targets: [result.target],
                    checks: [result.check],
                    occurrenceCount: 1,
                    suggestedNextStep: "Inspect whether \(result.target) should be restored, quarantined, or deleted from the local capture library."
                )
            )
        }

        for result in emptyUtteranceResults where !usedKeys.contains(result.resultKey) {
            let base = baseNameFromJSONTarget(result.target) ?? result.target
            markUsed([result], usedKeys: &usedKeys)
            fingerprints.append(
                ValidationFingerprint(
                    id: "empty_json_sidecar_utterances/\(sanitizeFingerprintComponent(base))",
                    summary: "\(result.target) has no utterances, so agents would read an empty legacy transcript artifact.",
                    scope: .localData,
                    repoFixCandidate: false,
                    targets: [result.target],
                    checks: [result.check],
                    occurrenceCount: 1,
                    suggestedNextStep: "Treat \(result.target) as stale or corrupt local data unless the same empty artifact is reproduced from fresh output."
                )
            )
        }

        let remainingFailures = failedResults.filter { !usedKeys.contains($0.resultKey) }
        let groupedFailures = Dictionary(grouping: remainingFailures, by: categoryKey(for:))

        for key in groupedFailures.keys.sorted() {
            guard let group = groupedFailures[key] else { continue }
            let category = fingerprintCategory(for: key, results: group)
            fingerprints.append(
                ValidationFingerprint(
                    id: category.id,
                    summary: category.summary,
                    scope: category.scope,
                    repoFixCandidate: category.repoFixCandidate,
                    targets: uniqueSortedStrings(group.map(\.target)),
                    checks: uniqueSortedStrings(group.map(\.check)),
                    occurrenceCount: group.count,
                    suggestedNextStep: category.suggestedNextStep
                )
            )
        }

        return fingerprints.sorted { lhs, rhs in
            if lhs.repoFixCandidate != rhs.repoFixCandidate {
                return lhs.repoFixCandidate && !rhs.repoFixCandidate
            }
            return lhs.id < rhs.id
        }
    }

    private func categoryKey(for result: ValidationResult) -> String {
        if result.check.hasPrefix("database/") {
            return "database"
        }
        if result.check.hasPrefix("logs/") {
            return "logs"
        }
        if result.check == "transcript/body-has-sections" {
            return "transcript-body"
        }
        if result.check.hasPrefix("transcript/yaml-") || result.check == "transcript/permissions" {
            return "transcript-yaml"
        }
        if result.check.hasPrefix("artifact/json-") {
            return "artifact-json-schema"
        }
        if result.check.hasPrefix("index/") {
            return "index-structure"
        }
        if result.check.hasPrefix("health/") {
            return "health"
        }
        return "generic/\(sanitizeFingerprintComponent(result.check))"
    }

    private func fingerprintCategory(for key: String, results: [ValidationResult]) -> (id: String, summary: String, scope: ValidationScope, repoFixCandidate: Bool, suggestedNextStep: String) {
        switch key {
        case "database":
            return (
                "database_integrity_failure",
                "One or more Transcripted state databases failed integrity or schema validation.",
                .localData,
                false,
                "Inspect the affected SQLite files locally first. Treat this as local data corruption unless the same failure reproduces on fresh fixtures."
            )
        case "logs":
            return (
                "log_file_validation_failure",
                "The local app.jsonl log failed validation.",
                .localData,
                false,
                "Inspect or rotate the local log file before changing repo code. Only patch logging if the corruption reproduces from fresh app output."
            )
        case "transcript-body":
            return (
                "truncated_or_malformed_transcript_markdown",
                "One or more Markdown transcripts are missing the expected body sections.",
                .sharedContract,
                true,
                "Check whether current Transcripted output can still produce this malformed Markdown. If yes, patch the writer and add a regression test."
            )
        case "transcript-yaml":
            return (
                "invalid_transcript_frontmatter_contract",
                "One or more Markdown transcripts failed the expected YAML/frontmatter contract.",
                .sharedContract,
                true,
                "Reproduce the frontmatter failure on fresh output or fixtures. If it reproduces, patch the writer or validator and add coverage."
            )
        case "artifact-json-schema":
            return (
                "legacy_json_sidecar_schema_contract_failure",
                "One or more legacy JSON sidecars failed the expected schema contract.",
                .sharedContract,
                true,
                "Confirm whether fresh Transcripted output still writes this bad JSON shape. If it does, patch the writer or validator and add a regression test."
            )
        case "index-structure":
            return (
                "legacy_index_structure_failure",
                "transcripted.json failed a structural contract check beyond simple missing-file drift.",
                .sharedContract,
                true,
                "Reproduce the index failure on fixtures or fresh output before patching path or index-writing code."
            )
        case "health":
            return (
                "runtime_health_or_path_failure",
                "The QA run found a path or runtime health problem before artifact validation was fully trustworthy.",
                .runtimeHealth,
                false,
                "Repair the local paths, permissions, or runtime environment first, then rerun the artifact sweep."
            )
        default:
            return (
                "validation_failure/\(sanitizeFingerprintComponent(key))",
                "Validation failed for \(results.first?.check ?? key).",
                .mixed,
                false,
                "Review the failing check in detail and reproduce it on clean fixtures before broadening the fix."
            )
        }
    }

    private func markUsed(_ results: [ValidationResult], usedKeys: inout Set<String>) {
        for result in results {
            usedKeys.insert(result.resultKey)
        }
    }

    private func uniqueSortedStrings(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private func baseNameFromJSONTarget(_ target: String) -> String? {
        guard target.hasSuffix(".json") else { return nil }
        return URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
    }

    private func missingMarkdownBaseName(from detail: String?) -> String? {
        guard let detail else { return nil }
        let marker = ".md not found"
        guard let range = detail.range(of: marker) else { return nil }
        return String(detail[..<range.lowerBound])
    }

    private func sanitizeFingerprintComponent(_ value: String) -> String {
        let sanitized = value.replacingOccurrences(
            of: #"[^A-Za-z0-9_-]+"#,
            with: "_",
            options: .regularExpression
        )
        return sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
