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
           !(regionsMeaningAnotherLanguage[wanted]?.contains(preferredRegion) ?? false),
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

    /// Which of Apple's reserved locales to give back before reserving
    /// `wantedIdentifier`, as an index into `reservedIdentifiers`, or nil when
    /// nothing needs to go (under the limit, or the language is already
    /// reserved) or everything reserved is still needed.
    ///
    /// Apple may report a variant of the locale it was given, so languages are
    /// compared, not identifiers. `keepLanguages` are languages still in use
    /// (dictation's, the saved meeting language, installs in flight). Among
    /// the rest, the least recently used goes first; never-used counts as
    /// oldest, and ties keep Apple's order.
    static func reservationToRelease(
        reservedIdentifiers: [String],
        limit: Int,
        wantedIdentifier: String,
        keepLanguages: Set<String>,
        lastUsed: [String: Date]
    ) -> Int? {
        guard limit > 0, reservedIdentifiers.count >= limit else { return nil }
        let wanted = languageCode(ofIdentifier: wantedIdentifier)
        let reservedLanguages = reservedIdentifiers.map(languageCode(ofIdentifier:))
        guard !reservedLanguages.contains(wanted) else { return nil }

        let keep = Set(keepLanguages.map(normalizedLanguageCode)).union([wanted])
        return reservedLanguages.indices
            .filter { !keep.contains(reservedLanguages[$0]) }
            .min { lhs, rhs in
                let left = lastUsed[reservedLanguages[lhs]] ?? .distantPast
                let right = lastUsed[reservedLanguages[rhs]] ?? .distantPast
                return left == right ? lhs < rhs : left < right
            }
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

    /// Regions whose locale for this language code has historically meant a
    /// different spoken language in Apple's speech engines: zh-HK/zh-MO were
    /// Cantonese. The app lists Cantonese separately ("yue"), so "zh" (Mandarin)
    /// doesn't follow a Hong Kong or Macau region onto them.
    private static let regionsMeaningAnotherLanguage: [String: Set<String>] = [
        "zh": ["HK", "MO"],
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

/// One language's download from Apple, for Settings to show. Kept apart from
/// the engine's model state so a meeting language downloading after setup
/// never makes the whole engine look unloaded.
struct AppleSpeechLanguageDownload: Equatable {
    enum Phase: Equatable {
        case downloading(progress: Double)
        case failed(String)
    }

    let languageCode: String
    let phase: Phase

    /// The Meeting language row's line for this download. The failure text
    /// stays plain: Apple's raw error isn't something a person can act on.
    func caption(languageName: String) -> String {
        switch phase {
        case .downloading(let progress):
            let fraction = progress.isFinite ? min(max(progress, 0), 1) : 0
            return "Downloading \(languageName) from Apple… \(Int((fraction * 100).rounded()))%"
        case .failed:
            return "Couldn't download \(languageName) from Apple. Check your internet connection. It'll try again when a meeting needs it."
        }
    }
}
