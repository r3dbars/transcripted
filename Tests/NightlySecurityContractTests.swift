import Foundation

func testNightlySecurityContract() {
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
        assertEqual(paths["analytics_event_policy"]?.stringValue, "Sources/Observability/AnalyticsEventPolicy.swift", "release-health gate should parse the analytics policy source")
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

    runSuite("Nightly security sanitizer corpus stays shared and non-empty") {
        let corpus = loadJSONFixture("Tests/Fixtures/ObservabilitySanitizerCorpus.json", as: ObservabilitySanitizerCorpus.self)
        let ids = corpus.cases.map(\.id)

        assertTrue(corpus.cases.count >= 5, "shared sanitizer corpus should cover several privacy cases")
        assertEqual(Set(ids).count, ids.count, "shared sanitizer corpus ids should be unique")
        assertTrue(corpus.cases.allSatisfy { !$0.mustContain.isEmpty && !$0.mustNotContain.isEmpty }, "each sanitizer corpus case should define required and forbidden markers")
    }

    runSuite("Nightly security docs reference the deterministic checker") {
        let scriptsReadme = (try? String(contentsOf: repoFixtureURL("scripts/README.md"), encoding: .utf8)) ?? ""
        let privacyDoc = (try? String(contentsOf: repoFixtureURL("docs/privacy-first-observability.md"), encoding: .utf8)) ?? ""
        let releaseDoc = (try? String(contentsOf: repoFixtureURL("docs/release-packaging.md"), encoding: .utf8)) ?? ""
        let testMatrix = (try? String(contentsOf: repoFixtureURL(".agents/test-matrix.yml"), encoding: .utf8)) ?? ""

        assertTrue(scriptsReadme.contains("nightly-security-check.py"), "scripts README should mention the nightly security checker")
        assertTrue(scriptsReadme.contains("--strict --live-release-surfaces"), "scripts README should show the live release-health gate")
        assertTrue(scriptsReadme.contains("privacy-leak-sweep.py"), "scripts README should mention the synthetic privacy leak sweep")
        assertTrue(privacyDoc.contains("nightly-security-check.py"), "privacy observability doc should mention the nightly security checker")
        assertTrue(privacyDoc.contains("privacy-leak-sweep.py"), "privacy observability doc should mention the synthetic privacy leak sweep")
        assertTrue(releaseDoc.contains("--strict --live-release-surfaces"), "release packaging docs should point release agents at the strict live-surface gate")
        assertTrue(releaseDoc.contains("privacy-leak-sweep.py"), "release docs should route release-note privacy checks through the synthetic sweep")
        assertTrue(testMatrix.contains("privacy-leak-sweep.py"), "test matrix should route edits to the privacy leak sweep checks")
    }

    runSuite("Nightly security checker exposes strict release-health flags") {
        let checker = (try? String(contentsOf: repoFixtureURL("scripts/ops/nightly-security-check.py"), encoding: .utf8)) ?? ""
        let preflight = (try? String(contentsOf: repoFixtureURL("scripts/dev/agent-preflight.sh"), encoding: .utf8)) ?? ""
        let matrix = (try? String(contentsOf: repoFixtureURL(".agents/test-matrix.yml"), encoding: .utf8)) ?? ""

        assertTrue(checker.contains("--strict"), "nightly checker should expose a failing gate mode")
        assertTrue(checker.contains("--live-release-surfaces"), "nightly checker should expose live release-surface checks")
        assertTrue(checker.contains("--github-release-json"), "nightly checker should accept deterministic GitHub release fixtures")
        assertTrue(checker.contains("live_appcast_urls"), "live release-surface checks should include the Sparkle feed used by installed apps")
        assertTrue(checker.contains("--sentry-release-health"), "nightly checker should expose Sentry release existence checks")
        assertTrue(checker.contains("--require-sentry-release-health"), "nightly checker should expose required Sentry release checks")
        assertTrue(checker.contains("--require-release-debug-files"), "nightly checker should expose release dSYM verification")
        assertTrue(checker.contains("has_required_release_health_failure"), "required release-health checks should fail even outside strict mode")
        assertTrue(checker.contains("has_blocking_release_health_watch_item"), "release-health checks should fail on stale appcast watch items")
        assertTrue(checker.contains("should_check_automation_prompt"), "release-health gates should not depend on local Codex automation state")
        assertFalse(checker.contains("SENTRY_AUTH_TOKEN is not configured"), "Sentry release checks should let configured sentry-cli auth attempt the lookup")
        assertTrue(checker.contains("check_cask"), "nightly checker should verify Homebrew cask parity")
        assertTrue(checker.contains("check_github_release_metadata"), "nightly checker should verify GitHub release asset metadata")
        assertTrue(checker.contains("github-release-asset-digest"), "nightly checker should compare the cask checksum to the GitHub asset digest")
        assertTrue(checker.contains("check_observability_payload_keys"), "nightly checker should scan observability allowlists for raw payload keys")
        assertTrue(checker.contains("check_posthog_health_schema"), "nightly checker should pin PostHog health schema to AnalyticsEventPolicy")
        assertTrue(checker.contains("first_value_sources"), "PostHog first-value event checks should inspect each probe source independently")
        assertTrue(checker.contains("posthog-first-value-schema-"), "PostHog first-value drift findings should identify the missing probe source")
        assertTrue(preflight.contains("--github-release-json Tests/Fixtures/release-health-github-release-1.1.47.json"), "agent preflight should suggest a strict checker command with deterministic GitHub release metadata")
        assertTrue(matrix.contains("--github-release-json Tests/Fixtures/release-health-github-release-1.1.47.json"), "test matrix should suggest a strict checker command with deterministic GitHub release metadata")
    }

    runSuite("Nightly security checker fails stale GitHub release asset metadata") {
        let passing = runNightlySecurityChecker(arguments: [
            "--strict",
            "--automation-toml", "Tests/Fixtures/nightly-security-automation.toml",
            "--github-release-json", "Tests/Fixtures/release-health-github-release-1.1.47.json"
        ])
        let staleCask = runNightlySecurityChecker(arguments: [
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

private func runNightlySecurityChecker(arguments: [String]) -> ShellResult {
    let process = Process()
    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("nightly-security-check-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
        return ShellResult(status: -127, output: "Unable to create checker output file")
    }
    defer {
        try? FileManager.default.removeItem(at: outputURL)
    }

    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "scripts/ops/nightly-security-check.py"] + arguments
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
