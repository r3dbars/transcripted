import SwiftUI

/// "Fix a word" for the open meeting: type a misheard word, type the right
/// one, and every match in this transcript is fixed at once. The live count
/// comes from the preview's own Markdown; the file write, preview reload and
/// undo all run in the Settings shell through `onFixWord`.
struct QuietMeetingWordFixBar: View {
    let markdown: String
    let onFixWord: (
        HomeMeetingWordFixAction,
        @escaping (HomeMeetingWordFixOutcome) -> Void
    ) -> Void
    let onClose: () -> Void

    @State private var find = ""
    @State private var replacement = ""
    @State private var matchCase = true
    @State private var wholeWords = true
    @State private var isWorking = false
    @State private var lastFix: HomeMeetingWordFixReceipt?
    @State private var statusText: String?
    @State private var errorText: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case find
        case replacement
    }

    private var options: HomeMeetingWordFixOptions {
        HomeMeetingWordFixOptions(matchCase: matchCase, wholeWords: wholeWords)
    }

    private var matchCount: Int {
        HomeMeetingWordFix.matchCount(of: find, in: markdown, options: options)
    }

    private var canReplace: Bool {
        let normalizedFind = HomeMeetingWordFix.normalized(find)
        let normalizedReplacement = HomeMeetingWordFix.normalized(replacement)
        return !isWorking
            && matchCount > 0
            && !normalizedReplacement.isEmpty
            && normalizedReplacement != normalizedFind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Word to fix", text: $find)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($focusedField, equals: .find)
                    .onSubmit { focusedField = .replacement }
                    .accessibilityIdentifier("transcripted.home.expansion.fix-word.find")

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LibraryTokens.ink3)
                    .accessibilityHidden(true)

                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($focusedField, equals: .replacement)
                    .onSubmit(replaceAll)
                    .accessibilityIdentifier("transcripted.home.expansion.fix-word.replacement")

                Button("Replace all", action: replaceAll)
                    .controlSize(.small)
                    .disabled(!canReplace)
                    .accessibilityIdentifier("transcripted.home.expansion.fix-word.replace-all")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LibraryTokens.ink2)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel(Text("Close Fix a word"))
                .accessibilityIdentifier("transcripted.home.expansion.fix-word.close")
            }

            HStack(spacing: 14) {
                Toggle("Match case", isOn: $matchCase)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("transcripted.home.expansion.fix-word.match-case")
                Toggle("Whole words only", isOn: $wholeWords)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("transcripted.home.expansion.fix-word.whole-words")
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.mini)
                } else if !HomeMeetingWordFix.normalized(find).isEmpty {
                    Text(HomeMeetingWordFixCopy.matchCount(matchCount))
                        .foregroundStyle(matchCount > 0 ? LibraryTokens.ink2 : LibraryTokens.ink3)
                        .accessibilityIdentifier("transcripted.home.expansion.fix-word.count")
                }
            }
            .font(LibraryTokens.meta)

            if let errorText {
                Text(errorText)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
            } else if let statusText {
                HStack(spacing: 8) {
                    Text(statusText)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                    if let lastFix {
                        Button("Undo") { undo(lastFix) }
                            .buttonStyle(.plain)
                            .font(LibraryTokens.meta.weight(.medium))
                            .foregroundStyle(LibraryTokens.accent)
                            .disabled(isWorking)
                            .accessibilityIdentifier("transcripted.home.expansion.fix-word.undo")
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .accessibilityIdentifier("transcripted.home.expansion.fix-word")
        .onAppear { focusedField = .find }
        .onChange(of: find) { _, _ in errorText = nil }
        .onChange(of: replacement) { _, _ in errorText = nil }
    }

    private func replaceAll() {
        guard canReplace else { return }
        isWorking = true
        errorText = nil
        onFixWord(.replace(find: find, replacement: replacement, options: options)) { outcome in
            isWorking = false
            switch outcome {
            case .replaced(let receipt):
                lastFix = receipt
                statusText = HomeMeetingWordFixCopy.fixed(receipt)
            case .undone:
                break
            case .failed(let error):
                errorText = error.errorDescription
            }
        }
    }

    private func undo(_ receipt: HomeMeetingWordFixReceipt) {
        isWorking = true
        errorText = nil
        onFixWord(.undo(receipt)) { outcome in
            isWorking = false
            switch outcome {
            case .undone:
                lastFix = nil
                statusText = HomeMeetingWordFixCopy.undone(receipt)
            case .replaced:
                break
            case .failed(let error):
                lastFix = nil
                statusText = nil
                errorText = error.errorDescription
            }
        }
    }
}
