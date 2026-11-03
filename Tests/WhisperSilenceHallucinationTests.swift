import Foundation

// Promise: Whisper's made-up lines over silence ("Kiitos.", "Thank you.",
// "Thanks for watching!") never reach a transcript, and real speech always
// does. `WhisperVoicedSpeechGate` says whether audio has a voice;
// `WhisperHallucinationFilter` drops stock silence lines only from audio
// without one, so a "kiitos" said out loud is kept.
// Synthetic: generated tones and noise, no real microphone or Whisper model.
// The real-audio numbers are in the commit message.

private let rate = 16_000

/// Deterministic noise so a failure reproduces.
private struct NoiseSource {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2_000_001 - 1_000_000) / 1_000_000
    }

    mutating func gaussian() -> Float {
        (0..<4).reduce(Float(0)) { sum, _ in sum + next() } * 0.87
    }
}

private func scaled(_ samples: [Float], rms: Float) -> [Float] {
    let current = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
    return samples.map { $0 * rms / max(current, 1e-9) }
}

/// Brown noise: a random walk, nearly all rumble. Of the noises tried, this
/// one most often lines up into a chance pitch for a frame.
private func brown(seconds: Double, rms: Float, seed: UInt64) -> [Float] {
    var source = NoiseSource(state: seed)
    var value: Float = 0
    return scaled((0..<Int(seconds * Double(rate))).map { _ in
        value = 0.995 * value + source.gaussian() * 0.05
        return value
    }, rms: rms)
}

/// Pink noise (Kellet's filter): the usual model of room tone.
private func pink(seconds: Double, rms: Float, seed: UInt64) -> [Float] {
    var source = NoiseSource(state: seed)
    var b0: Float = 0, b1: Float = 0, b2: Float = 0
    return scaled((0..<Int(seconds * Double(rate))).map { _ in
        let input = source.gaussian()
        b0 = 0.99765 * b0 + input * 0.0990460
        b1 = 0.96300 * b1 + input * 0.2965164
        b2 = 0.57000 * b2 + input * 1.0526913
        return b0 + b1 + b2 + input * 0.1848
    }, rms: rms)
}

private func white(seconds: Double, level: Float, seed: UInt64 = 7) -> [Float] {
    var source = NoiseSource(state: seed)
    return (0..<Int(seconds * Double(rate))).map { _ in source.next() * level }
}

/// Room tone: low-passed noise with most of its energy down low, like a fan
/// or HVAC rumble.
private func rumble(seconds: Double, level: Float, seed: UInt64 = 11) -> [Float] {
    var source = NoiseSource(state: seed)
    var smoothed: Float = 0
    var out = (0..<Int(seconds * Double(rate))).map { _ -> Float in
        smoothed = 0.98 * smoothed + 0.02 * source.next()
        return smoothed
    }
    let peak = out.map(abs).max() ?? 1
    out = out.map { $0 / max(peak, 1e-9) * level }
    return out
}

/// Keyboard-like clicks: short decaying bursts over quiet noise.
private func clicks(seconds: Double, level: Float) -> [Float] {
    var audio = white(seconds: seconds, level: level / 40, seed: 3)
    var source = NoiseSource(state: 5)
    var at = 1_200
    while at + 200 < audio.count {
        for offset in 0..<160 {
            audio[at + offset] += level * exp(-Float(offset) / 25) * source.next()
        }
        at += 2_900
    }
    return audio
}

/// A sung-vowel stand-in for speech: a harmonic stack at `pitch` Hz with a
/// little vibrato, faded in and out.
private func vowel(seconds: Double, pitch: Double, level: Float) -> [Float] {
    let count = Int(seconds * Double(rate))
    var phase = 0.0
    return (0..<count).map { index in
        let time = Double(index) / Double(rate)
        let f0 = pitch * (1 + 0.02 * sin(2 * .pi * 5 * time))
        phase += 2 * .pi * f0 / Double(rate)
        var sample = 0.0
        for harmonic in 1...12 {
            sample += sin(Double(harmonic) * phase) / Double(harmonic)
        }
        let fade = min(1, min(time, seconds - time) / 0.03)
        return Float(sample * fade) * level / 2
    }
}

private func mixed(_ layers: [Float]...) -> [Float] {
    let count = layers.map(\.count).max() ?? 0
    return (0..<count).map { index in
        layers.reduce(Float(0)) { $0 + (index < $1.count ? $1[index] : 0) }
    }
}

/// A vowel under pink room tone at about 3 dB SNR.
private func noisyVowel() -> [Float] {
    let voice = vowel(seconds: 0.4, pitch: 130, level: 0.05)
    let voiceRMS = (voice.reduce(Float(0)) { $0 + $1 * $1 } / Float(voice.count)).squareRoot()
    return mixed(voice, pink(seconds: 0.4, rms: voiceRMS * 0.7, seed: 9))
}

/// The meeting mic path's 12x quiet-segment boost, then padding to 1 s.
private func boostedAndPadded(_ samples: [Float]) -> [Float] {
    let boosted = samples.map { max(-1, min(1, $0 * 12)) }
    return boosted + [Float](repeating: 0, count: max(0, rate - boosted.count))
}

