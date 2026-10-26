// Security contracts: manifest checks and the nightly checker's behavior.
// The suites parsing config/security/nightly-security-manifest.json are real data
// contracts (they decode and validate manifest values). The checker's own
// behavior (built-app entitlements per channel, version drift, release-health
// gates, PostHog schema, Sentry lookups, forbidden entitlements) is tested by
// scripts/ops/test-nightly-security-check.py on synthetic fixtures; the first
// suite runs it. No real signing, keychain access, network, or hardware.
// The one suite that still reads text checks that docs and the agent preflight
// point at the checker: that promise is about the words in those files.

import Foundation

func testNightlySecurityContract() {
    runSuite("The nightly security checker passes its offline behavior tests") {
        let result = runRepoPythonScript("scripts/ops/test-nightly-security-check.py", arguments: [])
        assertEqual(result.status, 0, "the checker's synthetic-fixture tests should pass: \(result.output)")
    }

    runSuite("Nightly security manifest is parseable and weights sum to 100") {
        let manifest = loadJSONFixture("config/security/nightly-security-manifest.json", as: [String: AnyDecodable].self)
        let weights = manifest["scoring"]?.dictionaryValue?["weights"]?.dictionaryValue ?? [:]
        let totalWeight = weights.values.compactMap(\.intValue).reduce(0, +)

        assertEqual(totalWeight, 100, "nightly scoring weights should add up to 100")
        assertNotNil(manifest["paths"]?.dictionaryValue?["sanitizer_corpus"]?.stringValue, "manifest should point at the shared sanitizer corpus")
        assertEqual(
            manifest["paths"]?.dictionaryValue?["privacy_leak_sweep"]?.stringValue,
            "scripts/ops/privacy-leak-sweep.py",
            "manifest should point at the synthetic privacy leak sweep"
        )
        assertNotNil(manifest["expected_info_plist"]?.dictionaryValue?["SUFeedURL"]?.stringValue, "manifest should pin the Sparkle feed URL")
        assertEqual(
            manifest["expected_info_plist"]?.dictionaryValue?["TranscriptedSentryReleasePrefix"]?.stringValue,
            "transcripted",
            "manifest should pin the Sentry release prefix"
        )
    }

    runSuite("Nightly security manifest covers release-health automation surfaces") {
        let manifest = loadJSONFixture("config/security/nightly-security-manifest.json", as: [String: AnyDecodable].self)
        let paths = manifest["paths"]?.dictionaryValue ?? [:]
        let liveSurfaces = manifest["live_release_surfaces"]?.dictionaryValue ?? [:]
        let directRoutes = liveSurfaces["direct_download_routes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let disallowedKeys = Set(manifest["disallowed_observability_payload_keys"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let firstValueEvents = Set(manifest["required_posthog_first_value_events"]?.arrayValue?.compactMap(\.stringValue) ?? [])

        assertEqual(paths["homebrew_cask"]?.stringValue, "Casks/transcripted.rb", "release-health gate should check Homebrew cask parity")
        let analyticsPolicyPath = paths["analytics_event_policy"]?.stringValue ?? ""
        assertTrue(
            analyticsPolicyPath.hasSuffix("/AnalyticsEventPolicy.swift")
                && FileManager.default.fileExists(atPath: repoFixtureURL(analyticsPolicyPath).path),
            "release-health gate should point at an analytics policy file that exists, so the PostHog schema check has something to parse"
        )
        assertEqual(paths["health_probe"]?.stringValue, "scripts/ops/health-probe.sh", "release-health gate should keep PostHog probe schema pinned")
        assertEqual(paths["release_debug_files"]?.stringValue, "build/Transcripted.app.dSYM", "release-health gate should know the release dSYM location")
        assertEqual(liveSurfaces["appcast"]?.stringValue, "https://transcripted.app/appcast.xml", "live appcast should be part of the release-health gate")
        assertTrue(directRoutes.contains("https://transcripted.app/download/latest.dmg/"), "trailing-slash direct download route should stay checked")
        assertTrue(disallowedKeys.contains("transcript_text"), "raw transcript payload keys should stay denied")
        assertTrue(disallowedKeys.contains("audio_path"), "raw audio path payload keys should stay denied")
        assertTrue(firstValueEvents.contains("activation_agent_prompt_action_clicked"), "agent payoff events should stay in the PostHog first-value schema")
    }

    runSuite("Nightly security manifest preserves calendar access entitlement") {
        let manifest = loadJSONFixture("config/security/nightly-security-manifest.json", as: [String: AnyDecodable].self)
        let expectedEntitlements = manifest["expected_entitlements"]?.dictionaryValue ?? [:]
        let calendarEntitlement = "com.apple.security.personal-information.calendars"
        let localEntitlements = loadPlistDictionary("config/entitlements/local.plist")
        let betaEntitlements = loadPlistDictionary("config/entitlements/beta.plist")

        assertEqual(
            expectedEntitlements["local"]?.dictionaryValue?[calendarEntitlement]?.boolValue,
            true,
            "local builds should be signed with the Calendar entitlement so EventKit can show the permission prompt"
        )
        assertEqual(
            expectedEntitlements["beta"]?.dictionaryValue?[calendarEntitlement]?.boolValue,
            true,
            "beta builds should be signed with the Calendar entitlement so shipped apps appear in Calendar privacy settings"
        )
        assertEqual(
            localEntitlements[calendarEntitlement] as? Bool,
            true,
            "local entitlement plist should keep Calendar personal-information access enabled"
        )
        assertEqual(
            betaEntitlements[calendarEntitlement] as? Bool,
            true,
            "beta entitlement plist should keep Calendar personal-information access enabled"
        )
    }

    runSuite("Nightly security manifest forbids broad OS entitlements") {
        let manifest = loadJSONFixture("config/security/nightly-security-manifest.json", as: [String: AnyDecodable].self)
        let forbidden = Set(manifest["forbidden_entitlements"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let localEntitlements = Set(loadPlistDictionary("config/entitlements/local.plist").keys)
        let betaEntitlements = Set(loadPlistDictionary("config/entitlements/beta.plist").keys)
        // The checker rejecting these in the committed plists and in a built
        // app is tested in scripts/ops/test-nightly-security-check.py
        // (CommittedEntitlementTests, BuiltAppEntitlementTests).

        assertTrue(
            forbidden.contains("com.apple.security.files.user-selected.read-write"),
            "privacy contract should explicitly forbid broad user-selected file write access"
        )
        assertTrue(
            forbidden.contains("com.apple.security.automation.apple-events"),
            "privacy contract should explicitly forbid broad Apple Events automation"
        )
        assertTrue(
            forbidden.contains("com.apple.security.network.server"),
            "privacy contract should explicitly forbid listening network-server entitlement"
        )
        assertTrue(
            localEntitlements.isDisjoint(with: forbidden),
            "local entitlements should not include forbidden broad OS permissions"
        )
        assertTrue(
            betaEntitlements.isDisjoint(with: forbidden),
            "beta entitlements should not include forbidden broad OS permissions"
        )
    }

    runSuite("Nightly security sanitizer corpus stays shared and non-empty") {
        let manifest = loadJSONFixture("config/security/nightly-security-manifest.json", as: [String: AnyDecodable].self)
        let secretScan = manifest["secret_scan"]?.dictionaryValue ?? [:]
        let trackedAllowlist = Set(secretScan["tracked_file_allowlist_globs"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let historyAllowlist = Set(secretScan["history_file_allowlist_globs"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let corpus = loadJSONFixture("Tests/Fixtures/ObservabilitySanitizerCorpus.json", as: ObservabilitySanitizerCorpus.self)
        let ids = corpus.cases.map(\.id)
        let privacyParityCorpus = "Tests/Fixtures/PrivacyTextRedactorParityCorpus.json"

        assertTrue(corpus.cases.count >= 5, "shared sanitizer corpus should cover several privacy cases")
        assertEqual(Set(ids).count, ids.count, "shared sanitizer corpus ids should be unique")
        assertTrue(corpus.cases.allSatisfy { !$0.mustContain.isEmpty && !$0.mustNotContain.isEmpty }, "each sanitizer corpus case should define required and forbidden markers")
        assertTrue(
            trackedAllowlist.contains(privacyParityCorpus),
            "the exact synthetic privacy parity corpus should be allowlisted from tracked secret scanning"
        )
        assertTrue(
            historyAllowlist.contains(privacyParityCorpus),
            "the exact synthetic privacy parity corpus should be allowlisted from history secret scanning"
        )
    }

    // Text on purpose: the promise is that these docs and the agent preflight
    // name the checker, which only the words in those files can show.
    runSuite("Nightly security docs and the agent preflight point at the deterministic checker") {
        let scriptsReadme = (try? String(contentsOf: repoFixtureURL("scripts/README.md"), encoding: .utf8)) ?? ""
        let privacyDoc = (try? String(contentsOf: repoFixtureURL("docs/privacy-first-observability.md"), encoding: .utf8)) ?? ""
        let releaseDoc = (try? String(contentsOf: repoFixtureURL("docs/release-packaging.md"), encoding: .utf8)) ?? ""
        let preflight = (try? String(contentsOf: repoFixtureURL("scripts/dev/agent-preflight.sh"), encoding: .utf8)) ?? ""

        assertTrue(scriptsReadme.contains("nightly-security-check.py"), "scripts README should mention the nightly security checker")
        assertTrue(scriptsReadme.contains("--strict --live-release-surfaces"), "scripts README should show the live release-health gate")
        assertTrue(scriptsReadme.contains("privacy-leak-sweep.py"), "scripts README should mention the synthetic privacy leak sweep")
        assertTrue(privacyDoc.contains("nightly-security-check.py"), "privacy observability doc should mention the nightly security checker")
        assertTrue(privacyDoc.contains("privacy-leak-sweep.py"), "privacy observability doc should mention the synthetic privacy leak sweep")
        assertTrue(releaseDoc.contains("--strict --live-release-surfaces"), "release packaging docs should point release agents at the strict live-surface gate")
        assertTrue(releaseDoc.contains("privacy-leak-sweep.py"), "release docs should route release-note privacy checks through the synthetic sweep")
        assertTrue(
            preflight.contains("python3 scripts/dev/test-matrix-checks.py --matrix .agents/test-matrix.yml"),
            "agent preflight should execute the matrix that owns the strict checker command"
        )
    }

    runSuite("Editing the nightly checker or the privacy sweep routes to its gate") {
        let checkerRoute = runRepoPythonScript(
            "scripts/dev/test-matrix-checks.py",
            arguments: ["--matrix", ".agents/test-matrix.yml", "scripts/ops/nightly-security-check.py"]
        )
        assertEqual(checkerRoute.status, 0, "the matrix should select checks for the nightly checker: \(checkerRoute.output)")
        let strictCommand = checkerRoute.output
            .split(separator: "\n")
            .map(String.init)
            .first { $0.contains("scripts/ops/nightly-security-check.py") && $0.contains("--strict") }
        assertNotNil(strictCommand, "editing the nightly checker should suggest its strict gate")
        let arguments = strictCommand?.split(separator: " ").map(String.init) ?? []
        let releaseFixture = arguments.firstIndex(of: "--github-release-json").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        assertNotNil(releaseFixture, "the strict gate should run with deterministic GitHub release metadata")
        if let releaseFixture {
            assertTrue(
                FileManager.default.fileExists(atPath: repoFixtureURL(releaseFixture).path),
                "the strict gate's GitHub release fixture \(releaseFixture) should exist"
            )
        }

        let sweepRoute = runRepoPythonScript(
            "scripts/dev/test-matrix-checks.py",
            arguments: ["--matrix", ".agents/test-matrix.yml", "scripts/ops/privacy-leak-sweep.py"]
        )
        assertTrue(
            sweepRoute.output.split(separator: "\n").contains { $0.hasPrefix("python3 scripts/ops/privacy-leak-sweep.py") },
            "editing the privacy leak sweep should suggest running it: \(sweepRoute.output)"
        )
    }

    runSuite("Nightly security checker fails stale GitHub release asset metadata") {
        let passing = runRepoPythonScript("scripts/ops/nightly-security-check.py", arguments: [
            "--strict",
            "--automation-toml", "Tests/Fixtures/nightly-security-automation.toml",
            "--github-release-json", "Tests/Fixtures/release-health-github-release-1.1.73.json"
        ])
        let staleCask = runRepoPythonScript("scripts/ops/nightly-security-check.py", arguments: [
            "--strict",
            "--automation-toml", "Tests/Fixtures/nightly-security-automation.toml",
            "--github-release-json", "Tests/Fixtures/release-health-github-release-stale-cask.json"
        ])

        assertEqual(passing.status, 0, "matching release fixture should keep the strict checker green")
        assertEqual(staleCask.status, 1, "stale GitHub asset checksum fixture should fail the strict checker")
        assertTrue(staleCask.output.contains("github-release-asset-digest"), "stale fixture should fail on cask vs GitHub asset digest drift")
    }
}

private func loadPlistDictionary(_ relativePath: String) -> [String: Any] {
    let url = repoFixtureURL(relativePath)
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dictionary = plist as? [String: Any]
    else {
        return [:]
    }

    return dictionary
}

private struct ShellResult {
    let status: Int32
    let output: String
}

private func runRepoPythonScript(_ script: String, arguments: [String]) -> ShellResult {
    let process = Process()
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("nightly-security-contract-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
        return ShellResult(status: -127, output: "Unable to create checker output file")
    }
    defer {
        try? FileManager.default.removeItem(at: outputURL)
    }

    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", script] + arguments
    process.currentDirectoryURL = repoFixtureURL(".")
    process.standardOutput = outputHandle
    process.standardError = outputHandle

    do {
        try process.run()
        process.waitUntilExit()
        try? outputHandle.close()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return ShellResult(status: process.terminationStatus, output: output)
    } catch {
        try? outputHandle.close()
        return ShellResult(status: -127, output: String(describing: error))
    }
}

struct AnyDecodable: Decodable {
    let stringValue: String?
    let intValue: Int?
    let boolValue: Bool?
    let dictionaryValue: [String: AnyDecodable]?
    let arrayValue: [AnyDecodable]?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string
            intValue = nil
            boolValue = nil
            dictionaryValue = nil
            arrayValue = nil
        } else if let int = try? container.decode(Int.self) {
            stringValue = nil
            intValue = int
            boolValue = nil
            dictionaryValue = nil
            arrayValue = nil
        } else if let bool = try? container.decode(Bool.self) {
            stringValue = nil
            intValue = nil
            boolValue = bool
            dictionaryValue = nil
            arrayValue = nil
        } else if let dictionary = try? container.decode([String: AnyDecodable].self) {
            stringValue = nil
            intValue = nil
            boolValue = nil
            dictionaryValue = dictionary
            arrayValue = nil
        } else if let array = try? container.decode([AnyDecodable].self) {
            stringValue = nil
            intValue = nil
            boolValue = nil
            dictionaryValue = nil
            arrayValue = array
        } else {
            stringValue = nil
            intValue = nil
            boolValue = nil
            dictionaryValue = nil
            arrayValue = nil
        }
    }
}
