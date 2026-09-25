import AppKit
import SwiftUI

/// The Writing tab after setup, shaped like the Dictations page
/// (docs/writing-plan.md, "Everyday view"): the summary, a status line,
/// today's saved writing newest first, the autocomplete numbers, and the
/// settings section.
struct WritingEverydayView: View {
    typealias Copy = WritingSetupPresentation

    @ObservedObject var model: WritingSettingsModel
    @State private var expandedEntryID: String?
    @State private var copiedEntryID: String?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            attentionRows
            if model.saveMyWriting {
                savedWritingSection
            }
            if model.autocomplete {
                autocompleteSection
            }
            WritingSettingsSection(model: model)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsPageIntro(
                title: Copy.everydayTitle,
                summary: Copy.summary(
                    saveMyWriting: model.saveMyWriting,
                    autocomplete: model.autocomplete,
                    wordsToday: model.today.wordCount
                )
            )

            if model.saveMyWriting || model.autocomplete {
                Text(Copy.statusLine(
                    keyboardOn: model.keyboardOn,
                    autocomplete: model.autocomplete,
                    model: model.selectedModel,
                    modelStatus: model.modelStatus,
                    scope: model.scope,
                    pickedCount: model.pickedCount
                ))
                .font(LibraryTokens.meta)
                .foregroundStyle(Copy.isProblem(model.modelStatus) && model.autocomplete ? LibraryTokens.attention : LibraryTokens.ink2)
                .accessibilityIdentifier("transcripted.settings.writing.status")

                if model.autocomplete, case let .downloading(fraction) = model.modelStatus, let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(LibraryTokens.accent)
                        .frame(maxWidth: 320)
                        .accessibilityLabel(Text(Copy.modelStatusText(model.modelStatus)))
                        .accessibilityIdentifier("transcripted.settings.writing.model-progress")
                }
            }

            if model.saveMyWriting && model.saveProblem {
                Text(Copy.saveProblemLine)
                    .font(LibraryTokens.meta.weight(.semibold))
                    .foregroundStyle(LibraryTokens.attention)
                    .accessibilityIdentifier("transcripted.settings.writing.save-problem")
            }

            if let pausedUntil = model.pausedUntil {
                Text(Copy.pausedLine(until: pausedUntil, timeFormatter: Self.timeFormatter))
                    .font(LibraryTokens.meta.weight(.semibold))
                    .foregroundStyle(LibraryTokens.attention)
                    .accessibilityIdentifier("transcripted.settings.writing.paused")
            }

            HStack(spacing: 8) {
                SettingsInlineActionButton(
                    title: Copy.editSetup,
                    symbolName: "slider.horizontal.3",
                    automationIdentifier: "transcripted.settings.writing.edit-setup"
                ) {
                    model.editSetup()
                }
                if model.saveMyWriting || model.autocomplete {
                    if model.pausedUntil == nil {
                        SettingsInlineActionButton(
                            title: Copy.pauseForHour,
                            symbolName: "pause.circle",
                            automationIdentifier: "transcripted.settings.writing.pause"
                        ) {
                            model.pauseForAnHour()
                        }
                    } else {
                        SettingsInlineActionButton(
                            title: Copy.resume,
                            symbolName: "play.circle",
                            tone: .accent,
                            automationIdentifier: "transcripted.settings.writing.resume"
                        ) {
                            model.resume()
                        }
                    }
                }
            }
        }
    }

    // MARK: Needs attention

    @ViewBuilder
    private var attentionRows: some View {
        let keyboardOff = (model.saveMyWriting || model.autocomplete) && model.keyboardOn == false
        let needsScreenRecording = model.autocomplete && !model.screenRecordingGranted
        if keyboardOff || needsScreenRecording {
            SettingsCard {
                if keyboardOff {
                    attentionRow(
                        title: Copy.Step3.keyboardTitle,
                        line: Copy.Step3.keyboardLine,
                        note: nil,
                        buttonTitle: Copy.turnOnKeyboard,
                        buttonEnabled: true,
                        automationIdentifier: "transcripted.settings.writing.keyboard.turn-on",
                        showsDivider: needsScreenRecording
                    ) {
                        model.turnOnKeyboard()
                    }
                }
                if needsScreenRecording {
                    attentionRow(
                        title: Copy.Step3.screenRecordingTitle,
                        line: Copy.Step3.screenRecordingLine,
                        note: model.captureBusy ? Copy.finishRecordingFirst : Copy.screenRecordingReopenLine,
                        buttonTitle: model.screenRecordingRequested
                            ? Copy.openScreenRecordingSettings
                            : Copy.allowScreenRecording,
                        buttonEnabled: !model.captureBusy,
                        automationIdentifier: "transcripted.settings.writing.screen-recording.allow",
                        showsDivider: false
                    ) {
                        model.allowScreenRecording()
                    }
                }
            }
        }
    }

    private func attentionRow(
        title: String,
        line: String,
        note: String?,
        buttonTitle: String,
        buttonEnabled: Bool,
        automationIdentifier: String,
        showsDivider: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(LibraryTokens.attention)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(line)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(LibraryTokens.meta.weight(.semibold))
                        .foregroundStyle(buttonEnabled ? LibraryTokens.ink2 : LibraryTokens.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            SettingsInlineActionButton(
                title: buttonTitle,
                tone: .warning,
                automationIdentifier: automationIdentifier,
                action: action
            )
            .disabled(!buttonEnabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if showsDivider { Divider() }
        }
    }

    // MARK: Today's saved writing

    private var savedWritingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            LibrarySectionLabel(text: Copy.savedWritingLabel)
            if model.today.entries.isEmpty {
                Text(Copy.nothingSavedYet)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.ink2)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("transcripted.settings.writing.today.empty")
            } else {
                ForEach(model.today.entries) { entry in
                    if expandedEntryID == entry.id {
                        WritingEntryExpansion(
                            entry: entry,
                            time: time(of: entry),
                            isCopied: copiedEntryID == entry.id,
                            onCopy: { copy(entry) },
                            onOpenFile: { NSWorkspace.shared.open(model.todayFileURL) },
                            onCollapse: { toggle(entry) }
                        )
                    } else {
                        WritingEntryRow(
                            entry: entry,
                            time: time(of: entry),
                            isCopied: copiedEntryID == entry.id,
                            onOpen: { toggle(entry) },
                            onCopy: { copy(entry) }
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.writing.today")
    }

    private func time(of entry: WritingDayFileReader.Entry) -> String {
        entry.capturedAt.map { Self.timeFormatter.string(from: $0) } ?? ""
    }

    private func toggle(_ entry: WritingDayFileReader.Entry) {
        withAnimation(.snappy(duration: 0.2)) {
            expandedEntryID = expandedEntryID == entry.id ? nil : entry.id
        }
    }

    private func copy(_ entry: WritingDayFileReader.Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copiedEntryID = entry.id
        let copied = entry.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copiedEntryID == copied { copiedEntryID = nil }
        }
    }

    // MARK: Autocomplete numbers

    private var autocompleteSection: some View {
        let ledger = model.ledger
        let accepted = Copy.suggestionsAcceptedToday(
            ledgerAccepted: ledger.acceptedGhostsToday,
            ledgerHasTodayEvidence: ledger.hasTodayEvidence,
            keyboardCounter: model.keyboardAcceptedToday
        )
        return VStack(alignment: .leading, spacing: 6) {
            LibrarySectionLabel(text: Copy.autocompleteLabel)
            Text(Copy.suggestionsAcceptedLine(accepted))
                .font(LibraryTokens.rowTitle)
                .accessibilityIdentifier("transcripted.settings.writing.accepted")
            Text(Copy.keystrokesSavedLine(
                today: ledger.keystrokesSavedToday,
                last7Days: ledger.keystrokesSavedLast7Days,
                partial: ledger.truncated
            ))
            .font(LibraryTokens.meta)
            .foregroundStyle(LibraryTokens.ink2)
            if let kept = OutcomeLedgerPresentation.keptAfter30SecondsLine(summary: ledger) {
                Text(kept)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
            }
            if let streak = OutcomeLedgerPresentation.helpfulStreakLine(summary: ledger) {
                Text(streak)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
            }
            if let heldBack = OutcomeLedgerPresentation.heldBackLine(
                summary: ledger,
                screenAccessGranted: model.screenRecordingGranted
            ) {
                Text(heldBack)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.writing.autocomplete-stats")
    }
}

// MARK: - Rows

/// One saved entry: its first line, the app, and the time; Copy on hover.
/// Same shape as `QuietDictationRow`.
private struct WritingEntryRow: View {
    let entry: WritingDayFileReader.Entry
    let time: String
    let isCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(QuietDictationLibraryFormatting.firstLine(of: entry.text, fallback: entry.title))
                .font(LibraryTokens.body)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)

            HomeRowActionButtons(
                isCopied: isCopied,
                onCopy: onCopy,
                menuItems: [],
                copyAutomationIdentifier: "transcripted.settings.writing.entry.copy"
            )
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)

            Text(entry.sourceAppName)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink3)
                .lineLimit(1)
                .fixedSize()
            Text(time)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink3)
                .fixedSize()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 1, style: .continuous)
                .fill(isHovering ? LibraryTokens.rowHover : Color.clear)
        )
        .padding(.horizontal, -10)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .onTapGesture(perform: onOpen)
        .help("Open writing")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("transcripted.settings.writing.entry")
    }
}