func testWhisperSilenceHallucination() {
    runSuite("Silence, room tone, hiss and clicks have no voice in them") {
        let noVoice: [(String, [Float])] = [
            ("digital silence", [Float](repeating: 0, count: rate * 2)),
            ("padded short silence", boostedAndPadded([Float](repeating: 0, count: rate / 2))),
            ("hiss", white(seconds: 3, level: 0.002)),
            ("boosted hiss", boostedAndPadded(white(seconds: 1.5, level: 0.0008))),
            ("room rumble", rumble(seconds: 4, level: 0.003)),
            ("boosted room rumble", boostedAndPadded(rumble(seconds: 1.5, level: 0.001))),
            ("brown noise", brown(seconds: 12, rms: 0.003, seed: 1)),
            ("other brown noise", brown(seconds: 12, rms: 0.003, seed: 2)),
            ("pink room tone", pink(seconds: 12, rms: 0.003, seed: 3)),
            ("typing", clicks(seconds: 3, level: 0.05)),
        ]
        for (label, audio) in noVoice {
            assertFalse(WhisperVoicedSpeechGate.hasVoicedSpeech(audio), "\(label) must not count as a voice")
        }
    }

    runSuite("A spoken vowel counts as a voice at any level, pitch or room") {
        let voiced: [(String, [Float])] = [
            ("loud", vowel(seconds: 0.4, pitch: 120, level: 0.3)),
            ("low voice", vowel(seconds: 0.4, pitch: 85, level: 0.3)),
            ("high voice", vowel(seconds: 0.4, pitch: 320, level: 0.3)),
            ("quiet and boosted", boostedAndPadded(mixed(vowel(seconds: 0.3, pitch: 140, level: 0.004), white(seconds: 0.6, level: 0.0002)))),
            ("short word in room tone", mixed(rumble(seconds: 1.5, level: 0.01), [Float](repeating: 0, count: rate / 2) + vowel(seconds: 0.15, pitch: 110, level: 0.1))),
            ("noisy room", mixed(vowel(seconds: 0.5, pitch: 130, level: 0.05), white(seconds: 0.5, level: 0.01))),
            ("room tone almost as loud as the voice", noisyVowel()),
            ("one word late in a long quiet segment", mixed(
                white(seconds: 25, level: 0.0005),
                [Float](repeating: 0, count: 159_000) + vowel(seconds: 0.25, pitch: 115, level: 0.08)
            )),
        ]
        for (label, audio) in voiced {
            assertTrue(WhisperVoicedSpeechGate.hasVoicedSpeech(audio), "\(label) must count as a voice")
        }
    }

    runSuite("Whisper's stock silence lines are dropped from audio with no voice") {
        let invented = [
            "Kiitos.", "Kiitos kun katsoit!", "Kiitos. Kiitos.", " kiitos ", "Thank you.", "you",
            "Thanks for watching!", "Subtitles by the Amara.org community", "...", "-", "*sigh*", "[Music]",
            "Продолжение следует...", "Gracias.", "Um...", "I", "",
        ]
        for text in invented {
            assertEqual(
                WhisperHallucinationFilter.keptWindowTexts([text], audioIsVoiced: false),
                [],
                "\"\(text)\" over silence must be dropped"
            )
        }
    }

    runSuite("Real words are kept: anything said out loud, and whispered sentences") {
        let stockLines = ["Kiitos.", "Kiitos kun katsoit!", "Thank you.", "so"]
        assertEqual(
            WhisperHallucinationFilter.keptWindowTexts(stockLines, audioIsVoiced: true),
            stockLines,
            "voiced audio keeps every line, including a real \"kiitos\""
        )
        let whispered = ["Kiitos, nähdään huomenna.", "Let's meet tomorrow.", "Kiitos. Soitan sinulle huomenna."]
        assertEqual(
            WhisperHallucinationFilter.keptWindowTexts(whispered, audioIsVoiced: false),
            whispered,
            "a whispered sentence with real words is kept even without a voice"
        )
    }

    runSuite("Only the invented windows of a long unvoiced segment are dropped") {
        assertEqual(
            WhisperHallucinationFilter.keptWindowTexts(["Kiitos.", "Palataan tähän ensi viikolla.", "Thank you."], audioIsVoiced: false),
            ["Palataan tähän ensi viikolla."]
        )
    }

    runSuite("A real kiitos in one decoder window does not admit kiitos over later silence") {
        var audio = [Float](repeating: 0, count: rate * 61)
        let word = vowel(seconds: 0.25, pitch: 130, level: 0.004)
        audio.replaceSubrange(1_000..<(1_000 + word.count), with: word)
        let windows: [WhisperHallucinationFilter.DecodedWindow] = [
            .init(text: "Kiitos.", seek: 0, start: 0, end: 30),
            .init(text: "Kiitos.", seek: rate * 30, start: 30, end: 60),
            .init(text: "Nähdään huomenna.", seek: rate * 60, start: 60, end: 61),
        ]
        let result = WhisperHallucinationFilter.filterWindows(windows, samples: audio)
        assertEqual(result.texts, ["Kiitos.", "Nähdään huomenna."])
        assertEqual(result.droppedWindows, 1)
        assertEqual(result.voicedWindows, 1)
        assertEqual(result.unvoicedWindows, 2)
    }

    runSuite("A quiet short word late in the final decoder window keeps its own stock text") {
        var audio = [Float](repeating: 0, count: rate * 31)
        let word = vowel(seconds: 0.15, pitch: 110, level: 0.004)
        let wordStart = rate * 30 + rate / 2
        audio.replaceSubrange(wordStart..<(wordStart + word.count), with: word)
        let result = WhisperHallucinationFilter.filterWindows([
            .init(text: "Thank you.", seek: 0, start: 0, end: 30),
            .init(text: "Kiitos.", seek: rate * 30, start: 30, end: 31),
        ], samples: audio)
        assertEqual(result.texts, ["Kiitos."])
        assertEqual(result.droppedWindows, 1)
        assertEqual(result.voicedWindows, 1)
    }

    runSuite("A short spoken stock word crossing a decoder boundary is retained") {
        var audio = [Float](repeating: 0, count: rate * 60)
        let word = vowel(seconds: 0.12, pitch: 120, level: 0.004)
        let wordStart = rate * 30 - word.count / 2
        audio.replaceSubrange(wordStart..<(wordStart + word.count), with: word)
        let result = WhisperHallucinationFilter.filterWindows([
            .init(text: "Kiitos.", seek: 0, start: 0, end: 30),
            .init(text: "Kiitos.", seek: rate * 30, start: 30, end: 60),
        ], samples: audio)
        assertEqual(result.texts, ["Kiitos.", "Kiitos."], "a window edge must not turn real speech into silence")
        assertEqual(result.droppedWindows, 0)
    }

    runSuite("Unchanged decoder results retain their exact full text and whitespace") {
        let audio = boostedAndPadded(vowel(seconds: 0.25, pitch: 120, level: 0.004))
        for text in ["こんにちは世界", "  first\nsecond\t", "Kiitos."] {
            let result = WhisperHallucinationFilter.filterResults([
                (text, [.init(text: "different window rendering", seek: 0, start: 0, end: 1)])
            ], samples: audio)
            assertEqual(result.texts, [text], "a no-op filter must not reconstruct the decoder's full text")
            assertEqual(result.droppedWindows, 0)
        }
    }

    runSuite("Only a decoder result that loses a stock window is reconstructed") {
        let audio = [Float](repeating: 0, count: rate * 31)
        let result = WhisperHallucinationFilter.filterResults([
            ("こんにちは世界", [
                .init(text: "こんにちは", seek: 0, start: 0, end: 30),
                .init(text: "世界", seek: rate * 30, start: 30, end: 31),
            ]),
            ("Kiitos. Nähdään huomenna.", [
                .init(text: "Kiitos.", seek: 0, start: 0, end: 30),
                .init(text: "Nähdään huomenna.", seek: rate * 30, start: 30, end: 31),
            ]),
        ], samples: audio)
        assertEqual(result.texts, ["こんにちは世界", "Nähdään huomenna."])
        assertEqual(result.droppedWindows, 1)
        assertEqual(result.voicedWindows, 0)
        assertEqual(result.unvoicedWindows, 4)
    }

    runSuite("Missing or invalid window timing preserves the original decoder result") {
        let original = "  こんにちは世界\n"
        let result = WhisperHallucinationFilter.filterResults([
            (original, []),
            (original, [.init(text: "Kiitos.", seek: -1, start: .nan, end: .nan)]),
        ], samples: [Float](repeating: 0, count: rate))
        assertEqual(result.texts, [original, original])
        assertEqual(result.droppedWindows, 0)
    }

    runSuite("Unknown or inconsistent decoder timing preserves words") {
        let unknown: [WhisperHallucinationFilter.DecodedWindow] = [
            .init(text: "Kiitos.", seek: -1, start: 0, end: 1),
            .init(text: "Kiitos.", seek: .max, start: 0, end: 1),
            .init(text: "Kiitos.", seek: rate, start: 1, end: 2),
            .init(text: "Kiitos.", seek: 0, start: .nan, end: 1),
            .init(text: "Kiitos.", seek: 0, start: 0, end: .infinity),
            .init(text: "Kiitos.", seek: 0, start: 0, end: 0),
            .init(text: "Kiitos.", seek: 0, start: 0.5, end: 1),
            .init(text: "Kiitos.", seek: 0, start: 0, end: 2),
            .init(text: "Kiitos.", seek: 0, start: 0, end: 0.5),
        ]
        let result = WhisperHallucinationFilter.filterWindows(unknown, samples: [Float](repeating: 0, count: rate))
        assertEqual(result.texts, unknown.map(\.text))
        assertEqual(result.droppedWindows, 0)
        let empty = WhisperHallucinationFilter.filterWindows(unknown, samples: [])
        assertEqual(empty.texts, unknown.map(\.text))
    }
}
