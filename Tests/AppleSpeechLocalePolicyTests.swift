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
}
