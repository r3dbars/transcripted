enum TranscriptedModelInfo {
    static let speechToTextName = "Parakeet TDT 0.6B V3"
    static let speechToTextSummary =
        "Transcripted currently uses \(speechToTextName) for dictation and meeting transcripts."
    static let speechToTextLanguageSummary =
        "Supports 25 European languages with automatic language detection, including Swedish."
    static let meetingModelSummary =
        "Meetings also load local speaker models for diarization: Sortformer, PyAnnote, and WeSpeaker."
    static let downloadHostSummary =
        "If bundled models are missing, Transcripted may connect to huggingface.co or hf-mirror.com once to download local model files."
    static let downloadSummary =
        "\(downloadHostSummary) After that, transcription stays on this Mac."
    static let secureConnectionSummary =
        "A secure connection error during setup means the one-time local model download failed. It does not mean Transcripted is sending your audio or transcript text to an online speech API."
    static let pickerSummary =
        "Transcripted does not offer a model picker or custom model import yet."
}
