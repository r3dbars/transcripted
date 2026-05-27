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
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Learn about \(info.title)")
        .accessibilityLabel(Text("About \(info.title)"))
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
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct GeneralActionRow: View {
    let title: String
    let value: String
    let systemImage: String?
    let help: String
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
    }
}

struct GeneralDisclosureRow: View {
    let title: String
    let value: String
    @Binding var isExpanded: Bool
    let help: String
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
