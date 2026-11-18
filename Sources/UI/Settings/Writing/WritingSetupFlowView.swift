import SwiftUI

/// Setup in two screens (owner-approved 2026-11-18, docs/writing-plan.md,
/// "Setup, screen 1 of 2" and "screen 2 of 2"). Screen 1 is the pitch plus
/// the two questions: what Writing does and which apps. Screen 2 is the
/// keyboard, Screen Recording and the model picked for you. Editing both
/// features off applies on screen 1 through `finishSetupStep1()`; enabled
/// choices fill the draft until "Turn on writing".
struct WritingSetupFlowView: View {
    typealias Copy = WritingSetupPresentation

    @ObservedObject var model: WritingSettingsModel
    let step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch step {
            case 1: stepOne
            default: stepTwo
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    // MARK: Screen 1: Turn on Writing

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 24) {
            if model.isEditingSetup {
                SettingsPageIntro(title: Copy.Step1.editTitle)
            } else {
                WritingIntroView()
            }

            VStack(alignment: .leading, spacing: 10) {
                WritingQuestionTitle(text: Copy.Step1.title)
                SettingsCard {
                    WritingToggleRow(
                        title: Copy.Step1.saveTitle,
                        line: Copy.Step1.saveLine,
                        isOn: $model.draft.saveMyWriting,
                        automationIdentifier: "transcripted.settings.writing.setup.save-my-writing"
                    )
                    WritingToggleRow(
                        title: Copy.Step1.autocompleteTitle,
                        line: Copy.Step1.autocompleteLine,
                        isOn: $model.draft.autocomplete,
                        automationIdentifier: "transcripted.settings.writing.setup.autocomplete",
                        showsDivider: false
                    )
                }
                validationMessage(Copy.step1Message(
                    saveMyWriting: model.draft.saveMyWriting,
                    autocomplete: model.draft.autocomplete,
                    isEditing: model.isEditingSetup
                ), isBlocking: !model.draft.canContinueStep1 && !model.isEditingSetup)
            }

            appsQuestion

            WritingPrivacyPoint(point: Copy.Intro.privacy)

            HStack(spacing: 12) {
                WritingPageDots(count: Copy.setupStepCount, current: 1)
                Spacer()
                if model.isEditingSetup {
                    WritingSecondaryButton(
                        title: Copy.cancel,
                        automationIdentifier: "transcripted.settings.writing.setup.cancel"
                    ) {
                        model.cancelSetup()
                    }
                } else {
                    WritingSecondaryButton(
                        title: Copy.notNow,
                        automationIdentifier: "transcripted.settings.writing.intro.not-now"
                    ) {
                        model.dismissNewBadge()
                    }
                }
                WritingPrimaryButton(
                    title: Copy.step1Primary(
                        saveMyWriting: model.draft.saveMyWriting,
                        autocomplete: model.draft.autocomplete,
                        isEditing: model.isEditingSetup
                    ) == .turnOffWriting ? Copy.Step1.turnOffTitle : Copy.Step1.continueTitle,
                    isEnabled: model.draft.canFinishStep1(isEditing: model.isEditingSetup),
                    automationIdentifier: "transcripted.settings.writing.setup.continue"
                ) {
                    model.finishSetupStep1()
                }
            }
            .padding(.top, 4)
        }
        .task {
            model.loadInstalledAppsIfNeeded()
        }
    }

    private var appsQuestion: some View {
        VStack(alignment: .leading, spacing: 6) {
            WritingQuestionTitle(text: Copy.Step1.appsTitle)
            VStack(alignment: .leading, spacing: 0) {
                WritingChoiceRow(
                    title: Copy.Step1.allApps,
                    detail: Copy.Step1.allAppsLine,
                    isSelected: model.draft.scope == .all,
                    automationIdentifier: "transcripted.settings.writing.setup.scope.all"
                ) {
                    model.draft.scope = .all
                }
                WritingChoiceRow(
                    title: Copy.Step1.pickedApps,
                    detail: Copy.Step1.sameApps,
                    isSelected: model.draft.scope == .picked,
                    automationIdentifier: "transcripted.settings.writing.setup.scope.picked"
                ) {
                    model.draft.scope = .picked
                }
                if model.draft.scope == .picked {
                    appChips
                        .padding(.leading, 24)
                        .padding(.top, 4)
                }
            }
            validationMessage(Copy.appsMessage(
                scope: model.draft.scope,
                pickedCount: model.draft.pickedBundleIdentifiers.count
            ))
        }
    }

    private var appChips: some View {
        let ordered = model.appChoices
        let visible = Copy.visibleApps(
            ordered: ordered,
            picked: model.draft.pickedBundleIdentifiers,
            showAll: model.showsAllApps
        )
        return VStack(alignment: .leading, spacing: 8) {
            WritingFlowLayout {
                ForEach(visible, id: \.bundleIdentifier) { app in
                    WritingAppChip(
                        title: app.name,
                        isSelected: model.draft.pickedBundleIdentifiers.contains(app.bundleIdentifier),
                        automationIdentifier: "transcripted.settings.writing.setup.app.\(app.bundleIdentifier)"
                    ) {
                        model.toggleApp(app.bundleIdentifier)
                    }
                }
            }
            if ordered.count > Copy.collapsedAppCount {
                Button(model.showsAllApps ? Copy.Step1.fewerApps : Copy.Step1.moreApps) {
                    model.showsAllApps.toggle()
                }
                .buttonStyle(.transcriptedQuiet)
                .controlSize(.small)
                .accessibilityIdentifier("transcripted.settings.writing.setup.more-apps")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.writing.setup.apps")
    }

    // MARK: Screen 2: Allow and download

    private var stepTwo: some View {
        let rows = Copy.step2Rows(
            saveMyWriting: model.draft.saveMyWriting,
            autocomplete: model.draft.autocomplete
        )
        return VStack(alignment: .leading, spacing: 18) {
            SettingsPageIntro(title: Copy.Step2.title)

            SettingsCard {
                ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                    step2Row(row, showsDivider: index < rows.count - 1)
                }
            }

            Text(Copy.Step2.footnote)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                WritingPageDots(count: Copy.setupStepCount, current: 2)
                Spacer()
                WritingSecondaryButton(
                    title: Copy.back,
                    automationIdentifier: "transcripted.settings.writing.setup.back"
                ) {
                    model.showStep(1)
                }
                WritingPrimaryButton(
                    title: Copy.Step2.turnOn,
                    isEnabled: model.draft.canContinueStep1 && model.draft.canContinueApps,
                    automationIdentifier: "transcripted.settings.writing.setup.turn-on"
                ) {
                    model.turnOnWriting()
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func step2Row(_ row: Copy.Step2Row, showsDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch row {
            case .keyboard:
                // Once the keyboard is installed, the steps for where it
                // stands; "Turn on writing" never waits on them.
                let keyboardStep = Copy.keyboardStep(model.keyboardSetup)
                rowHeader(
                    title: Copy.Step2.keyboardTitle,
                    badge: Copy.keyboardBadge(
                        saveMyWriting: model.draft.saveMyWriting,
                        autocomplete: model.draft.autocomplete
                    ),
                    done: keyboardStep.isDone
                )
                rowLine(keyboardStep.line)
                if let buttonTitle = keyboardStep.buttonTitle {
                    Button(buttonTitle) {
                        model.openKeyboardSettings()
                    }
                    .buttonStyle(.transcriptedSecondary)
                    .controlSize(.small)
                    .padding(.top, 4)
                    .accessibilityIdentifier("transcripted.settings.writing.setup.keyboard.open-settings")
                }
            case .screenRecording:
                rowHeader(
                    title: Copy.Step2.screenRecordingTitle,
                    badge: Copy.Step2.autocompleteBadge,
                    done: model.screenRecordingGranted
                )
                rowLine(Copy.Step2.screenRecordingLine)
                if !model.screenRecordingGranted, model.captureBusy {
                    Text(Copy.finishRecordingFirst)
                        .font(LibraryTokens.meta.weight(.semibold))
                        .foregroundStyle(LibraryTokens.attention)
                        .accessibilityIdentifier("transcripted.settings.writing.setup.screen-recording.hold")
                }
            case .model:
                // No question here: the draft's model (the smaller one
                // unless changed) downloads, and the Settings card on the
                // Writing page switches it.
                rowHeader(title: Copy.Step2.modelTitle, badge: Copy.Step2.autocompleteBadge, done: false)
                rowLine(Copy.modelLine(for: model.draft.model))
                    .accessibilityIdentifier("transcripted.settings.writing.setup.model")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if showsDivider { Divider() }
        }
        .accessibilityElement(children: .contain)
    }

    private func rowHeader(title: String, badge: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(LibraryTokens.rowTitle)
            WritingBadge(text: badge)
            Spacer(minLength: 0)
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LibraryTokens.ink)
                    .accessibilityLabel(Text("Done"))
            }
        }
    }

    private func rowLine(_ text: String) -> some View {
        Text(text)
            .font(LibraryTokens.meta)
            .foregroundStyle(LibraryTokens.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Shared

    @ViewBuilder
    private func validationMessage(_ message: String?, isBlocking: Bool = true) -> some View {
        if let message {
            Text(message)
                .font(LibraryTokens.meta.weight(.semibold))
                .foregroundStyle(isBlocking ? LibraryTokens.attention : LibraryTokens.ink2)
                .accessibilityIdentifier("transcripted.settings.writing.setup.message")
        }
    }
}
