import AppKit
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
                let showsKey = feature == DeveloperPreview.nextSentence && on[feature.id] == true
                DeveloperPreviewRow(feature: feature, isOn: binding(for: feature), showsDivider: showsKey || index < DeveloperPreview.all.count - 1)
                if showsKey {
                    WriteForMeKeyRow(showsDivider: index < DeveloperPreview.all.count - 1)
                }
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

/// Which key opens Write for Me, shown once it's on: a few quick choices, or Record… to press any other
/// modifier key (either side) or function key. It says so when dictation already uses the same key.
private struct WriteForMeKeyRow: View {
    let showsDivider: Bool
    @State private var key = NextSentencePreferences.hotkey()
    @State private var recording = false
    @State private var rejected = false
    @State private var monitor: Any?

    private var choices: [NextSentenceHotkey] {
        NextSentenceHotkey.presets.contains(key) ? NextSentenceHotkey.presets : NextSentenceHotkey.presets + [key]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                GeneralTitleLabel(title: "Write for Me key", info: GeneralInfo(
                    title: "Write for Me key",
                    message: "Tap it in any text box to open Write for Me, or hold it and say what the message should say. "
                        + "Only the key on its own counts: pressed with another key, it does what it always does. "
                        + "Record… takes any modifier key, left or right, or an F key (on a MacBook, F keys work when "
                        + "they're set to act as standard function keys)."
                ))
                Spacer(minLength: 10)
                if recording {
                    Text(rejected ? "Use a modifier or an F key" : "Press a key…")
                        .font(.subheadline)
                        .foregroundStyle(rejected ? Color.orange : Color.secondary)
                    Button("Cancel") { stopRecording() }
                } else {
                    Picker("Write for Me key", selection: Binding(get: { key }, set: { choose($0) })) {
                        ForEach(choices, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityIdentifier("transcripted.settings.developer-preview.next-sentence.key")
                    Button("Record…") { startRecording() }
                        .accessibilityIdentifier("transcripted.settings.developer-preview.next-sentence.record-key")
                }
            }
            if NextSentencePreferences.hotkeyClashesWithDictation(key) {
                Text("Dictation uses this key too. Pick another one here, or change the dictation key above.")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            if showsDivider { Divider() }
        }
        .accessibilityElement(children: .contain)
        .onDisappear { stopRecording() }
    }

    private func choose(_ newKey: NextSentenceHotkey) {
        key = newKey
        NextSentencePreferences.setHotkey(newKey)
    }

    /// The next key pressed in this window becomes the key; Esc cancels.
    private func startRecording() {
        stopRecording()
        recording = true
        rejected = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let isFlags = event.type == .flagsChanged
            let code = Int64(event.keyCode)
            let flags = UInt64(event.modifierFlags.rawValue)
            let swallow = MainActor.assumeIsolated { recorded(isFlags: isFlags, code: code, flags: flags) }
            return swallow ? nil : event
        }
    }

    /// Returns whether the press was used up by recording.
    private func recorded(isFlags: Bool, code: Int64, flags: UInt64) -> Bool {
        if !isFlags && code == 53 {
            stopRecording()
            return true
        }
        guard let candidate = NextSentenceHotkey(recorded: code) else {
            if !isFlags { rejected = true }
            return !isFlags
        }
        if isFlags {
            // A modifier counts when it goes down, not when it's let go.
            guard let mask = candidate.downMask, flags & mask != 0 else { return false }
        } else if candidate.isModifier {
            return false
        }
        choose(candidate)
        stopRecording()
        return true
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
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
