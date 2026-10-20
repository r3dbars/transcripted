import SwiftUI

/// Settings › Developer Preview: a row per feature in `DeveloperPreview.all`, each tagged, with what it
/// does and sends in its ⓘ popover. Turning one on asks first, because these can do what the rest of
/// Transcripted never does, like send text to Claude.
struct DeveloperPreviewSettingsRows: View {
    @State private var on: [String: Bool] = Dictionary(uniqueKeysWithValues: DeveloperPreview.all.map { ($0.id, DeveloperPreview.isOn($0)) })
    @State private var asking: DeveloperPreviewFeature?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(DeveloperPreview.all.enumerated()), id: \.element.id) { index, feature in
                DeveloperPreviewRow(feature: feature, isOn: binding(for: feature), showsDivider: index < DeveloperPreview.all.count - 1)
            }
        }
        .alert(asking?.consentTitle ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
               presenting: asking) { feature in
            Button("Turn On") {
                DeveloperPreview.set(feature, on: true)
                on[feature.id] = true
            }
            Button("Cancel", role: .cancel) {}
        } message: { feature in
            Text(feature.consent)
        }
    }

    private func binding(for feature: DeveloperPreviewFeature) -> Binding<Bool> {
        Binding(
            get: { on[feature.id] ?? false },
            set: { newValue in
                if newValue {
                    asking = feature
                } else {
                    DeveloperPreview.set(feature, on: false)
                    on[feature.id] = false
                }
            }
        )
    }
}

private struct DeveloperPreviewRow: View {
    let feature: DeveloperPreviewFeature
    @Binding var isOn: Bool
    let showsDivider: Bool

    var body: some View {
        HStack(spacing: 8) {
            GeneralTitleLabel(title: feature.title, info: GeneralInfo(title: feature.title, message: feature.details))
            DeveloperPreviewTag()
            Spacer(minLength: 10)
            Toggle(feature.title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .tint(.accentColor)
                .accessibilityLabel(Text("\(feature.title), Developer Preview"))
                .accessibilityValue(Text(isOn ? "On" : "Off"))
                .accessibilityIdentifier("transcripted.settings.developer-preview.\(feature.id)")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            if showsDivider { Divider() }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The small tag on every Developer Preview row.
struct DeveloperPreviewTag: View {
    var body: some View {
        Text("Developer Preview")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.14)))
            .fixedSize()
            .accessibilityHidden(true)
    }
}
