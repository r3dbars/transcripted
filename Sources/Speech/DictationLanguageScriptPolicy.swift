import Foundation

/// Dictation has no language setting, and Parakeet V3, Parakeet Ultra and
/// Whisper pick the language themselves. On a short or unclear clip they can
/// land on the wrong one and write, say, Russian for an English speaker. None
/// of them take a language hint for dictation (FluidAudio's Parakeet has no
/// such input), so this checks the finished text instead: text that is nearly
/// all in a writing system none of the person's languages use is not pasted
/// right away. The message offers Paste Anyway and the audio is kept. It runs
/// for every model; the others only ever write in an expected script.
///
/// Latin letters are always accepted (names, brands and English words show up
/// in every language), and scripts this policy can't classify are never
/// rejected. So it only catches the clear case: a whole dictation in, say,
/// Cyrillic, Greek or Han when the Mac is set up for none of those. A wrong
/// guess between two Latin-script languages (Polish for English) isn't caught.
enum DictationLanguageScriptPolicy {
    enum Script: String, CaseIterable {
        case latin
        case cyrillic
        case greek
        case arabic
        case hebrew
        case han
        case kana
        case hangul
        case devanagari
        case thai
        case georgian
        case armenian
    }

    /// Fewer letters than this are too little to judge. A Han character
    /// counts as one letter, so this still covers a short Chinese phrase.
    static let minimumLetterCount = 4
    /// Share of the classified letters one non-Latin script must reach. High
    /// on purpose: "Email Дмитрий" or "Ask 王先生" is an English sentence with a
    /// name in it, not a wrong-language guess.
    static let rejectionShare = 0.8

    /// The non-Latin script that makes up nearly all of `text`, or nil when
    /// the text is Latin, mixed, too short, or in a script this policy can't
    /// classify. It needs no language list, so callers can skip reading the
    /// person's languages for ordinary text.
    static func dominantNonLatinScript(in text: String) -> Script? {
        var counts: [Script: Int] = [:]
        var classifiedLetters = 0
        for scalar in text.unicodeScalars {
            guard let script = script(of: scalar) else { continue }
            counts[script, default: 0] += 1
            classifiedLetters += 1
        }
        guard classifiedLetters >= minimumLetterCount else { return nil }
        // With an 80% bar at most one script can qualify, so ties never matter.
        return counts.first { script, count in
            script != .latin && Double(count) / Double(classifiedLetters) >= rejectionShare
        }?.key
    }

    /// The unexpected script that dominates `text`, or nil when the text is
    /// fine to paste.
    static func unexpectedScript(in text: String, userLanguageCodes: [String]) -> Script? {
        guard let dominant = dominantNonLatinScript(in: text) else { return nil }
        return isExpected(dominant, userLanguageCodes: userLanguageCodes) ? nil : dominant
    }

    static func isExpected(_ script: Script, userLanguageCodes: [String]) -> Bool {
        expectedScripts(forLanguageCodes: userLanguageCodes).contains(script)
    }

    /// Scripts the given languages are written in. Latin is always included.
    /// A language this map doesn't know is assumed to be written in Latin,
    /// which only makes the check more permissive for its own script.
    static func expectedScripts(forLanguageCodes codes: [String]) -> Set<Script> {
        var scripts: Set<Script> = [.latin]
        for code in codes {
            scripts.formUnion(scriptsByLanguage[baseLanguageCode(code)] ?? [])
        }
        return scripts
    }

    /// "ru-RU", "zh_Hans_CN" and "en" all reduce to their bare language code.
    static func baseLanguageCode(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? trimmed
        return base
    }

    private static let scriptsByLanguage: [String: Set<Script>] = [
        // Cyrillic
        "ru": [.cyrillic], "uk": [.cyrillic], "be": [.cyrillic], "bg": [.cyrillic],
        "mk": [.cyrillic], "sr": [.cyrillic], "kk": [.cyrillic], "ky": [.cyrillic],
        "mn": [.cyrillic], "tg": [.cyrillic], "tt": [.cyrillic], "ba": [.cyrillic],
        "uz": [.cyrillic], "az": [.cyrillic], "bs": [.cyrillic], "cnr": [.cyrillic],
        // Greek
        "el": [.greek],
        // Arabic script
        "ar": [.arabic], "fa": [.arabic], "ur": [.arabic], "ps": [.arabic],
        "sd": [.arabic], "ug": [.arabic], "ku": [.arabic], "ckb": [.arabic], "pnb": [.arabic],
        // Hebrew script
        "he": [.hebrew], "iw": [.hebrew], "yi": [.hebrew],
        // East Asian
        "zh": [.han], "yue": [.han], "ja": [.han, .kana], "ko": [.hangul, .han],
        // Indic and others
        "hi": [.devanagari], "mr": [.devanagari], "ne": [.devanagari], "sa": [.devanagari],
        "th": [.thai], "ka": [.georgian], "hy": [.armenian],
    ]

    static func script(of scalar: Unicode.Scalar) -> Script? {
        let value = scalar.value
        switch value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x00D6, 0x00D8...0x00F6,
             0x00F8...0x024F, 0x1E00...0x1EFF:
            return .latin
        case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            // 0x0374/0x037E/0x0387 are punctuation; letters only.
            return scalar.properties.isAlphabetic ? .greek : nil
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return scalar.properties.isAlphabetic ? .arabic : nil
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return scalar.properties.isAlphabetic ? .hebrew : nil
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return .han
        case 0x3041...0x3096, 0x30A1...0x30FA, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            return .kana
        case 0x1100...0x11FF, 0x3131...0x318E, 0xAC00...0xD7AF:
            return .hangul
        case 0x0900...0x097F:
            return scalar.properties.isAlphabetic ? .devanagari : nil
        case 0x0E00...0x0E7F:
            return scalar.properties.isAlphabetic ? .thai : nil
        case 0x10A0...0x10FF, 0x1C90...0x1CBF:
            return .georgian
        case 0x0531...0x058F:
            return scalar.properties.isAlphabetic ? .armenian : nil
        default:
            return nil
        }
    }
}
