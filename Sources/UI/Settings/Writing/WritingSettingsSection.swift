import SwiftUI

/// The everyday view's settings: the two features, personalized
/// suggestions, the model switch, the storage meter and Delete all writing.
/// Replaces Tilde's settings window (`TildeSettingsWindowController`).
struct WritingSettingsSection: View {
    typealias Copy = WritingSetupPresentation

    @ObservedObject var model: WritingSettingsModel
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCardLabel(text: Copy.settingsLabel)
            SettingsCard {
                toggleRow(
                    title: Copy.Step1.saveTitle,
                    line: Copy.Step1.saveLine,
                    isOn: Binding(get: { model.saveMyWriting }, set: { model.setSaveMyWriting($0) }),
                    automationIdentifier: "transcripted.settings.writing.settings.save-my-writing"
                )
                toggleRow(
                    title: Copy.Step1.autocompleteTitle,
                    line: Copy.Step1.autocompleteLine,
                    isOn: Binding(get: { model.autocomplete }, set: { model.setAutocomplete($0) }),
                    automationIdentifier: "transcripted.settings.writing.settings.autocomplete"
                )
                toggleRow(
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.writing.settings")
    }

    private func toggleRow(
        title: String,
        line: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        automationIdentifier: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(line)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.accentColor)
                .disabled(!isEnabled)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(line))
                .accessibilityIdentifier(automationIdentifier)
        }
        .opacity(isEnabled ? 1 : 0.6)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Copy.Step3.modelTitle)
                .font(.subheadline.weight(.semibold))
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
                    .font(.subheadline.weight(.semibold))
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcripted.settings.writing.settings.storage")
    }

    private var deleteRow: some View {
        HStack(spacing: 12) {
            if model.deleteFailed {
                Text(Copy.deleteFailed)
                    .font(LibraryTokens.meta.weight(.semibold))
                    .foregroundStyle(LibraryTokens.attention)
            }
            Spacer()
            if model.isDeleting {
                ProgressView().controlSize(.small)
            }
            SettingsInlineActionButton(
                title: Copy.deleteAll,
                symbolName: "trash",
                tone: .destructive,
                automationIdentifier: "transcripted.settings.writing.delete-all"
            ) {
                confirmsDelete = true
            }
            .disabled(model.isDeleting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// Model, saved writing and learning data as one bar.
private struct WritingStorageMeter: View {
    let usage: WritingStorageUsage

    private static let colors: [Color] = [LibraryTokens.accent, LibraryTokens.dictationStream, LibraryTokens.meetingsStream]

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
