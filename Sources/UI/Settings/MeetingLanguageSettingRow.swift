import SwiftUI

/// A durable meeting/import preference, kept separate from dictation settings.
struct MeetingLanguageSettingRow: View {
    let model: TranscriptionModelChoice
    /// Apple Speech's in-flight or failed download of a meeting language.
    var appleLanguageDownload: AppleSpeechLanguageDownload? = nil
    /// Called after the saved language changes, so Apple Speech can start
    /// downloading it now rather than inside the next meeting.
    var onLanguageChange: () -> Void = {}

    @AppStorage(TranscriptionLanguagePreferences.preferenceKey)
    private var storedLanguageCode = TranscriptionLanguagePreferences.automaticValue

    /// Languages Apple Speech can transcribe on this Mac. nil until loaded.
    @State private var appleSupportedLanguageCodes: Set<String>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsControlRow(
                title: "Meeting language",
                info: GeneralInfo(
                    title: "Meeting language",
                    message: "Applies to new meetings and imported files, not dictation. With Whisper, Auto checks speech from across the recording and keeps a language when the checks confidently agree. Mixed or uncertain speech stays automatic. With Apple Speech, Auto uses your Mac's language. Choose a language when you know which will be spoken. Captures keep the choice they started with."
                ),
                automationIdentifier: "transcripted.settings.general.meeting-language",
                showsDivider: false
            ) {
                Picker("Meeting language", selection: languageSelection) {
                    Text("Auto").tag(TranscriptionLanguagePreferences.automaticValue)
                    if model.supportsMeetingLanguageChoice {
                        ForEach(pickerLanguages) { language in
                            Text(language.title).tag(language.code)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("transcripted.settings.general.meeting-language.picker")
                .help("Language for new meetings and imported files. Does not change dictation.")
            }

            if let caption = captionLines, !caption.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(caption, id: \.self) { line in
                        Text(line)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            Divider()
        }
        .task(id: model) {
            // Refetch until macOS returns a real list: an empty answer can be
            // temporary, and caching it would leave "isn't available" stuck.
            guard model.isAppleSpeech, appleSupportedLanguageCodes?.isEmpty != false else { return }
            guard AppleSpeechEngine.isAvailable else {
                appleSupportedLanguageCodes = []
                return
            }
            let codes = await AppleSpeechEngine.supportedLanguageCodes()
            appleSupportedLanguageCodes = codes.isEmpty ? nil : codes
        }
    }

    private var preferredLanguageCode: String {
        TranscriptionLanguagePreferences.normalizedLanguageCode(storedLanguageCode)
    }

    /// Apple Speech covers fewer languages than Whisper, so its list is
    /// filtered to what macOS reports. The saved choice always stays listed so
    /// the picker never shows a blank selection.
    private var pickerLanguages: [TranscriptionLanguageChoice] {
        let all = TranscriptionLanguagePreferences.supportedLanguages
        guard model.isAppleSpeech, let supported = appleSupportedLanguageCodes else { return all }
        return all.filter { language in
            language.code == preferredLanguageCode
                || supported.contains(AppleSpeechLocalePolicy.normalizedLanguageCode(language.code))
        }
    }

    private var captionLines: [String]? {
        if model.isAppleSpeech {
            var lines: [String] = []
            if preferredLanguageCode == TranscriptionLanguagePreferences.automaticValue {
                let macLanguage = AppleSpeechEngine.macLanguageCode
                lines.append("Auto uses your Mac's language (\(AppleSpeechEngine.languageDisplayName(for: macLanguage))).")
                if let supported = appleSupportedLanguageCodes, !supported.isEmpty,
                   !supported.contains(AppleSpeechLocalePolicy.normalizedLanguageCode(macLanguage)) {
                    lines.append("Apple Speech can't transcribe that language. Choose a meeting language here.")
                }
            } else if let supported = appleSupportedLanguageCodes, !supported.isEmpty,
                      !supported.contains(AppleSpeechLocalePolicy.normalizedLanguageCode(preferredLanguageCode)) {
                lines.append("Apple Speech can't transcribe \(TranscriptionLanguagePreferences.displayName(for: preferredLanguageCode)). Choose another language or model.")
            }
            if appleSupportedLanguageCodes?.isEmpty == true {
                lines.append("Apple Speech isn't available on this Mac. Choose another model.")
            } else if let download = appleLanguageDownload {
                let name = AppleSpeechEngine.languageDisplayName(for: download.languageCode)
                switch download.phase {
                case .downloading(let progress):
                    let percent = Int((min(max(progress, 0), 1) * 100).rounded())
                    lines.append("Downloading \(name) from Apple… \(percent)%")
                case .failed:
                    lines.append("Couldn't download \(name) from Apple. Check your internet connection. It'll try again when a meeting needs it.")
                }
            } else {
                lines.append("macOS downloads each language from Apple the first time you use it.")
            }
            return lines
        }

        guard !model.isWhisper else { return nil }
        var lines = [
            model == .parakeetTDTv2
                ? "Choose Whisper or Apple Speech to set a language. Parakeet V2 transcribes in English only."
                : "Choose Whisper or Apple Speech to set a language. Parakeet detects languages automatically."
        ]
        if preferredLanguageCode != TranscriptionLanguagePreferences.automaticValue {
            lines.append("\(TranscriptionLanguagePreferences.displayName(for: preferredLanguageCode)) is saved for Whisper and Apple Speech.")
        }
        return lines
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: {
                TranscriptionLanguagePreferences.effectiveLanguageCode(
                    for: model,
                    preferredLanguageCode: storedLanguageCode
                )
            },
            set: { value in
                guard TranscriptionLanguagePreferences.isSupportedPreference(value),
                      model.supportsMeetingLanguageChoice || value == TranscriptionLanguagePreferences.automaticValue else { return }
                storedLanguageCode = value
                onLanguageChange()
            }
        )
    }
}
