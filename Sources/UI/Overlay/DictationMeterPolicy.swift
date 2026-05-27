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
}
