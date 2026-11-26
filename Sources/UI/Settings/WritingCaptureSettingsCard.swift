import AppKit
import SwiftUI

/// Calm, opt-in writing capture card on the Agent page. Off by default.
/// Lets users opt into capturing what they type as local Markdown day files so
/// connected AI agents can search meetings, dictations, and writing together —
/// with zero model download and zero Screen Recording permission.
struct WritingCaptureSettingsCard: View {
    @ObservedObject private var model: WritingCaptureCardModel
    @State private var showPickedApps = false
    @State private var confirmDeleteAll = false

    init(controller: WritingController) {
        _model = ObservedObject(wrappedValue: WritingCaptureCardModel.shared(for: controller))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Capture my writing")
                        .textRole(.heading)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusText)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                    }
                }
                Spacer(minLength: 12)
                if model.isRunning {
                    if model.isPaused {
                        SettingsInlineActionButton(
                            title: "Resume",
                            symbolName: "play.fill",
                            automationIdentifier: "transcripted.settings.agent.writing-capture.resume"
                        ) {
                            model.resumeCapture()
                        }
                        .disabled(model.isDeleting)
                    } else {
                        SettingsInlineActionButton(
                            title: "Pause 1 hour",
                            symbolName: "pause.fill",
                            automationIdentifier: "transcripted.settings.agent.writing-capture.pause"
                        ) {
                            model.pauseForOneHour()
                        }
                        .disabled(model.isDeleting)
                    }
                }
            }

            Text("Save what you type as local Markdown so your AI can search your meetings, dictations, and writing together. Password managers and secure fields are never captured, and secrets are scrubbed before saving.")
                .font(LibraryTokens.body)
                .foregroundStyle(LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)

            SettingsCard {
                SettingsControlRow(
                    title: "Capture writing for AI context",
                    info: GeneralInfo(
                        title: "Capture writing for AI context",
                        message: "Off by default. Saves typed text into local Markdown day files in your capture folder using a lightweight macOS input source. Saved locally on this Mac until an AI agent you connect reads it — no model download or Screen Recording permission is needed."
                    ),
                    automationIdentifier: "transcripted.settings.agent.writing-capture.toggle",
                    showsDivider: model.isEnabled
                ) {
                    Toggle("Capture writing for AI context", isOn: Binding(
                        get: { model.isEnabled },
                        set: { model.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.isDeleting)
                }

                if model.isEnabled {
                    keyboardRow
                    appScopeRow
                }
            }

            if model.isEnabled && model.scopeMode == .picked && showPickedApps {
                pickedAppsList
            }

            if model.isEnabled && !model.isRunning {
                Label(
                    model.startFailed
                        ? "Writing capture couldn't start. Another copy of Transcripted may already be running."
                        : "Writing capture isn't running yet.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.attention)
                .fixedSize(horizontal: false, vertical: true)
            }

            if model.saveProblem {
                Label(
                    "Writing couldn't be saved to this folder. Check that your capture folder is writable.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.attention)
                .fixedSize(horizontal: false, vertical: true)
            }

            if model.deleteFailed {
                Label(
                    "Some saved writing files couldn't be deleted. Try again or check the writing folder.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.attention)
                .fixedSize(horizontal: false, vertical: true)
            }

            if model.isEnabled || model.savedBytes > 0 {
                HStack(alignment: .center, spacing: 10) {
                    Text(model.savedSummary)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)

                    Spacer(minLength: 8)

                    if model.savedBytes > 0 {
                        SettingsInlineActionButton(
                            title: "Open folder",
                            symbolName: "folder",
                            automationIdentifier: "transcripted.settings.agent.writing-capture.open-folder"
                        ) {
                            let url = model.writingFolderURL
                            let target = FileManager.default.fileExists(atPath: url.path)
                                ? url
                                : url.deletingLastPathComponent()
                            NSWorkspace.shared.activateFileViewerSelecting([target])
                        }

                        SettingsInlineActionButton(
                            title: model.isDeleting ? "Deleting…" : "Delete all saved writing",
                            tone: .destructive,
                            automationIdentifier: "transcripted.settings.agent.writing-capture.delete-all"
                        ) {
                            confirmDeleteAll = true
                        }
                        .disabled(model.isDeleting)
                    }
                }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.agent.writing-capture.card")
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .alert("Delete all saved writing?", isPresented: $confirmDeleteAll) {
            Button("Delete all", role: .destructive) {
                model.deleteAllSavedWriting()
            }
            .accessibilityIdentifier("transcripted.settings.agent.writing-capture.delete-all.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every Writing day file in your capture folder and turns writing capture off. Meetings and dictations stay.")
        }
    }

    private var keyboardRow: some View {
        SettingsControlRow(
            title: "Capture keyboard",
            info: GeneralInfo(
                title: "Capture keyboard",
                message: "macOS lets apps capture typed text through an Input Source. Add \"Transcripted\" under Keyboard > Text Input > Edit… and select it from the menu bar."
            ),
            automationIdentifier: "transcripted.settings.agent.writing-capture.keyboard"
        ) {
            HStack(spacing: 8) {
                switch model.keyboardStatus {
                case .checking:
                    ProgressView().controlSize(.small)
                case .ready:
                    Label("Active", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                case .enabledNotSelected:
                    Text("Select Transcripted in Input Sources")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.attention)
                    SettingsInlineActionButton(title: "Select") {
                        model.openKeyboardSettings()
                    }
                case .needsUserToAdd:
                    Text("Add in Keyboard settings")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.attention)
                    SettingsInlineActionButton(title: "Open Keyboard Settings") {
                        model.openKeyboardSettings()
                    }
                case .needsRelogin:
                    Text("Log out & back in, then add in Keyboard settings")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.attention)
                    SettingsInlineActionButton(title: "Open Keyboard Settings") {
                        model.openKeyboardSettings()
                    }
                }
            }
        }
    }

    private var appScopeRow: some View {
        SettingsControlRow(
            title: "Apps to capture",
            info: GeneralInfo(
                title: "Apps to capture",
                message: "Capture typing in every app (except password managers) or only the apps you pick."
            ),
            automationIdentifier: "transcripted.settings.agent.writing-capture.scope",
            showsDivider: false
        ) {
            HStack(spacing: 8) {
                Picker("Apps to capture", selection: Binding(
                    get: { model.scopeMode },
                    set: { newMode in
                        model.setScopeMode(newMode)
                        if newMode == .picked { showPickedApps = true }
                    }
                )) {
                    Text("All apps").tag(WritingCaptureCardModel.ScopeMode.all)
                    Text("Picked apps").tag(WritingCaptureCardModel.ScopeMode.picked)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                if model.scopeMode == .picked {
                    SettingsInlineActionButton(
                        title: showPickedApps
                            ? "Hide apps"
                            : "Choose apps (\(model.pickedBundleIdentifiers.count))"
                    ) {
                        showPickedApps.toggle()
                    }
                }
            }
        }
    }

    private var pickedAppsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.appChoices.isEmpty {
                Text("Loading installed apps…")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.appChoices) { app in
                            let selected = model.pickedBundleIdentifiers.contains(app.bundleIdentifier)
                            Button {
                                model.togglePickedApp(app.bundleIdentifier)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selected ? LibraryTokens.accent : LibraryTokens.ink2)
                                    Text(app.name)
                                        .font(LibraryTokens.body)
                                        .foregroundStyle(LibraryTokens.ink)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(12)
        .background(LibraryTokens.raisedFill, in: RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised))
    }

    private var statusText: String {
        if !model.isEnabled { return "Off · opt in to include writing in your AI context" }
        if !model.isRunning {
            return model.startFailed
                ? "Error · capture listener couldn't start"
                : "Off · capture listener isn't running"
        }
        if model.isPaused {
            if let resumeTime = model.pauseResumeTimeText {
                return "Paused · resumes at \(resumeTime)"
            }
            return "Paused · typing isn't being saved"
        }
        if model.saveProblem { return "Needs attention · folder unavailable" }
        switch model.keyboardStatus {
        case .ready: return "On · saving local Markdown day files"
        case .checking: return "On · checking keyboard"
        case .enabledNotSelected: return "On · select Transcripted in Input Sources"
        case .needsUserToAdd: return "On · add Transcripted in Keyboard settings"
        case .needsRelogin: return "On · log out and back in to enable keyboard"
        }
    }

    private var statusColor: Color {
        if !model.isEnabled { return LibraryTokens.ink2 }
        if !model.isRunning { return LibraryTokens.attention }
        if model.isPaused { return LibraryTokens.ink2 }
        if model.saveProblem { return LibraryTokens.attention }
        return model.keyboardStatus == .ready ? LibraryTokens.accent : LibraryTokens.attention
    }
}
