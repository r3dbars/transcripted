import Carbon
import Foundation

/// The languages this person uses, for `DictationLanguageScriptPolicy`: the
/// Mac's preferred languages, the main language of each enabled keyboard
/// (someone with an English Mac and a Russian keyboard dictates Russian too),
/// and a meeting language they picked.
@MainActor
enum DictationUserLanguages {
    static func current() -> [String] {
        var codes = Locale.preferredLanguages
        codes.append(contentsOf: enabledKeyboardLanguages())
        let meetingLanguage = TranscriptionLanguagePreferences.preferredLanguageCode()
        if meetingLanguage != TranscriptionLanguagePreferences.automaticValue {
            codes.append(meetingLanguage)
        }
        return codes
    }

    private static func enabledKeyboardLanguages() -> [String] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return sources.compactMap { source in
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
            // The first language is the one the keyboard is made for; the rest
            // are other languages it can also type.
            let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]
            return languages?.first
        }
    }
}
