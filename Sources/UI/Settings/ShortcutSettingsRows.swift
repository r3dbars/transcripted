// ShortcutSettingsRows.swift
// General page shortcut rows: the one dictation key, its behavior, and the
// meeting shortcut. Each key row records a new
// shortcut in place (press the key you want) and has its own reset.

import AppKit
import Carbon
import SwiftUI

/// Which shortcut a key row records.
enum ShortcutRecordingTarget: CaseIterable {
    case dictation
    case meeting

    var name: String {
        switch self {
        case .dictation: return "Dictation key"
        case .meeting: return "Meetings"
        }
    }

    var binding: PhysicalDictationTriggerBinding {
        switch self {
        case .dictation: return PhysicalDictationTriggerPreferences.pushToTalkBinding()
        case .meeting: return PhysicalDictationTriggerPreferences.meetingBinding()
        }
    }

    var defaultBinding: PhysicalDictationTriggerBinding {
        switch self {
        case .dictation: return PhysicalDictationTriggerPreferences.defaultPushToTalkBinding
        case .meeting: return PhysicalDictationTriggerPreferences.defaultMeetingBinding
        }
    }

    func save(_ binding: PhysicalDictationTriggerBinding) {
        switch self {
        case .dictation: PhysicalDictationTriggerPreferences.savePushToTalk(binding)
        case .meeting: PhysicalDictationTriggerPreferences.saveMeeting(binding)
        }
    }
}

/// Records one shortcut at a time from the Settings window's own key
/// events. A modifier-only key (Fn, Right Option) saves on release, so a
/// chord that starts with it can still be recorded.
@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var recordingTarget: ShortcutRecordingTarget?
    /// Why the last chord was refused (`rejectionReason` or a duplicate).
    /// Shown under the row until an acceptable chord or Esc.
    @Published private(set) var rejectionHint: String?
    /// Bumped after a save so rows re-read the stored bindings.
    @Published private(set) var revision = 0

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var pendingModifier: PhysicalDictationTriggerBinding?
    private var pendingModifierKeyCode: UInt32?

    func displayText(for target: ShortcutRecordingTarget) -> String {
        recordingTarget == target
            ? "Press keys…"
            : PhysicalDictationTriggerPreferences.displayString(for: target.binding)
    }

    func isDefault(_ target: ShortcutRecordingTarget) -> Bool {
        target.binding == target.defaultBinding
    }

    func hint(for target: ShortcutRecordingTarget) -> String? {
        recordingTarget == target ? rejectionHint : nil
    }

    func toggleRecording(_ target: ShortcutRecordingTarget) {
        if recordingTarget == target {
            stopRecording()
        } else {
            startRecording(target)
        }
    }

    /// Resets one row. If its default is now taken by another shortcut, the
    /// row opens for recording with the reason instead of saving a duplicate.
    func reset(_ target: ShortcutRecordingTarget) {
        stopRecording()
        if let reason = duplicateReason(for: target.defaultBinding, target: target) {
            NSSound.beep()
            startRecording(target)
            rejectionHint = reason
            return
        }
        target.save(target.defaultBinding)
        revision &+= 1
    }

    func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        recordingTarget = nil
        rejectionHint = nil
        pendingModifier = nil
        pendingModifierKeyCode = nil
    }

    private func startRecording(_ target: ShortcutRecordingTarget) {
        stopRecording()
        recordingTarget = target

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording()
                return nil
            }

            self.pendingModifier = nil
            self.pendingModifierKeyCode = nil
            let candidate = PhysicalDictationTriggerPreferences.bindingForKeyDown(
                keyCode: UInt32(event.keyCode),
                modifierFlags: event.modifierFlags
            )
            // A bare typing key or a macOS-reserved ⌘ chord would be swallowed
            // system-wide by the event tap (a ⌘V paste-last binding turns every
            // paste on the Mac into Transcripted's popup). Refuse it, say why,
            // and keep listening for an acceptable chord.
            if let reason = PhysicalDictationTriggerPreferences.rejectionReason(for: candidate) {
                NSSound.beep()
                self.rejectionHint = reason
                return nil
            }
            self.saveIfFree(candidate, for: target)
            return nil
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let keyCode = UInt32(event.keyCode)
            let modifiers = PhysicalDictationTriggerPreferences.modifiers(from: event.modifierFlags)

            if let candidate = PhysicalDictationTriggerPreferences.bindingForFlagsChanged(
                keyCode: keyCode,
                modifierFlags: event.modifierFlags
            ) {
                if keyCode == UInt32(kVK_CapsLock) {
                    self.saveIfFree(candidate, for: target)
                    return nil
                }
                self.pendingModifier = candidate
                self.pendingModifierKeyCode = keyCode
                return nil
            }

            if let pending = self.pendingModifier,
               self.pendingModifierKeyCode == keyCode,
               PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(pending, keyCode: keyCode, modifiers: modifiers) {
                self.saveIfFree(pending, for: target)
                return nil
            }

            return event
        }
    }

    /// Saves unless another shortcut already uses it. Then it beeps, says
    /// which one, and keeps listening for a different key.
    private func saveIfFree(_ binding: PhysicalDictationTriggerBinding, for target: ShortcutRecordingTarget) {
        if let reason = duplicateReason(for: binding, target: target) {
            NSSound.beep()
            pendingModifier = nil
            pendingModifierKeyCode = nil
            rejectionHint = reason
            return
        }
        target.save(binding)
        stopRecording()
        revision &+= 1
    }

    /// The dictation key counts even while dictation shortcuts are off, so
    /// turning them back on can't bring a clash back.
    private func duplicateReason(for binding: PhysicalDictationTriggerBinding, target: ShortcutRecordingTarget) -> String? {
        let others = ShortcutRecordingTarget.allCases
            .filter { $0 != target }
            .map { (name: $0.name, binding: $0.binding) }
        return PhysicalDictationTriggerPreferences.duplicateReason(for: binding, otherShortcuts: others)
    }
}

