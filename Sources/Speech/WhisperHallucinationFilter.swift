// WhisperHallucinationFilter.swift
// What Whisper text to keep from audio with no voice in it.
//
// `WhisperVoicedSpeechGate` says whether a decoder window has a voice. Voiced
// windows keep everything Whisper wrote, exactly as before. Unvoiced ones
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
    /// Pinned WhisperKit 0.18, with timestamps disabled, emits one segment per
    /// 30 s decoder window. `seek` is an exact sample offset in the input;
    /// start/end are Float seconds covering the unpadded part of that window.
    /// See argmax-oss-swift e2adabbe, Core/TranscribeTask.swift window slicing
    /// and Core/Text/SegmentSeeker.swift's no-consecutive-timestamps branch.
    struct DecodedWindow: Sendable {
        let text: String
        let seek: Int
        let start: Float
        let end: Float
    }

    struct FilteredWindows: Sendable {
        var texts: [String] = []
        var droppedWindows = 0
        var voicedWindows = 0
        var unvoicedWindows = 0
    }

    static let decoderWindowSamples = 30 * 16_000

    /// Scope audio evidence to the window that produced the words, with one
    /// pitch run's context at its edges to preserve words cut by a boundary.
    /// Remote voice in another window never exempts this window's silence.
    /// Unknown timing preserves text: it is never evidence of silence.
    static func filterWindows(_ windows: [DecodedWindow], samples: [Float]) -> FilteredWindows {
        var result = FilteredWindows()
        for window in windows {
            guard let range = sampleRange(for: window, sampleCount: samples.count) else {
                result.texts.append(window.text)
                continue
            }
            let voiced = WhisperVoicedSpeechGate.hasVoicedSpeech(samples[range])
            if voiced { result.voicedWindows += 1 } else { result.unvoicedWindows += 1 }
            if !voiced, isSilenceHallucination(window.text) {
                result.droppedWindows += 1
            } else {
                result.texts.append(window.text)
            }
        }
        return result
    }

    private static func sampleRange(for window: DecodedWindow, sampleCount: Int) -> Range<Int>? {
        guard window.seek >= 0, window.seek < sampleCount,
              window.start.isFinite, window.end.isFinite, window.end > window.start else { return nil }
        // Subtract before adding, so even malformed near-Int.max offsets do
        // not overflow. The final window ends at actual input, before padding.
        let count = min(decoderWindowSamples, sampleCount - window.seek)
        let endSample = window.seek + count
        let expectedStart = Float(window.seek) / 16_000
        let expectedEnd = expectedStart + Float(count) / 16_000
        // Match the upstream Float arithmetic, permitting only rounding at
        // this magnitude. Different timestamp/chunking semantics fail open.
        let tolerance = max(expectedStart.ulp, expectedEnd.ulp) * 2
        guard abs(window.start - expectedStart) <= tolerance,
              abs(window.end - expectedEnd) <= tolerance else { return nil }
        let context = WhisperVoicedSpeechGate.minimumVoicedSupportSamples
        let contextStart = max(0, window.seek - context)
        let contextEnd = endSample + min(context, sampleCount - endSample)
        return contextStart..<contextEnd
    }

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
