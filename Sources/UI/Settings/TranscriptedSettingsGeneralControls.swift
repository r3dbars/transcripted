import SwiftUI



struct GeneralInfo {
    let title: String
    let message: String
}

/// Klack-style settings card: a rounded fill that groups rows, with the rows'
/// own hairline dividers separating them. Rows keep their flat styling; the
/// card provides the only chrome on the page.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 620, alignment: .leading)
    }
}

/// Small gray section label above a card, mirroring the mock's plain
/// wayfinding (no icon chips).
struct SettingsCardLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

/// One card row hosting an arbitrary trailing control: label + optional info
/// bubble on the left, the control on the right. The verbose explanation
/// lives in the info popover, not on the row.
struct SettingsControlRow<Control: View>: View {
    let title: String
    var info: GeneralInfo? = nil
    var automationIdentifier: String? = nil
    var showsDivider = true
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            GeneralTitleLabel(title: title, info: info)

            Spacer(minLength: 10)

            control
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
            }
        }
        .accessibilityElement(children: .contain)
        .generalRowAutomationIdentifier(automationIdentifier)
    }
}

private extension View {
    @ViewBuilder
    func generalRowAutomationIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
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

/// Whether the Notch island shows up in screen sharing (off by default).
struct NotchIslandScreenSharingRow: View {
    @AppStorage(NotchIslandPreferences.visibleInScreenSharingKey)
    private var visibleInScreenSharing = false

    var body: some View {
        GeneralToggleRow(
            title: "Show island in screen sharing",
            isOn: $visibleInScreenSharing,
            help: visibleInScreenSharing
                ? "The island shows in screen sharing, recordings, and screenshots."
                : "The island is hidden from screen sharing, recordings, and screenshots.",
            info: GeneralInfo(
                title: "Show island in screen sharing",
                message: "Off keeps the island out of screen sharing, screen recordings, and screenshots, so people watching your screen never see what you dictate. Turn it on to demo it or capture it in a screenshot."
            ),
            automationIdentifier: "transcripted.settings.general.island-screen-sharing"
        )
    }
}

struct GeneralToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var help: String
    var info: GeneralInfo? = nil
    var automationIdentifier: String? = nil
    var showsDivider = true

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
            if showsDivider {
                Divider()
            }
        }
    }
}

struct GeneralActionRow: View {
    let title: String
    let value: String
    let systemImage: String?
    let help: String
    var automationIdentifier: String? = nil
    var showsDivider = true
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
            if showsDivider {
                Divider()
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        .accessibilityHint(Text(help))
        .generalAutomationIdentifier(automationIdentifier)
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