/// A Settings row with a shortcut key on the right: click it, press the new
/// key, and it saves. The reset arrow shows only when it isn't the default.
struct ShortcutKeyRow<Footer: View>: View {
    let target: ShortcutRecordingTarget
    var info: GeneralInfo? = nil
    let automationIdentifier: String
    var showsDivider = true
    @ObservedObject var recorder: ShortcutRecorderModel
    @ViewBuilder var footer: Footer

    var body: some View {
        let isRecording = recorder.recordingTarget == target
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                GeneralTitleLabel(title: target.name, info: info)

                Spacer(minLength: 10)

                if !recorder.isDefault(target), !isRecording {
                    Button {
                        recorder.reset(target)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reset to \(PhysicalDictationTriggerPreferences.displayString(for: target.defaultBinding))")
                    .accessibilityLabel(Text("Reset \(target.name)"))
                }

                Button {
                    recorder.toggleRecording(target)
                } label: {
                    Text(recorder.displayText(for: target))
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .frame(minWidth: 72)
                }
                .controlSize(.regular)
                .tint(isRecording ? .orange : nil)
                .buttonStyle(.bordered)
                .help(isRecording ? "Press the new shortcut, or Esc to cancel." : "Click, then press a new shortcut.")
                .accessibilityLabel(Text(target.name))
                .accessibilityValue(Text(recorder.displayText(for: target)))
                .accessibilityIdentifier(automationIdentifier)
            }

            if let hint = recorder.hint(for: target) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            if showsDivider { Divider() }
        }
        .accessibilityElement(children: .contain)
    }
}

extension ShortcutKeyRow where Footer == EmptyView {
    init(
        target: ShortcutRecordingTarget,
        info: GeneralInfo? = nil,
        automationIdentifier: String,
        showsDivider: Bool = true,
        recorder: ShortcutRecorderModel
    ) {
        self.init(
            target: target,
            info: info,
            automationIdentifier: automationIdentifier,
            showsDivider: showsDivider,
            recorder: recorder
        ) { EmptyView() }
    }
}

/// Hold or tap / Hold only / Tap to toggle, with what the current choice
/// does spelled out under the title.
struct DictationKeyBehaviorRow: View {
    @Binding var behavior: DictationKeyBehavior

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                GeneralTitleLabel(
                    title: "Behavior",
                    info: GeneralInfo(
                        title: "Behavior",
                        message: "Hold or tap: hold the key to talk and let go to paste, or tap it to keep listening and tap again to paste. Hold only: records only while you hold it. Tap to toggle: every tap starts or stops."
                    )
                )
                Text(behavior.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Picker("Behavior", selection: $behavior) {
                ForEach(DictationKeyBehavior.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("transcripted.settings.general.dictation-key-behavior")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
