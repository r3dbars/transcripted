import Foundation

func testAppleSpeechLocalePolicy() {
    let supported = ["en_US", "en_GB", "es_ES", "es_MX", "es_US", "fr_FR", "fr_CA", "pt_BR", "zh_CN", "zh_TW", "yue_CN", "nb_NO"]

    runSuite("Apple Speech locale — the Mac's region wins for the chosen language") {
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(languageCode: "es", preferredRegion: "MX", supportedIdentifiers: supported),
            "es_MX"
        )
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(languageCode: "en", preferredRegion: "gb", supportedIdentifiers: supported),
            "en_GB",
            "region codes compare case-insensitively"
        )
    }

    runSuite("Apple Speech locale — falls back to the language's home region, then a stable first match") {
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(languageCode: "es", preferredRegion: "DE", supportedIdentifiers: supported),
            "es_ES",
            "a Spanish speaker in Germany gets Spain's Spanish, not whatever macOS listed first"
        )
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(languageCode: "fr", preferredRegion: nil, supportedIdentifiers: supported),
            "fr_FR"
        )
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(languageCode: "zh", preferredRegion: nil, supportedIdentifiers: supported.reversed()),
            "zh_CN",
            "the choice must not depend on the order macOS reports locales"
        )
    }

    runSuite("Apple Speech locale — unsupported languages resolve to nil so the engine can explain") {
        assertNil(AppleSpeechLocalePolicy.bestLocaleIdentifier(languageCode: "fi", preferredRegion: "FI", supportedIdentifiers: supported))
        assertNil(AppleSpeechLocalePolicy.bestLocaleIdentifier(languageCode: "", preferredRegion: "US", supportedIdentifiers: supported))
        assertNil(AppleSpeechLocalePolicy.bestLocaleIdentifier(languageCode: "en", preferredRegion: "US", supportedIdentifiers: []))
    }

    runSuite("Apple Speech locale — Cantonese and Chinese stay separate languages") {
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(languageCode: "yue", preferredRegion: "CN", supportedIdentifiers: supported),
            "yue_CN"
        )
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(languageCode: "zh", preferredRegion: "TW", supportedIdentifiers: supported),
            "zh_TW"
        )
    }

    runSuite("Apple Speech locale — Traditional Chinese outside Taiwan still gets Traditional") {
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(
                languageCode: "zh",
                preferredRegion: "US",
                preferredScript: "Hant",
                supportedIdentifiers: supported
            ),
            "zh_TW",
            "a zh-Hant Mac set to the US must not fall back to Simplified"
        )
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(
                languageCode: "zh",
                preferredRegion: "US",
                preferredScript: "Hans",
                supportedIdentifiers: supported
            ),
            "zh_CN"
        )
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(
                languageCode: "es",
                preferredRegion: "MX",
                preferredScript: "Hant",
                supportedIdentifiers: supported
            ),
            "es_MX",
            "a script only matters for its own language"
        )
    }

    runSuite("Apple Speech locale — Mandarin doesn't follow a Hong Kong region onto a Cantonese locale") {
        let withHongKong = supported + ["zh_HK"]
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(
                languageCode: "zh",
                preferredRegion: "HK",
                preferredScript: "Hant",
                supportedIdentifiers: withHongKong
            ),
            "zh_TW",
            "a zh-Hant-HK Mac asking for Mandarin gets Traditional Mandarin"
        )
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(
                languageCode: "zh",
                preferredRegion: "HK",
                supportedIdentifiers: ["zh_HK"]
            ),
            "zh_HK",
            "when it's the only Chinese locale, it's still better than nothing"
        )
    }

    runSuite("Apple Speech locale — the app's stored codes map onto Apple's") {
        assertEqual(
            AppleSpeechLocalePolicy.bestLocaleIdentifier(languageCode: "no", preferredRegion: nil, supportedIdentifiers: supported),
            "nb_NO",
            "the app stores Norwegian as \"no\"; Apple ships Bokmål as nb"
        )
        assertEqual(AppleSpeechLocalePolicy.normalizedLanguageCode("jw"), "jv")
        assertEqual(AppleSpeechLocalePolicy.normalizedLanguageCode(" ES "), "es")
    }

    runSuite("Apple Speech locale — identifier parsing handles scripts and dashes") {
        assertEqual(AppleSpeechLocalePolicy.languageCode(ofIdentifier: "zh-Hans-CN"), "zh")
        assertEqual(AppleSpeechLocalePolicy.regionCode(ofIdentifier: "zh-Hans-CN"), "CN")
        assertEqual(AppleSpeechLocalePolicy.regionCode(ofIdentifier: "es-419"), "419")
        assertNil(AppleSpeechLocalePolicy.regionCode(ofIdentifier: "es"))
        assertEqual(AppleSpeechLocalePolicy.languageCode(ofIdentifier: "es_MX"), "es")
        assertEqual(AppleSpeechLocalePolicy.scriptCode(ofIdentifier: "zh-Hant-US"), "Hant")
        assertNil(AppleSpeechLocalePolicy.scriptCode(ofIdentifier: "es_ES"))
    }

    runSuite("Apple Speech locale — result pieces join without spaces only for languages written that way") {
        assertTrue(AppleSpeechLocalePolicy.writesWithoutSpaces(localeIdentifier: "zh_CN"))
        assertTrue(AppleSpeechLocalePolicy.writesWithoutSpaces(localeIdentifier: "ja-JP"))
        assertTrue(AppleSpeechLocalePolicy.writesWithoutSpaces(localeIdentifier: "yue_CN"))
        assertFalse(AppleSpeechLocalePolicy.writesWithoutSpaces(localeIdentifier: "es_ES"))
        assertFalse(AppleSpeechLocalePolicy.writesWithoutSpaces(localeIdentifier: "ko_KR"), "Korean uses spaces")
    }

    runSuite("Apple Speech locale — supported language codes feed the meeting language picker") {
        let codes = AppleSpeechLocalePolicy.supportedLanguageCodes(supportedIdentifiers: supported)
        assertEqual(codes, ["en", "es", "fr", "pt", "zh", "yue", "no"])
        assertTrue(AppleSpeechLocalePolicy.supportedLanguageCodes(supportedIdentifiers: []).isEmpty)
    }

    runSuite("Apple Speech reservations — nothing is released under the limit or for a reserved language") {
        assertNil(AppleSpeechLocalePolicy.reservationToRelease(
            reservedIdentifiers: ["en_US", "es_ES"], limit: 3, wantedIdentifier: "fr_FR",
            keepLanguages: [], lastUsed: [:]
        ))
        assertNil(AppleSpeechLocalePolicy.reservationToRelease(
            reservedIdentifiers: ["en_US", "es_MX"], limit: 2, wantedIdentifier: "es_ES",
            keepLanguages: [], lastUsed: [:]
        ), "Apple may report a variant; Spanish is already reserved")
        assertNil(AppleSpeechLocalePolicy.reservationToRelease(
            reservedIdentifiers: ["en_US"], limit: 0, wantedIdentifier: "fr_FR",
            keepLanguages: [], lastUsed: [:]
        ), "an unknown limit never releases anything")
    }

    runSuite("Apple Speech reservations — the least recently used language not in use goes first") {
        let now = Date()
        let lastUsed = ["de": now.addingTimeInterval(-60), "it": now.addingTimeInterval(-3600), "ja": now]
        assertEqual(AppleSpeechLocalePolicy.reservationToRelease(
            reservedIdentifiers: ["en_US", "de_DE", "it_IT", "ja_JP"], limit: 4, wantedIdentifier: "fr_FR",
            keepLanguages: ["en"], lastUsed: lastUsed
        ), 2, "Italian was used longest ago; English is dictation's and stays")
        assertEqual(AppleSpeechLocalePolicy.reservationToRelease(
            reservedIdentifiers: ["en_US", "de_DE", "ko_KR"], limit: 3, wantedIdentifier: "fr_FR",
            keepLanguages: ["en"], lastUsed: ["de": now]
        ), 2, "never used this session counts as oldest")
        assertEqual(AppleSpeechLocalePolicy.reservationToRelease(
            reservedIdentifiers: ["en_US", "de_DE", "ko_KR"], limit: 3, wantedIdentifier: "fr_FR",
            keepLanguages: ["EN"], lastUsed: [:]
        ), 1, "ties keep Apple's order, and kept languages compare case-insensitively")
        assertNil(AppleSpeechLocalePolicy.reservationToRelease(
            reservedIdentifiers: ["en_US", "es_ES"], limit: 2, wantedIdentifier: "fr_FR",
            keepLanguages: ["en", "es"], lastUsed: [:]
        ), "when every reservation is in use, nothing is released and Apple's error surfaces")
    }

    runSuite("Apple Speech language download — Settings line") {
        let downloading = AppleSpeechLanguageDownload(languageCode: "es", phase: .downloading(progress: 0.404))
        assertEqual(downloading.caption(languageName: "Spanish"), "Downloading Spanish from Apple… 40%")
        let overflow = AppleSpeechLanguageDownload(languageCode: "es", phase: .downloading(progress: 1.7))
        assertEqual(overflow.caption(languageName: "Spanish"), "Downloading Spanish from Apple… 100%")
        let unknown = AppleSpeechLanguageDownload(languageCode: "es", phase: .downloading(progress: .nan))
        assertEqual(unknown.caption(languageName: "Spanish"), "Downloading Spanish from Apple… 0%")
        let failed = AppleSpeechLanguageDownload(languageCode: "es", phase: .failed("NSURLErrorDomain -1009"))
        assertFalse(failed.caption(languageName: "Spanish").contains("NSURLErrorDomain"), "raw errors stay out of Settings")
        assertTrue(failed.caption(languageName: "Spanish").contains("Couldn't download Spanish"))
    }
}
