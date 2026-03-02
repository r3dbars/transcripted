// HotkeyRecorderView.swift
// Compact two-row keyboard shortcut recorder for the settings popover.

import SwiftUI
import Carbon

struct HotkeyRecorderView: View {
    @ObservedObject var captureEngine: ContextCaptureEngine

    /// Which shortcut is currently being recorded (nil = not recording)
    @State private var recordingTarget: RecordingTarget? = nil
    @State private var keyMonitor: Any? = nil

    enum RecordingTarget {
        case draft
        case dictation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            shortcutRow(
                label: "Draft",
                binding: HotkeyPreferences.draftBinding(),
                defaultBinding: HotkeyPreferences.defaultDraft,
                target: .draft
            )
            shortcutRow(
                label: "Dictation",
                binding: HotkeyPreferences.dictationBinding(),
                defaultBinding: HotkeyPreferences.defaultDictation,
                target: .dictation
            )

            Button("Reset to Defaults") {
                stopRecording()
                HotkeyPreferences.resetToDefaults()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
        }
        .onDisappear {
            stopRecording()
        }
    }

    @ViewBuilder
    private func shortcutRow(
        label: String,
        binding: HotkeyBinding,
        defaultBinding: HotkeyBinding,
        target: RecordingTarget
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 60, alignment: .leading)

            // Shortcut display / recording button
            Button(action: { startRecording(target) }) {
                Text(isRecording(target) ? "Press shortcut..." : HotkeyPreferences.displayString(for: binding))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 110)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isRecording(target) ? Color.accentColor.opacity(0.12) : Color(.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isRecording(target) ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            // Per-row reset button (only show if not default)
            if binding != defaultBinding {
                Button(action: {
                    stopRecording()
                    switch target {
                    case .draft: HotkeyPreferences.save(draft: defaultBinding)
                    case .dictation: HotkeyPreferences.save(dictation: defaultBinding)
                    }
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }
        }
    }

    private func isRecording(_ target: RecordingTarget) -> Bool {
        switch (recordingTarget, target) {
        case (.draft, .draft), (.dictation, .dictation): return true
        default: return false
        }
    }

    private func startRecording(_ target: RecordingTarget) {
        // Cancel any existing recording first
        stopRecording()
        recordingTarget = target

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode

            // Escape cancels recording
            if code == UInt16(kVK_Escape) {
                stopRecording()
                return nil  // Consume the event
            }

            let carbonMods = HotkeyPreferences.carbonModifiers(from: event.modifierFlags)
            let candidate = HotkeyBinding(keyCode: UInt32(code), modifiers: carbonMods)

            guard HotkeyPreferences.isValid(candidate) else {
                return nil  // Invalid — consume but don't save
            }

            // Save the new binding
            switch target {
            case .draft: HotkeyPreferences.save(draft: candidate)
            case .dictation: HotkeyPreferences.save(dictation: candidate)
            }
            stopRecording()
            return nil  // Consume the event
        }
    }

    private func stopRecording() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        recordingTarget = nil
    }
}
