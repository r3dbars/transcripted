import SwiftUI
import TranscriptedCore

extension TranscriptedSettingsView {
    var modelsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Models",
                summary: "Choose the local engine used for transcription."
            )

            SettingsSection(
                title: "Active Model",
                detail: "Used for dictation, meetings, and audio imports."
            ) {
                SettingsStatusCard(
                    title: "Active transcription engine",
                    status: effectiveTranscriptionModel.title,
                    detail: activeModelDetail,
                    tone: .ready
                )

                let modelCard = FirstRunExperience.modelCard(
                    for: FirstRunLocalModelState(sttRouter.modelDownloadState),
                    model: effectiveTranscriptionModel
                )
                SettingsStatusCard(
                    title: "Model files",
                    status: modelCard.status,
                    detail: modelCard.detail,
                    tone: tone(for: modelCard.tone),
                    progress: modelCard.progress,
                    actionTitle: modelDownloadActionTitle,
                    action: modelDownloadAction
                )
            }

            SettingsSection(
                title: "Switch Model",
                detail: "Parakeet is the default. Whisper is optional."
            ) {
                DisclosureGroup("Change model", isExpanded: $showAdvancedModelControls) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Preferred model", selection: Binding(
                            get: { preferredTranscriptionModel },
                            set: { newValue in
                                updatePreferredTranscriptionModel(newValue)
                            }
                        )) {
                            ForEach(TranscriptionModelChoice.allCases) { model in
                                Text(model.title).tag(model)
                            }
                        }
                        .pickerStyle(.menu)

                        ForEach(TranscriptionModelChoice.allCases) { model in
                            ModelChoiceRow(
                                model: model,
                                isPreferred: preferredTranscriptionModel == model,
                                isEffective: effectiveTranscriptionModel == model
                            )
                        }

                        HStack {
                            SettingsInlineActionButton(title: "Use Parakeet", tone: .accent) {
                                updatePreferredTranscriptionModel(.parakeetTDTv3)
                            }
                            .disabled(preferredTranscriptionModel == .parakeetTDTv3)
                            .help(preferredTranscriptionModel == .parakeetTDTv3
                                ? "Parakeet is already the selected transcription model."
                                : "")

                            Text("Changes apply to the next capture.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .accessibilityIdentifier("transcripted.settings.page.general")
    }
}
