enum DictationMeterPolicy {
    struct Presentation: Equatable {
        let isVisible: Bool
        let level: Float
    }

    static func presentation(
        isListening: Bool,
        sttIsRecording: Bool,
        rawLevel: Float,
        showsQuietStartupWaveform: Bool = false
    ) -> Presentation {
        if showsQuietStartupWaveform {
            return Presentation(isVisible: true, level: 0)
        }

        guard isListening, sttIsRecording else {
            return Presentation(isVisible: false, level: 0)
        }

        return Presentation(
            isVisible: true,
            level: max(0, min(1, rawLevel))
        )
    }

    /// The same rule for a whole meter reading: silent unless listening and
    /// recording, otherwise the level and peak clamped to 0...1, the peak
    /// never below the level.
    static func presentation(
        isListening: Bool,
        sttIsRecording: Bool,
        reading: DictationAudioLevel
    ) -> DictationAudioLevel {
        let shown = presentation(isListening: isListening, sttIsRecording: sttIsRecording, rawLevel: reading.level)
        guard shown.isVisible else { return .silent }
        return DictationAudioLevel(level: shown.level, peak: max(0, min(1, reading.peak)))
    }
}
