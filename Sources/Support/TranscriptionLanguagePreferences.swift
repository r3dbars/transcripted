import Foundation

struct TranscriptionLanguageChoice: Identifiable, Equatable, Sendable {
    let code: String
    let title: String

    var id: String { code }
}

/// Meetings/imports only. Callers snapshot this together with their model so
/// later preference changes do not alter queued work. Dictation does not read it.
enum TranscriptionLanguagePreferences {
    static let preferenceKey = "meetingTranscriptionLanguage"
    static let automaticValue = "auto"

    // One title per code from WhisperKit Constants.languages, pinned at
    // argmax-oss-swift e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef. Aliases are
    // omitted. The engine separately validates against the actual catalog.
    static let supportedLanguages: [TranscriptionLanguageChoice] = [
        .init(code: "af", title: "Afrikaans"),
        .init(code: "sq", title: "Albanian"),
        .init(code: "am", title: "Amharic"),
        .init(code: "ar", title: "Arabic"),
        .init(code: "hy", title: "Armenian"),
        .init(code: "as", title: "Assamese"),
        .init(code: "az", title: "Azerbaijani"),
        .init(code: "ba", title: "Bashkir"),
        .init(code: "eu", title: "Basque"),
        .init(code: "be", title: "Belarusian"),
        .init(code: "bn", title: "Bengali"),
        .init(code: "bs", title: "Bosnian"),
        .init(code: "br", title: "Breton"),
        .init(code: "bg", title: "Bulgarian"),
        .init(code: "my", title: "Burmese"),
        .init(code: "yue", title: "Cantonese"),
        .init(code: "ca", title: "Catalan"),
        .init(code: "zh", title: "Chinese"),
        .init(code: "hr", title: "Croatian"),
        .init(code: "cs", title: "Czech"),
        .init(code: "da", title: "Danish"),
        .init(code: "nl", title: "Dutch"),
        .init(code: "en", title: "English"),
        .init(code: "et", title: "Estonian"),
        .init(code: "fo", title: "Faroese"),
        .init(code: "fi", title: "Finnish"),
        .init(code: "fr", title: "French"),
        .init(code: "gl", title: "Galician"),
        .init(code: "ka", title: "Georgian"),
        .init(code: "de", title: "German"),
        .init(code: "el", title: "Greek"),
        .init(code: "gu", title: "Gujarati"),
        .init(code: "ht", title: "Haitian Creole"),
        .init(code: "ha", title: "Hausa"),
        .init(code: "haw", title: "Hawaiian"),
        .init(code: "he", title: "Hebrew"),
        .init(code: "hi", title: "Hindi"),
        .init(code: "hu", title: "Hungarian"),
        .init(code: "is", title: "Icelandic"),
        .init(code: "id", title: "Indonesian"),
        .init(code: "it", title: "Italian"),
        .init(code: "ja", title: "Japanese"),
        .init(code: "jw", title: "Javanese"),
        .init(code: "kn", title: "Kannada"),
        .init(code: "kk", title: "Kazakh"),
        .init(code: "km", title: "Khmer"),
        .init(code: "ko", title: "Korean"),
        .init(code: "lo", title: "Lao"),
        .init(code: "la", title: "Latin"),
        .init(code: "lv", title: "Latvian"),
        .init(code: "ln", title: "Lingala"),
        .init(code: "lt", title: "Lithuanian"),
        .init(code: "lb", title: "Luxembourgish"),
        .init(code: "mk", title: "Macedonian"),
        .init(code: "mg", title: "Malagasy"),
        .init(code: "ms", title: "Malay"),
        .init(code: "ml", title: "Malayalam"),
        .init(code: "mt", title: "Maltese"),
        .init(code: "mi", title: "Māori"),
        .init(code: "mr", title: "Marathi"),
        .init(code: "mn", title: "Mongolian"),
        .init(code: "ne", title: "Nepali"),
        .init(code: "no", title: "Norwegian"),
        .init(code: "nn", title: "Norwegian Nynorsk"),
        .init(code: "oc", title: "Occitan"),
        .init(code: "ps", title: "Pashto"),
        .init(code: "fa", title: "Persian"),
        .init(code: "pl", title: "Polish"),
        .init(code: "pt", title: "Portuguese"),
        .init(code: "pa", title: "Punjabi"),
        .init(code: "ro", title: "Romanian"),
        .init(code: "ru", title: "Russian"),
        .init(code: "sa", title: "Sanskrit"),
        .init(code: "sr", title: "Serbian"),
        .init(code: "sn", title: "Shona"),
        .init(code: "sd", title: "Sindhi"),
        .init(code: "si", title: "Sinhala"),
        .init(code: "sk", title: "Slovak"),
        .init(code: "sl", title: "Slovenian"),
        .init(code: "so", title: "Somali"),
        .init(code: "es", title: "Spanish"),
        .init(code: "su", title: "Sundanese"),
        .init(code: "sw", title: "Swahili"),
        .init(code: "sv", title: "Swedish"),
        .init(code: "tl", title: "Tagalog"),
        .init(code: "tg", title: "Tajik"),
        .init(code: "ta", title: "Tamil"),
        .init(code: "tt", title: "Tatar"),
        .init(code: "te", title: "Telugu"),
        .init(code: "th", title: "Thai"),
        .init(code: "bo", title: "Tibetan"),
        .init(code: "tr", title: "Turkish"),
        .init(code: "tk", title: "Turkmen"),
        .init(code: "uk", title: "Ukrainian"),
        .init(code: "ur", title: "Urdu"),
        .init(code: "uz", title: "Uzbek"),
        .init(code: "vi", title: "Vietnamese"),
        .init(code: "cy", title: "Welsh"),
        .init(code: "yi", title: "Yiddish"),
        .init(code: "yo", title: "Yoruba"),
    ]

    private static let supportedCodes = Set(supportedLanguages.map(\.code))

    static func isSupportedPreference(_ rawValue: String) -> Bool {
        rawValue == automaticValue || supportedCodes.contains(rawValue)
    }

    static func normalizedLanguageCode(_ rawValue: String) -> String {
        isSupportedPreference(rawValue) ? rawValue : automaticValue
    }

    static func displayName(for rawValue: String) -> String {
        supportedLanguages.first { $0.code == rawValue }?.title ?? "Auto"
    }

    static func preferredLanguageCode(userDefaults: UserDefaults = .standard) -> String {
        normalizedLanguageCode(userDefaults.string(forKey: preferenceKey) ?? automaticValue)
    }

    @discardableResult
    static func setPreferredLanguageCode(_ rawValue: String, userDefaults: UserDefaults = .standard) -> Bool {
        guard isSupportedPreference(rawValue) else { return false }
        userDefaults.set(rawValue, forKey: preferenceKey)
        return true
    }

    static func effectiveLanguageCode(
        for model: TranscriptionModelChoice,
        userDefaults: UserDefaults = .standard
    ) -> String {
        effectiveLanguageCode(for: model, preferredLanguageCode: preferredLanguageCode(userDefaults: userDefaults))
    }

    static func effectiveLanguageCode(for model: TranscriptionModelChoice, preferredLanguageCode: String) -> String {
        // Parakeet cannot enforce an explicit language. Preserve the preference
        // so returning to Whisper or Apple Speech restores it without an
        // implicit model switch.
        model.supportsMeetingLanguageChoice ? normalizedLanguageCode(preferredLanguageCode) : automaticValue
    }
}
