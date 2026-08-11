import AppKit
import SwiftUI

/// Wraps a `@State` mirror binding so writing a new value also fires settings
/// telemetry, persists it, and optionally runs a further side effect, in that
/// fixed order: mirror -> track -> persist -> sideEffect. This fixed order is
/// only safe when `track` and `persist` are independent of each other — i.e.
/// telemetry doesn't read back whatever `persist` just wrote. That does NOT
/// hold for every settings toggle: `AnalyticsReporter.trackEvent` drops any
/// event fired while `AnalyticsPreferences` reads disabled, so the anonymous-
/// analytics toggle's own transition event needs `persist` before `track` on
/// enable (and the reverse on disable) — that site is intentionally left as a
/// hand-written `Binding(get:set:)` rather than routed through this helper.
///
/// Centralizes the "read local mirror -> track telemetry -> persist to
/// preferences" triple that `TranscriptedSettingsView` otherwise hand-writes
/// at each settings toggle/picker site. Sites with branching, multi-step, or
/// order-dependent side effects beyond a single trailing closure are left as
/// hand-written `Binding(get:set:)` blocks rather than forced through this
/// helper.
func persistedSettingsBinding<Value>(
    _ state: Binding<Value>,
    persist: @escaping (Value) -> Void,
    track: ((Value) -> Void)? = nil,
    sideEffect: ((Value) -> Void)? = nil
) -> Binding<Value> {
    Binding(
        get: { state.wrappedValue },
        set: { newValue in
            state.wrappedValue = newValue
            track?(newValue)
            persist(newValue)
            sideEffect?(newValue)
        }
    )
}

struct SettingsPageIntro: View {
    let title: String
    var summary: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: summaryText == nil ? 0 : 8) {
            Text(title)
                .font(LibraryTokens.title)

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
