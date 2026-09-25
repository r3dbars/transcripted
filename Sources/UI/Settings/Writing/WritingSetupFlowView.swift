import SwiftUI

/// Setup, steps 1 to 3 (docs/writing-plan.md, "Setup, step 1 of 3" to
/// "step 3 of 3"). The steps only fill `model.draft`; "Turn on writing"
/// applies it through `WritingSettingsModel.turnOnWriting()`.
struct WritingSetupFlowView: View {
    typealias Copy = WritingSetupPresentation

    @ObservedObject var model: WritingSettingsModel
    let step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch step {
            case 1: stepOne
            case 2: stepTwo
            default: stepThree
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    // MARK: Step 1: What should writing do?

    private var stepOne: some View {
        VStack(alignment: .leading, spacing: 18) {
            WritingStepHeader(step: 1, title: Copy.Step1.title)

            SettingsCard {
                featureToggle(
                    title: Copy.Step1.saveTitle,
                    line: Copy.Step1.saveLine,
                    isOn: $model.draft.saveMyWriting,
                    automationIdentifier: "transcripted.settings.writing.setup.save-my-writing"
                )
                featureToggle(
                    title: Copy.Step1.autocompleteTitle,
                    line: Copy.Step1.autocompleteLine,
                    isOn: $model.draft.autocomplete,
                    automationIdentifier: "transcripted.settings.writing.setup.autocomplete",
                    showsDivider: false
                )
            }

            validationMessage(Copy.step1Message(
                saveMyWriting: model.draft.saveMyWriting,
                autocomplete: model.draft.autocomplete
            ))

            HStack(spacing: 12) {
                if model.isEditingSetup {
                    WritingSecondaryButton(
                        title: Copy.cancel,
                        automationIdentifier: "transcripted.settings.writing.setup.cancel"
                    ) {
                        model.cancelSetup()
                    }
                }
                Spacer()
                WritingPrimaryButton(
                    title: Copy.Step1.continueTitle,
                    isEnabled: model.draft.canContinueStep1,
                    automationIdentifier: "transcripted.settings.writing.setup.continue"
                ) {
                    model.showStep(2)
                }
            }
        }
    }

    private func featureToggle(
        title: String,
        line: String,
        isOn: Binding<Bool>,
        automationIdentifier: String,
        showsDivider: Bool = true
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
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(line))
                .accessibilityIdentifier(automationIdentifier)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) {
            if showsDivider { Divider() }
        }
    }

    // MARK: Step 2: Which apps?

    private var stepTwo: some View {
        VStack(alignment: .leading, spacing: 18) {
            WritingStepHeader(step: 2, title: Copy.Step2.title)

            VStack(alignment: .leading, spacing: 4) {
                WritingChoiceRow(
                    title: Copy.Step2.allApps,
                    detail: Copy.Step2.allAppsLine,
                    isSelected: model.draft.scope == .all,
                    automationIdentifier: "transcripted.settings.writing.setup.scope.all"
                ) {
                    model.draft.scope = .all
                }
                WritingChoiceRow(
                    title: Copy.Step2.pickedApps,
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

            Text(Copy.Step2.sameApps)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)

            validationMessage(Copy.step2Message(
                scope: model.draft.scope,
                pickedCount: model.draft.pickedBundleIdentifiers.count
            ))

            HStack(spacing: 12) {
                WritingSecondaryButton(
                    title: Copy.back,
                    automationIdentifier: "transcripted.settings.writing.setup.back"
                ) {
                    model.showStep(1)
                }
                Spacer()
                WritingPrimaryButton(
                    title: Copy.Step1.continueTitle,
                    isEnabled: model.draft.canContinueStep2,
                    automationIdentifier: "transcripted.settings.writing.setup.continue"
                ) {
                    model.showStep(3)
                }
            }
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
                Button(model.showsAllApps ? Copy.Step2.fewerApps : Copy.Step2.moreApps) {
                    model.showsAllApps.toggle()
                }
                .buttonStyle(.link)
                .font(LibraryTokens.meta)
                .frame(minHeight: 28)
                .accessibilityIdentifier("transcripted.settings.writing.setup.more-apps")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.writing.setup.apps")
    }

    // MARK: Step 3: Allow and download

    private var stepThree: some View {
        let rows = Copy.step3Rows(
            saveMyWriting: model.draft.saveMyWriting,
            autocomplete: model.draft.autocomplete
        )
        return VStack(alignment: .leading, spacing: 18) {
            WritingStepHeader(step: 3, title: Copy.Step3.title)

            SettingsCard {
                ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                    step3Row(row, showsDivider: index < rows.count - 1)
                }
            }

            Text(Copy.Step3.footnote)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                WritingSecondaryButton(
                    title: Copy.back,
                    automationIdentifier: "transcripted.settings.writing.setup.back"
                ) {
                    model.showStep(2)
                }
                Spacer()
                WritingPrimaryButton(
                    title: Copy.Step3.turnOn,
                    isEnabled: model.draft.canContinueStep1 && model.draft.canContinueStep2,
                    automationIdentifier: "transcripted.settings.writing.setup.turn-on"
                ) {
                    model.turnOnWriting()
                }
            }
        }
    }

    @ViewBuilder
    private func step3Row(_ row: Copy.Step3Row, showsDivider: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch row {
            case .keyboard:
                rowHeader(
                    title: Copy.Step3.keyboardTitle,
                    badge: Copy.keyboardBadge(
                        saveMyWriting: model.draft.saveMyWriting,
                        autocomplete: model.draft.autocomplete
                    ),
                    done: model.keyboardOn == true
                )
                rowLine(Copy.Step3.keyboardLine)
            case .screenRecording:
                rowHeader(
                    title: Copy.Step3.screenRecordingTitle,
                    badge: Copy.Step3.autocompleteBadge,
                    done: model.screenRecordingGranted
                )
                rowLine(Copy.Step3.screenRecordingLine)
                if !model.screenRecordingGranted, model.captureBusy {
                    Text(Copy.finishRecordingFirst)
                        .font(LibraryTokens.meta.weight(.semibold))
                        .foregroundStyle(LibraryTokens.attention)
                        .accessibilityIdentifier("transcripted.settings.writing.setup.screen-recording.hold")
                }
            case .model:
                rowHeader(title: Copy.Step3.modelTitle, badge: Copy.Step3.autocompleteBadge, done: false)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Copy.modelOptions, id: \.name) { option in
                        let eligible = option.choice == .gemma4E2B || model.isQwenEligible
                        WritingChoiceRow(
                            title: option.name,
                            detail: option.detail,
                            tag: option.isDefault ? Copy.defaultTag : nil,
                            disabledLine: Copy.ineligibleLine(for: option.choice, isEligible: eligible),
                            isSelected: model.draft.model == option.choice,
                            isEnabled: eligible,
                            automationIdentifier: "transcripted.settings.writing.setup.model.\(option.choice == .gemma4E2B ? "gemma" : "qwen")"
                        ) {
                            model.draft.model = option.choice
                        }
                    }
                }
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
                .font(.subheadline.weight(.semibold))
            WritingBadge(text: badge)
            Spacer(minLength: 0)
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LibraryTokens.accent)
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
    private func validationMessage(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(LibraryTokens.meta.weight(.semibold))
                .foregroundStyle(LibraryTokens.attention)
                .accessibilityIdentifier("transcripted.settings.writing.setup.message")
        }
    }
}
