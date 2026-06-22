import AppKit
import SwiftUI

struct SettingsPageIntro: View {
    let title: String
    var summary: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: summaryText == nil ? 0 : 8) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))

            if let summaryText {
                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summaryText: String? {
        guard let summary else { return nil }
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedSummary.isEmpty ? nil : summary
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                if let detailText {
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var detailText: String? {
        guard let detail else { return nil }
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDetail.isEmpty ? nil : detail
    }
}

enum SettingsInteractionTone {
    case neutral
    case accent
    case warning
    case destructive
}

enum SettingsInteractionPalette {
    static let animation = Animation.easeOut(duration: 0.12)
    static let pressAnimation = Animation.easeOut(duration: 0.08)

    static func hoverFill(for tone: SettingsInteractionTone) -> Color {
        switch tone {
        case .neutral:
            return Color.primary.opacity(0.04)
        case .accent:
            return Color.accentColor.opacity(0.13)
        case .warning:
            return Color.orange.opacity(0.12)
        case .destructive:
            return Color.red.opacity(0.10)
        }
    }

    static func pressedFill(for tone: SettingsInteractionTone) -> Color {
        switch tone {
        case .neutral:
            return Color.primary.opacity(0.07)
        case .accent:
            return Color.accentColor.opacity(0.18)
        case .warning:
            return Color.orange.opacity(0.17)
        case .destructive:
            return Color.red.opacity(0.15)
        }
    }

    static func hoverStroke(for tone: SettingsInteractionTone) -> Color {
        switch tone {
        case .neutral:
            return Color.primary.opacity(0.10)
        case .accent:
            return Color.accentColor.opacity(0.30)
        case .warning:
            return Color.orange.opacity(0.26)
        case .destructive:
            return Color.red.opacity(0.22)
        }
    }
}

struct SettingsHoverButtonStyle: ButtonStyle {
    let tone: SettingsInteractionTone
    let cornerRadius: CGFloat
    let normalFill: Color
    let normalStroke: Color
    let hoverFill: Color?
    let pressedFill: Color?
    let hoverStroke: Color?
    let lineWidth: CGFloat

    init(
        tone: SettingsInteractionTone = .neutral,
        cornerRadius: CGFloat = 10,
        normalFill: Color = .clear,
        normalStroke: Color = .clear,
        hoverFill: Color? = nil,
        pressedFill: Color? = nil,
        hoverStroke: Color? = nil,
        lineWidth: CGFloat = 1
    ) {
        self.tone = tone
        self.cornerRadius = cornerRadius
        self.normalFill = normalFill
        self.normalStroke = normalStroke
        self.hoverFill = hoverFill
        self.pressedFill = pressedFill
        self.hoverStroke = hoverStroke
        self.lineWidth = lineWidth
    }

    func makeBody(configuration: Configuration) -> Body {
        Body(
            configuration: configuration,
            tone: tone,
            cornerRadius: cornerRadius,
            normalFill: normalFill,
            normalStroke: normalStroke,
            hoverFill: hoverFill,
            pressedFill: pressedFill,
            hoverStroke: hoverStroke,
            lineWidth: lineWidth
        )
    }

    struct Body: View {
        let configuration: Configuration
        let tone: SettingsInteractionTone
        let cornerRadius: CGFloat
        let normalFill: Color
        let normalStroke: Color
        let hoverFill: Color?
        let pressedFill: Color?
        let hoverStroke: Color?
        let lineWidth: CGFloat

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(strokeColor, lineWidth: lineWidth)
                )
                .opacity(isEnabled ? 1 : 0.55)
                .onHover { isHovering = $0 }
                .animation(SettingsInteractionPalette.animation, value: isHovering)
                .animation(SettingsInteractionPalette.pressAnimation, value: configuration.isPressed)
        }

        private var fillColor: Color {
            guard isEnabled else { return normalFill.opacity(0.65) }
            if configuration.isPressed {
                return pressedFill ?? SettingsInteractionPalette.pressedFill(for: tone)
            }
            if isHovering {
                return hoverFill ?? SettingsInteractionPalette.hoverFill(for: tone)
            }
            return normalFill
        }

        private var strokeColor: Color {
            guard isEnabled else { return normalStroke.opacity(0.5) }
            if configuration.isPressed || isHovering {
                return hoverStroke ?? SettingsInteractionPalette.hoverStroke(for: tone)
            }
            return normalStroke
        }
    }
}

