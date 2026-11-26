import SwiftUI

/// A durable meeting/import preference, kept separate from dictation settings.
struct MeetingLanguageSettingRow: View {
    let model: TranscriptionModelChoice

    @AppStorage(TranscriptionLanguagePreferences.preferenceKey)
    private var storedLanguageCode = TranscriptionLanguagePreferences.automaticValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsControlRow(
                title: "Meeting language",
                info: GeneralInfo(
                    title: "Meeting language",
                    message: "Applies to new meetings and imported files, not dictation. With Whisper, Auto checks speech from across the recording and keeps a language when the checks confidently agree. Mixed or uncertain speech stays automatic. Choose a language when you know which will be spoken. Captures keep the choice they started with."
                ),
                automationIdentifier: "transcripted.settings.general.meeting-language",
                showsDivider: false
            ) {
                Picker("Meeting language", selection: languageSelection) {
                    Text("Auto").tag(TranscriptionLanguagePreferences.automaticValue)
                    if model.supportsMeetingLanguageChoice {
                        ForEach(TranscriptionLanguagePreferences.supportedLanguages) { language in
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
    }

    private var preferredLanguageCode: String {
        TranscriptionLanguagePreferences.normalizedLanguageCode(storedLanguageCode)
    }

    private var captionLines: [String]? {
        guard !model.isWhisper else { return nil }
        var lines = [
            "Choose Whisper to set a language. Parakeet detects languages automatically."
        ]
        if preferredLanguageCode != TranscriptionLanguagePreferences.automaticValue {
            lines.append("\(TranscriptionLanguagePreferences.displayName(for: preferredLanguageCode)) is saved for Whisper.")
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
            }
        )
    }
}
