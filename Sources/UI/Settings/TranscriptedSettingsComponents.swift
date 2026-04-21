import AppKit
import SwiftUI

struct SettingsPageIntro: View {
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))

            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    let action: () -> Void

    init(
        symbolName: String,
        title: String,
        detail: String,
        tone: Tone = .neutral,
        menuBarVisibility: Binding<Bool>? = nil,
        action: @escaping () -> Void
    ) {
        self.symbolName = symbolName
        self.title = title
        self.detail = detail
        self.tone = tone
        self.menuBarVisibility = menuBarVisibility
        self.action = action
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: action) {
                actionContent
            }
            .buttonStyle(.plain)

            if let menuBarVisibility {
                Toggle("Show in menu bar", isOn: menuBarVisibility)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Show in menu bar")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cardStroke, lineWidth: 1)
        )
    }

    private var actionContent: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(iconBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
            return Color.accentColor.opacity(0.08)
        case .neutral:
            return Color(nsColor: .controlBackgroundColor).opacity(0.75)
        }
    }

    private var cardStroke: Color {
        switch tone {
        case .accent:
            return Color.accentColor.opacity(0.18)
        case .neutral:
            return Color.primary.opacity(0.08)
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
                    .foregroundStyle(tintColor)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            }

            if let progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(tintColor)

                    Text("\(Int(progress * 100))% complete")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
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
        }
        .buttonStyle(.plain)
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

            Button(granted ? "Review" : kind.actionButtonTitle) {
                action()
            }
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

            Button("Show in Finder") {
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

struct HotkeyRecorderContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> HotkeyRecorderAppKitView {
        HotkeyRecorderAppKitView(frame: .zero)
    }

    func updateNSView(_ nsView: HotkeyRecorderAppKitView, context: Context) {
        nsView.refreshDisplay()
    }
}