private struct SettingsHoverGlowModifier: ViewModifier {
    let isActive: Bool
    let cornerRadius: CGFloat
    let fill: Color
    let stroke: Color
    let shadow: Color
    let lineWidth: CGFloat
    let shadowRadius: CGFloat
    let shadowYOffset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isActive ? fill : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isActive ? stroke : Color.clear, lineWidth: lineWidth)
            )
            .shadow(
                color: isActive && !reduceMotion ? shadow : Color.clear,
                radius: isActive && !reduceMotion ? shadowRadius : 0,
                x: 0,
                y: shadowYOffset
            )
            .animation(reduceMotion ? nil : SettingsInteractionPalette.animation, value: isActive)
    }
}

extension View {
    func settingsHoverGlow(
        isActive: Bool,
        cornerRadius: CGFloat,
        fill: Color = Color.primary.opacity(0.035),
        stroke: Color = Color.accentColor.opacity(0.16),
        shadow: Color = Color.accentColor.opacity(0.10),
        lineWidth: CGFloat = 1,
        shadowRadius: CGFloat = 8,
        shadowYOffset: CGFloat = 0
    ) -> some View {
        modifier(SettingsHoverGlowModifier(
            isActive: isActive,
            cornerRadius: cornerRadius,
            fill: fill,
            stroke: stroke,
            shadow: shadow,
            lineWidth: lineWidth,
            shadowRadius: shadowRadius,
            shadowYOffset: shadowYOffset
        ))
    }
}

struct SettingsInlineActionButton: View {
    let title: String
    var symbolName: String? = nil
    var tone: SettingsInteractionTone = .neutral
    var automationIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let symbolName {
                Label(title, systemImage: symbolName)
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .buttonStyle(SettingsHoverButtonStyle(
            tone: tone,
            cornerRadius: 8,
            normalFill: normalFill,
            normalStroke: normalStroke
        ))
        .frame(minHeight: 40)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .settingsAutomationIdentifier(automationIdentifier)
    }

    private var normalFill: Color {
        switch tone {
        case .neutral:
            return Color.primary.opacity(0.025)
        case .accent:
            return Color.accentColor.opacity(0.08)
        case .warning:
            return Color.orange.opacity(0.08)
        case .destructive:
            return Color.red.opacity(0.06)
        }
    }

    private var normalStroke: Color {
        switch tone {
        case .neutral:
            return Color.primary.opacity(0.06)
        case .accent:
            return Color.accentColor.opacity(0.16)
        case .warning:
            return Color.orange.opacity(0.16)
        case .destructive:
            return Color.red.opacity(0.14)
        }
    }
}

private extension View {
    @ViewBuilder
    func settingsAutomationIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

struct SettingsActionTile: View {
    enum Tone {
        case accent
        case neutral
    }

    let symbolName: String
    let title: String
    let detail: String
    let tone: Tone
    let menuBarVisibility: Binding<Bool>?
    let actionHelp: String
    let menuBarVisibilityHelp: String?
    let action: () -> Void

    @State private var isHovering = false

