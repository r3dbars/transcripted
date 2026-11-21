import SwiftUI

/// The everyday view's settings: the two features, personalized
/// suggestions, the model switch (setup picks the smaller model without
/// asking; this is where the other one is), Write for Me's sounds while
/// Write for Me is on, the storage meter with Delete model, and Delete all
/// writing. Deletes are ink buttons; their confirm is the red step.
/// Replaces Tilde's settings window (`TildeSettingsWindowController`).
struct WritingSettingsSection: View {
    typealias Copy = WritingSetupPresentation

    @ObservedObject var model: WritingSettingsModel
    @State private var confirmsDelete = false
    @State private var confirmsDeleteModel = false
    /// Write for Me is a Developer Preview; its switch lives in Settings ›
    /// Developer Preview. The sounds row shows here only while it's on.
    @AppStorage(NextSentencePreferences.enabledKey) private var writeForMeEnabled = false
    /// Same preference as Settings › Advanced. On unless set off.
    @AppStorage(NextSentencePreferences.soundsKey) private var writeForMeSounds = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCardLabel(text: Copy.settingsLabel)
            SettingsCard {
                WritingToggleRow(
                    title: Copy.Step1.saveTitle,
                    line: Copy.Step1.saveLine,
                    isOn: Binding(get: { model.saveMyWriting }, set: { model.setSaveMyWriting($0) }),
                    automationIdentifier: "transcripted.settings.writing.settings.save-my-writing"
                )
                WritingToggleRow(
                    title: Copy.Step1.autocompleteTitle,
                    line: Copy.Step1.autocompleteLine,
                    isOn: Binding(get: { model.autocomplete }, set: { model.setAutocomplete($0) }),
                    isEnabled: !model.isDeleting,
                    automationIdentifier: "transcripted.settings.writing.settings.autocomplete"
                )
                WritingToggleRow(
                    title: Copy.personalizedTitle,
                    line: model.saveMyWriting ? Copy.personalizedLine : Copy.personalizedNeedsSave,
                    isOn: Binding(
                        get: { model.personalizedSuggestions },
                        set: { model.setPersonalizedSuggestions($0) }
                    ),
                    isEnabled: model.saveMyWriting && model.autocomplete,
                    automationIdentifier: "transcripted.settings.writing.settings.personalized"
                )
                if model.autocomplete {
                    modelRow
                }
                if writeForMeEnabled {
                    WritingToggleRow(
                        title: Copy.WriteForMeSounds.title,
                        line: writeForMeSounds ? Copy.WriteForMeSounds.onLine : Copy.WriteForMeSounds.offLine,
                        isOn: $writeForMeSounds,
                        automationIdentifier: "transcripted.settings.writing.settings.write-for-me-sounds"
                    )
                }
                storageRow
                deleteRow
            }
        }
        .confirmationDialog(
            Copy.deleteConfirmTitle,
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button(Copy.deleteAll, role: .destructive) {
                model.deleteAllWriting()
            }
            .accessibilityIdentifier("transcripted.settings.writing.delete-all.confirm")
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.deleteConfirmMessage)
        }
        .confirmationDialog(
            Copy.deleteModelConfirmTitle,
            isPresented: $confirmsDeleteModel,
            titleVisibility: .visible
        ) {
            Button(Copy.deleteModel, role: .destructive) {
                model.deleteModel()
            }
            .accessibilityIdentifier("transcripted.settings.writing.delete-model.confirm")
            Button(Copy.cancel, role: .cancel) {}
        } message: {
            Text(Copy.deleteModelConfirmMessage(
                autocompleteOn: model.autocomplete,
                modelBytes: model.storage?.modelBytes ?? 0
            ))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.writing.settings")
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Copy.Step2.modelTitle)
                .font(LibraryTokens.rowTitle)
            ForEach(Copy.modelOptions, id: \.name) { option in
                let eligible = option.choice == .gemma4E2B || model.isQwenEligible
                WritingChoiceRow(
                    title: option.name,
                    detail: option.detail,
                    tag: option.isDefault ? Copy.defaultTag : nil,
                    disabledLine: Copy.ineligibleLine(for: option.choice, isEligible: eligible),
                    isSelected: model.selectedModel == option.choice,
                    isEnabled: eligible,
                    automationIdentifier: "transcripted.settings.writing.settings.model.\(option.choice == .gemma4E2B ? "gemma" : "qwen")"
                ) {
                    model.selectModel(option.choice)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.writing.settings.model")
    }

    private var storageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Copy.storageTitle)
                    .font(LibraryTokens.rowTitle)
                Spacer()
                Text(model.storage?.summary ?? "")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .monospacedDigit()
            }
            if let usage = model.storage, usage.totalBytes > 0 {
                WritingStorageMeter(usage: usage)
                Text(usage.legend)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .monospacedDigit()
            }
            if let usage = model.storage, usage.modelBytes > 0 || model.deleteModelFailed {
                deleteModelRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.writing.settings.storage")
    }

    private var deleteModelRow: some View {
        HStack(spacing: 12) {
            if model.deleteModelFailed {
                Text(Copy.deleteModelFailed)
                    .font(LibraryTokens.meta.weight(.semibold))
                    .foregroundStyle(LibraryTokens.attention)
            }
            Spacer()
            if model.isDeletingModel {
                ProgressView().controlSize(.small)
            }
            Button {
                confirmsDeleteModel = true
            } label: {
                Label(Copy.deleteModel, systemImage: "trash")
            }
            .buttonStyle(.transcriptedSecondary)
            .controlSize(.small)
            .disabled(model.isDeleting)
            .accessibilityIdentifier("transcripted.settings.writing.delete-model")
        }
    }

    private var deleteRow: some View {
        HStack(spacing: 12) {
            if model.deleteFailed {
                Text(Copy.deleteFailed)
                    .font(LibraryTokens.meta.weight(.semibold))
                    .foregroundStyle(LibraryTokens.attention)
            }
            Spacer()
            if model.isDeleting, !model.isDeletingModel {
                ProgressView().controlSize(.small)
            }
            Button {
                confirmsDelete = true
            } label: {
                Label(Copy.deleteAll, systemImage: "trash")
            }
            .buttonStyle(.transcriptedSecondary)
            .controlSize(.small)
            .disabled(model.isDeleting)
            .accessibilityIdentifier("transcripted.settings.writing.delete-all")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// Model, saved writing and learning data as one bar.
private struct WritingStorageMeter: View {
    let usage: WritingStorageUsage

    private static let colors: [Color] = [LibraryTokens.ink, LibraryTokens.ink2, LibraryTokens.ink3]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(usage.segments.enumerated()), id: \.offset) { index, segment in
                    if segment.bytes > 0 {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Self.colors[index % Self.colors.count])
                            .frame(width: max(3, geometry.size.width * segment.fraction))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6)
        .background(Capsule().fill(LibraryTokens.raisedFill))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}
