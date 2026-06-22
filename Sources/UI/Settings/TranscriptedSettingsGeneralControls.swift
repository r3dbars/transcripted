import SwiftUI

struct GeneralSettingsHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.14))
                )

            Text("General")
                .font(.system(size: 24, weight: .semibold))
        }
    }
}

struct GeneralSettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: 680, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.88))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.11), lineWidth: 1)
        )
    }
}

struct GeneralInfo {
    let title: String
    let message: String
}

struct GeneralInfoButton: View {
    let info: GeneralInfo

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isHovering ? 0.10 : 0.04))
                )
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Learn about \(info.title)")
        .accessibilityLabel(Text("About \(info.title)"))
        .accessibilityIdentifier("transcripted.settings.general.info.\(automationSlug(info.title))")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(info.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)

                Text(info.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
        }
        .onHover { isHovering = $0 }
    }
}

struct GeneralTitleLabel: View {
    let title: String
    let info: GeneralInfo?

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if let info {
                GeneralInfoButton(info: info)
            }
        }
        .layoutPriority(1)
    }
}

struct GeneralSectionHeading: View {
    let title: String
    let info: GeneralInfo?

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if let info {
                GeneralInfoButton(info: info)
            }
        }
        .padding(.leading, 10)
    }
}

struct GeneralToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var help: String
    var info: GeneralInfo? = nil
    var automationIdentifier: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            GeneralTitleLabel(title: title, info: info)

            Spacer(minLength: 10)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .tint(.accentColor)
                .help(help)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(isOn ? "On" : "Off"))
                .accessibilityHint(Text(help))
                .generalAutomationIdentifier(automationIdentifier)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct DictationOverlayModeRow: View {
    @Binding var selection: DictationOverlayPresentationMode

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                GeneralTitleLabel(
                    title: "Dictation window",
                    info: GeneralInfo(
                        title: "Dictation window",
                        message: "Choose how Transcripted shows live dictation. Near text box uses the full window beside the focused field. Mini cursor uses a tiny waveform that follows your pointer."
                    )
                )

                Text("Pick the window people see while dictating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 10)

            HStack(alignment: .top, spacing: 10) {
                ForEach(DictationOverlayPresentationMode.allCases) { mode in
                    DictationOverlayModeChoice(
                        mode: mode,
                        isSelected: selection == mode,
                        action: { selection = mode }
                    )
                }
            }
            .frame(maxWidth: 374, alignment: .trailing)
        .help(selection.detail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Dictation window options"))
        .accessibilityValue(Text(selection.title))
        .accessibilityHint(Text("Choose one of two dictation window styles."))
        .accessibilityIdentifier("transcripted.settings.general.dictation-window.options")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 124)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct DictationOverlayModeChoice: View {
    let mode: DictationOverlayPresentationMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) { cardContent }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .help(mode.detail)
        .accessibilityLabel(Text(mode.title))
        .accessibilityValue(Text(isSelected ? "Selected" : "Not selected"))
        .accessibilityHint(Text(mode.detail))
        .accessibilityIdentifier("transcripted.settings.general.dictation-window.\(mode.rawValue)")
        .onHover { isHovering = $0 }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            DictationOverlayModePreview(mode: mode, isSelected: isSelected)
                .frame(maxWidth: .infinity)

            copyContent
        }
        .padding(10)
        .frame(width: 182, alignment: .topLeading)
        .frame(minHeight: 112, alignment: .topLeading)
        .background(cardBackground)
        .overlay(cardStroke)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var copyContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(mode.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)

            Text(mode.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(choiceFill)
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(choiceStroke, lineWidth: isSelected || isFocused ? 2 : 1)
    }

    private var choiceFill: Color {
        isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(isHovering ? 0.055 : 0.035)
    }

    private var choiceStroke: Color {
        if isFocused { return .accentColor.opacity(0.92) }
        if isSelected { return .accentColor }
        return Color.primary.opacity(isHovering ? 0.18 : 0.11)
    }
}

private struct DictationOverlayModePreview: View {
    let mode: DictationOverlayPresentationMode
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            switch mode {
            case .nearText:
                NearTextOverlayPreview()
            case .cursorMini:
                MiniCursorOverlayPreview()
            }
        }
        .frame(height: 46)
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .background(Circle().fill(Color.black.opacity(0.72)))
                    .padding(6)
            }
        }
    }
}

private struct NearTextOverlayPreview: View {
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .frame(width: 82, height: 24)
                    .overlay {
                        MiniWaveformBars(barCount: 13, activeIndex: 8)
                            .frame(width: 54, height: 14)
                    }

                Text("Stop")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.86))
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.92))
                    )
            }

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(Color.accentColor.opacity(0.58), lineWidth: 1)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 2, style: .continuous))
                .frame(width: 116, height: 6)
        }
    }
}

private struct MiniCursorOverlayPreview: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.56))
                .offset(y: 8)

            Capsule()
                .fill(Color.black.opacity(0.82))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .frame(width: 76, height: 24)
                .overlay {
                    MiniWaveformBars(barCount: 12, activeIndex: 7)
                        .frame(width: 50, height: 14)
                }
        }
    }
}

private struct MiniWaveformBars: View {
    private static let heightPattern: [CGFloat] = [5, 9, 7, 12, 8, 14, 6, 11, 8, 13, 7, 10, 5, 9, 6]

    let barCount: Int
    let activeIndex: Int

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == activeIndex ? 0.95 : 0.68))
                    .frame(width: 1.6, height: barHeight(at: index))
            }
        }
    }

    private func barHeight(at index: Int) -> CGFloat {
        Self.heightPattern[index % Self.heightPattern.count]
    }
}

struct GeneralActionRow: View {
    let title: String
    let value: String
    let systemImage: String?
    let help: String
    var automationIdentifier: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 10)

                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(value)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.035) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        .accessibilityHint(Text(help))
        .generalAutomationIdentifier(automationIdentifier)
    }
}

struct GeneralDisclosureRow: View {
    let title: String
    let value: String
    @Binding var isExpanded: Bool
    let help: String
    var automationIdentifier: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                isExpanded.toggle()
            }
            action()
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 10)

                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isHovering ? 0.10 : 0.06))
                    )
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.035) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text("\(value), \(isExpanded ? "expanded" : "collapsed")"))
        .accessibilityHint(Text(help))
        .generalAutomationIdentifier(automationIdentifier)
    }
}

struct GeneralExpandedContent<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private extension View {
    @ViewBuilder
    func generalAutomationIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

private func automationSlug(_ value: String) -> String {
    value
        .lowercased()
        .map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        .reduce(into: "") { result, character in
            if character == "-", result.last == "-" {
                return
            }
            result.append(character)
        }
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}