    init(
        symbolName: String,
        title: String,
        detail: String,
        tone: Tone = .neutral,
        menuBarVisibility: Binding<Bool>? = nil,
        actionHelp: String? = nil,
        menuBarVisibilityHelp: String? = nil,
        action: @escaping () -> Void
    ) {
        self.symbolName = symbolName
        self.title = title
        self.detail = detail
        self.tone = tone
        self.menuBarVisibility = menuBarVisibility
        self.actionHelp = actionHelp ?? detail
        self.menuBarVisibilityHelp = menuBarVisibilityHelp
        self.action = action
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(iconBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            HStack(spacing: 10) {
                actionButton

                if let menuBarVisibility {
                    Toggle("Show in menu bar", isOn: menuBarVisibility)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help(menuBarVisibilityHelp ?? "Show or hide \(title) in the menu bar popover.")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cardStroke, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .animation(SettingsInteractionPalette.animation, value: isHovering)
    }

    private var actionButton: some View {
        Button(action: action) {
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(actionButtonForeground)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(SettingsHoverButtonStyle(
            tone: interactionTone,
            cornerRadius: 8,
            normalFill: actionButtonBackground,
            normalStroke: actionButtonStroke
        ))
        .help(actionHelp)
    }

    private var interactionTone: SettingsInteractionTone {
        switch tone {
        case .accent:
            return .accent
        case .neutral:
            return .neutral
        }
    }

    private var iconBackground: Color {
        switch tone {
        case .accent:
            return Color.accentColor.opacity(0.16)
        case .neutral:
            return Color.secondary.opacity(0.12)
        }
    }

    private var cardBackground: Color {
        switch tone {
        case .accent:
            return Color.accentColor.opacity(isHovering ? 0.11 : 0.08)
        case .neutral:
            return Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 0.92 : 0.75)
        }
    }

    private var cardStroke: Color {
        switch tone {
        case .accent:
            return Color.accentColor.opacity(isHovering ? 0.28 : 0.18)
        case .neutral:
            return Color.primary.opacity(isHovering ? 0.12 : 0.08)
        }
    }

    private var actionButtonForeground: Color {
        switch tone {
        case .accent:
            return .accentColor
        case .neutral:
            return .secondary
        }
    }

    private var actionButtonBackground: Color {
        switch tone {
        case .accent:
            return Color.accentColor.opacity(0.14)
        case .neutral:
            return Color.secondary.opacity(0.12)
        }
    }

    private var actionButtonStroke: Color {
        switch tone {
        case .accent:
            return Color.accentColor.opacity(0.28)
        case .neutral:
            return Color.primary.opacity(0.1)
        }
    }
}

struct SettingsStatusCard: View {
    enum Tone {
        case ready
        case working
        case caution
    }

    let title: String
    let status: String
    let detail: String
    let tone: Tone
    var progress: Double? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(tintColor)
                    .frame(width: 10, height: 10)

                Text(title)
                    .font(.headline)

                Spacer()

                Text(status)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tintColor)
                    .frame(
                        minWidth: progress == nil ? 0 : CGFloat(FirstRunOnboardingPolishContract.modelProgressLabelMinimumWidth),
                        alignment: .trailing
                    )
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .accessibilityLabel(Text(status))
            }

            if let actionTitle, let action {
                Button {
                    action()
                } label: {
                    Text(actionTitle)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(SettingsHoverButtonStyle(
                    tone: statusActionTone,
                    cornerRadius: 8,
                    normalFill: Color.primary.opacity(0.025),
                    normalStroke: Color.primary.opacity(0.06)
                ))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tintColor.opacity(0.16), lineWidth: 1)
        )
    }

    private var tintColor: Color {
        switch tone {
        case .ready:
            return .green
        case .working:
            return .blue
        case .caution:
            return .orange
        }
    }

