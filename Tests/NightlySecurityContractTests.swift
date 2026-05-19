import Foundation

func testNightlySecurityContract() {
    runSuite("Nightly security manifest is parseable and weights sum to 100") {
        let manifest = loadJSONFixture("config/security/nightly-security-manifest.json", as: [String: AnyDecodable].self)
        let weights = manifest["scoring"]?.dictionaryValue?["weights"]?.dictionaryValue ?? [:]
        let totalWeight = weights.values.compactMap(\.intValue).reduce(0, +)

        assertEqual(totalWeight, 100, "nightly scoring weights should add up to 100")
        assertNotNil(manifest["paths"]?.dictionaryValue?["sanitizer_corpus"]?.stringValue, "manifest should point at the shared sanitizer corpus")
        assertNotNil(manifest["expected_info_plist"]?.dictionaryValue?["SUFeedURL"]?.stringValue, "manifest should pin the Sparkle feed URL")
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

        assertTrue(scriptsReadme.contains("nightly-security-check.py"), "scripts README should mention the nightly security checker")
        assertTrue(privacyDoc.contains("nightly-security-check.py"), "privacy observability doc should mention the nightly security checker")
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

struct AnyDecodable: Decodable {
    let stringValue: String?
    let intValue: Int?
    let boolValue: Bool?
    let dictionaryValue: [String: AnyDecodable]?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string
            intValue = nil
            boolValue = nil
            dictionaryValue = nil
        } else if let int = try? container.decode(Int.self) {
            stringValue = nil
            intValue = int
            boolValue = nil
            dictionaryValue = nil
        } else if let bool = try? container.decode(Bool.self) {
            stringValue = nil
            intValue = nil
            boolValue = bool
            dictionaryValue = nil
        } else if let dictionary = try? container.decode([String: AnyDecodable].self) {
            stringValue = nil
            intValue = nil
            boolValue = nil
            dictionaryValue = dictionary
        } else {
            stringValue = nil
            intValue = nil
            boolValue = nil
            dictionaryValue = nil
        }
    }
}
