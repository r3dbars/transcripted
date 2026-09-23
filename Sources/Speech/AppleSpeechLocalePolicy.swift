import Foundation

/// Picks which of Apple's SpeechTranscriber locales to use for a language.
/// Foundation-only so the fast tests can pin it without the Speech framework.
///
/// Apple's on-device engine has no language detection: it needs one locale
/// per recording. The app's language setting stores bare language codes
/// ("es"), while Apple ships per-region assets ("es_ES", "es_MX", "es_US").
enum AppleSpeechLocalePolicy {
    /// Returns the supported locale identifier that best matches `languageCode`,
    /// or nil when Apple's engine has no locale for that language.
    ///
    /// Preference order: the Mac's own region for that language, then the
    /// region its script implies (Traditional Chinese → Taiwan), then the
    /// language's conventional home region, then the first supported match in
    /// sorted order so the choice is stable across launches.
    static func bestLocaleIdentifier(
        languageCode: String,
        preferredRegion: String?,
        preferredScript: String? = nil,
        supportedIdentifiers: [String]
    ) -> String? {
        let wanted = normalizedLanguageCode(languageCode)
        guard !wanted.isEmpty else { return nil }

        let candidates = supportedIdentifiers
            .filter { Self.languageCode(ofIdentifier: $0) == wanted }
            .sorted()
        guard !candidates.isEmpty else { return nil }

        if let preferredRegion = preferredRegion?.uppercased(), !preferredRegion.isEmpty,
           let match = candidates.first(where: { regionCode(ofIdentifier: $0) == preferredRegion }) {
            return match
        }
        if let script = preferredScript?.lowercased(),
           let scriptRegion = scriptRegions["\(wanted)-\(script)"],
           let match = candidates.first(where: { regionCode(ofIdentifier: $0) == scriptRegion }) {
            return match
        }
        if let homeRegion = homeRegions[wanted],
           let match = candidates.first(where: { regionCode(ofIdentifier: $0) == homeRegion }) {
            return match
        }
        return candidates.first
    }

    /// Bare language codes Apple's engine can transcribe, for filtering the
    /// meeting language picker.
    static func supportedLanguageCodes(supportedIdentifiers: [String]) -> Set<String> {
        Set(supportedIdentifiers.map(languageCode(ofIdentifier:)).filter { !$0.isEmpty })
    }

    /// "es_ES" / "es-ES" / "zh-Hans-CN" → "es" / "es" / "zh".
    static func languageCode(ofIdentifier identifier: String) -> String {
        let first = identifier
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .first
            .map(String.init) ?? ""
        return normalizedLanguageCode(first)
    }

    /// "es_ES" → "ES"; "zh-Hans-CN" → "CN"; "es" → nil.
    static func regionCode(ofIdentifier identifier: String) -> String? {
        let parts = identifier
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .dropFirst()
            .map(String.init)
        // Regions are two letters or three digits; scripts ("Hans") are four letters.
        return parts.last { part in
            (part.count == 2 && part.allSatisfy(\.isLetter))
                || (part.count == 3 && part.allSatisfy(\.isNumber))
        }?.uppercased()
    }

    /// Chinese, Japanese, Cantonese and Thai don't put spaces between words,
    /// so Apple's result pieces join without a separator.
    static func writesWithoutSpaces(localeIdentifier: String) -> Bool {
        languagesWrittenWithoutSpaces.contains(languageCode(ofIdentifier: localeIdentifier))
    }

    private static let languagesWrittenWithoutSpaces: Set<String> = ["ja", "lo", "km", "my", "th", "yue", "zh"]

    /// "zh-Hant-US" → "Hant"; "es_ES" → nil.
    static func scriptCode(ofIdentifier identifier: String) -> String? {
        identifier
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .dropFirst()
            .map(String.init)
            .first { $0.count == 4 && $0.allSatisfy(\.isLetter) }
    }

    /// Maps the Whisper-era codes the app stores onto ISO codes Apple uses.
    static func normalizedLanguageCode(_ code: String) -> String {
        let lowered = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return legacyAliases[lowered] ?? lowered
    }

    private static let legacyAliases: [String: String] = [
        "jw": "jv",   // Whisper's Javanese code
        "iw": "he",   // pre-1989 Hebrew
        "in": "id",   // pre-1989 Indonesian
        "nb": "no",   // Norwegian Bokmål is stored as "no" by the app
    ]

    /// Keys are "language-script", lowercased.
    private static let scriptRegions: [String: String] = [
        "zh-hant": "TW",
        "zh-hans": "CN",
    ]

    private static let homeRegions: [String: String] = [
        "ar": "SA",
        "de": "DE",
        "en": "US",
        "es": "ES",
        "fr": "FR",
        "it": "IT",
        "ja": "JP",
        "ko": "KR",
        "nl": "NL",
        "pt": "BR",
        "ru": "RU",
        "sv": "SE",
        "tr": "TR",
        "yue": "CN",
        "zh": "CN",
    ]
}