    private var statusActionTone: SettingsInteractionTone {
        switch tone {
        case .ready:
            return .neutral
        case .working:
            return .accent
        case .caution:
            return .warning
        }
    }
}

struct SettingsActivityCard: View {
    let symbolName: String
    let title: String
    let status: String
    let detail: String
    let tone: HomeTranscriptionActivityPresentation.Tone
    let progress: Double?
    let actionTitle: String?
    let action: (() -> Void)?
    var dismissAction: (() -> Void)? = nil
    var cancelAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tintColor)
                    .frame(width: 34, height: 34)
                    .background(tintColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tintColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(tintColor.opacity(0.12), in: Capsule())

                if let dismissAction {
                    Button(action: dismissAction) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsHoverButtonStyle(cornerRadius: 7))
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                    .accessibilityIdentifier("transcripted.settings.activity-card.dismiss")
                }
            }

            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(tintColor)

                    Text("\(Int(progress * 100))% complete")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(
                            minWidth: CGFloat(FirstRunOnboardingPolishContract.modelProgressLabelMinimumWidth),
                            alignment: .leading
                        )
                }
            }

            if actionTitle != nil || cancelAction != nil {
                HStack(spacing: 10) {
                    if let actionTitle, let action {
                        Button {
                            action()
                        } label: {
                            Text(actionTitle)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(SettingsHoverButtonStyle(
                            tone: actionTone,
                            cornerRadius: 8,
                            normalFill: tintColor.opacity(0.08),
                            normalStroke: tintColor.opacity(0.14)
                        ))
                        .frame(minHeight: 40)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    if let cancelAction {
                        Button {
                            cancelAction()
                        } label: {
                            Text("Cancel")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(SettingsHoverButtonStyle(
                            tone: .destructive,
                            cornerRadius: 8,
                            normalFill: Color.primary.opacity(0.04),
                            normalStroke: Color.primary.opacity(0.12)
                        ))
                        .frame(minHeight: 40)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .help("Cancel this import and clean up partial files")
                        .accessibilityLabel("Cancel transcription")
                        .accessibilityIdentifier("transcripted.settings.activity-card.cancel")
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tintColor.opacity(0.18), lineWidth: 1)
        )
    }

    private var tintColor: Color {
        switch tone {
        case .working:
            return .blue
        case .success:
            return .green
        case .caution:
            return .orange
        }
    }

    private var actionTone: SettingsInteractionTone {
        switch tone {
        case .working:
            return .accent
        case .success:
            return .neutral
        case .caution:
            return .warning
        }
    }
}

struct SettingsQuickLinkRow: View {
    let symbolName: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .buttonStyle(SettingsHoverButtonStyle(cornerRadius: 10))
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var help: String? = nil
    var automationIdentifier: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .tint(.accentColor)
                .help(help ?? title)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(isOn ? "On" : "Off"))
                .accessibilityHint(Text(detail))
                .settingsAutomationIdentifier(automationIdentifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PermissionSnapshot {
    private(set) var values: [TranscriptedPermissionKind: Bool]

    subscript(kind: TranscriptedPermissionKind) -> Bool? {
        values[kind]
    }

    static func current() -> PermissionSnapshot {
        PermissionSnapshot(values: Dictionary(uniqueKeysWithValues: TranscriptedPermissionKind.allCases.map {
            ($0, TranscriptedPermissionAccess.isGranted($0))
        }))
    }
}

struct PermissionStatusRow: View {
    let kind: TranscriptedPermissionKind
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                Text(kind.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                action()
            } label: {
                Text(granted ? "Review" : kind.actionButtonTitle)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(SettingsHoverButtonStyle(
                tone: granted ? .neutral : .warning,
                cornerRadius: 8,
                normalFill: Color.primary.opacity(0.025),
                normalStroke: Color.primary.opacity(0.06)
            ))
            .accessibilityIdentifier("transcripted.settings.permissions.\(kind.rawValue).action")
        }
    }
}

struct StorageRow: View {
    let title: String
    let url: URL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Text("Show in Finder")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(SettingsHoverButtonStyle(
                cornerRadius: 8,
                normalFill: Color.primary.opacity(0.025),
                normalStroke: Color.primary.opacity(0.06)
            ))
        }
    }
}

struct ModelCacheMetricRow: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Text(value)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct HotkeyRecorderContainer: NSViewRepresentable {
    var dictationShortcutsEnabled = true
    static let preferredHeight: CGFloat = 140

    func makeNSView(context: Context) -> HotkeyRecorderAppKitView {
        let view = HotkeyRecorderAppKitView(frame: .zero)
        view.dictationShortcutsEnabled = dictationShortcutsEnabled
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderAppKitView, context: Context) {
        nsView.dictationShortcutsEnabled = dictationShortcutsEnabled
        nsView.refreshDisplay()
    }
}