/// The opened entry: its full text, a meta line, Copy and Open file.
private struct WritingEntryExpansion: View {
    let entry: WritingDayFileReader.Entry
    let time: String
    let isCopied: Bool
    let onCopy: () -> Void
    let onOpenFile: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.text)
                .font(LibraryTokens.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Text([time, WritingSetupPresentation.entryMetaLine(
                sourceApp: entry.sourceAppName,
                words: entry.wordCount,
                acceptedWords: entry.acceptedWordCount
            )].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink3)
                .padding(.top, 8)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCollapse)
                .help("Collapse")

            HStack(spacing: 16) {
                action(
                    title: isCopied ? "Copied" : "Copy",
                    symbol: isCopied ? "checkmark" : "square.on.square",
                    automationIdentifier: "transcripted.settings.writing.entry.expansion.copy",
                    perform: onCopy
                )
                action(
                    title: "Open file",
                    symbol: "arrow.down.doc",
                    automationIdentifier: "transcripted.settings.writing.entry.expansion.open",
                    perform: onOpenFile
                )
                Spacer()
            }
            .padding(.top, 12)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .padding(.vertical, 4)
    }

    private func action(
        title: String,
        symbol: String,
        automationIdentifier: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .font(LibraryTokens.meta.weight(.semibold))
                .foregroundStyle(LibraryTokens.ink2)
                .frame(minHeight: LibraryTokens.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(automationIdentifier)
    }
}
