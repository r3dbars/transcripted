// WhisperHallucinationFilter.swift
// What Whisper text to keep from audio with no voice in it.
//
// `WhisperVoicedSpeechGate` says whether a segment has a voice. Voiced
// segments keep everything Whisper wrote, exactly as before. Unvoiced ones
// still go to Whisper, because whispering has no pitch and a whispered
// sentence is real speech. From those, a decoding window's text is dropped
// only when it says nothing: no words at all ("...", "-", "*sigh*"), or
// nothing but the stock lines Whisper invents for silence, like "Kiitos.",
// "Kiitos kun katsoit!", "Thank you.", "you" and "Thanks for watching!".
//
// The list only ever applies to unvoiced audio, so a "kiitos" or "thank you"
// someone says out loud is voiced and always kept.

import Foundation

enum WhisperHallucinationFilter {
    /// The texts to keep, one per Whisper decoding window, in order.
    static func keptWindowTexts(_ windowTexts: [String], audioIsVoiced: Bool) -> [String] {
        guard !audioIsVoiced else { return windowTexts }
        return windowTexts.filter { !isSilenceHallucination($0) }
    }

    /// Whether `text` holds nothing but stock silence lines and non-words.
    /// "Kiitos. Kiitos kun katsoit!" is; "Kiitos, nähdään huomenna." isn't.
    static func isSilenceHallucination(_ text: String) -> Bool {
        let withoutTags = text.replacingOccurrences(
            of: #"\*[^*]*\*?|\[[^\]]*\]?|\([^)]*\)?|♪[^♪]*♪?"#,
            with: " ",
            options: .regularExpression
        )
        // Split at sentence ends, but not inside "amara.org" or "1.5".
        let sentences = withoutTags
            .replacingOccurrences(of: #"[。！？]|[.!?…]+(?=\s|$)"#, with: "\n", options: .regularExpression)
            .split(separator: "\n")
        return sentences.allSatisfy { sentence in
            let words = normalizedWords(String(sentence))
            return words.isEmpty || stockLines.contains(words)
        }
    }

    private static func normalizedWords(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let letters = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar) || scalar == "'"
                ? Character(scalar)
                : " "
        }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    /// Lines Whisper is known to write over silence, lowercased with
    /// punctuation removed. Matched whole sentence by sentence, never as a
    /// substring.
    static let stockLines: Set<String> = [
        // Finnish
        "kiitos", "kiitos kun katsoit", "kiitos katsomisesta", "kiitos kun kuuntelit",
        "kiitos paljon", "kiitos hei", "kiitos ja näkemiin", "tekstitys", "suomenkielinen tekstitys",
        "yhteistyössä tehtyä",
        // English
        "you", "thank you", "thank", "thanks", "thank you so much", "thank you very much",
        "thanks for watching", "thank you for watching", "thanks for listening", "thank you for listening",
        "please subscribe", "like and subscribe", "so", "bye", "bye bye", "the end", "amen",
        "subtitles by the amara org community",
        // A lone filler or "I" carries nothing even when someone whispered it.
        "i", "oh", "um", "uh", "hmm", "mm", "mmm", "mm hmm",
        // Swedish
        "tack", "tack för att du tittade", "tack för att ni tittade", "tack för att du lyssnade",
        // German
        "danke", "vielen dank", "danke fürs zuschauen", "untertitel im auftrag des zdf für funk 2017",
        "untertitel der amara org community",
        // Spanish, French, Italian, Portuguese
        "gracias", "gracias por ver el video", "subtítulos realizados por la comunidad de amara org",
        "merci", "merci d'avoir regardé", "sous titres réalisés par la communauté d'amara org",
        "grazie", "grazie per la visione", "obrigado", "obrigada",
        // Dutch, Polish, Czech
        "bedankt", "bedankt voor het kijken", "dziękuję", "dzięki za obejrzenie", "konec", "děkuji",
        // Russian, Japanese, Chinese, Korean
        "продолжение следует", "спасибо", "спасибо за просмотр",
        "ご視聴ありがとうございました", "谢谢观看", "謝謝觀看", "시청해주셔서 감사합니다",
    ]
}
