import AppKit
import SwiftUI
import TranscriptedCore

// MARK: - Row actions

struct HomeRowMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let symbolName: String
    let isEnabled: Bool
    let isDestructive: Bool
    /// Optional AX/automation hook for a single item inside the ⋯ menu. The
    /// menu button itself only carries one identifier for the whole menu, so
    /// actions that automation needs to target by name (Rename) set this.
    let automationIdentifier: String?
    let action: () -> Void

    init(
        title: String,
        symbolName: String,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        automationIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.automationIdentifier = automationIdentifier
        self.action = action
    }
}

struct HomeRowActionButtons: View {
    let isCopied: Bool
    let onCopy: () -> Void
    let menuItems: [HomeRowMenuItem]
    var leadingAccessory: AnyView? = nil
    /// Page-scoped so AX/automation can tell the Home meeting row's Copy
    /// apart from the Dictations row's Copy.
    var copyAutomationIdentifier = "transcripted.home.row.copy"

    var body: some View {
        HStack(spacing: 4) {
            if let leadingAccessory {
                leadingAccessory
            }

            iconButton(
                systemName: isCopied ? "checkmark" : "square.on.square",
                help: isCopied ? "Copied" : "Copy",
                action: onCopy
            )

            if !menuItems.isEmpty {
                HomeRowMoreMenuButton(items: menuItems)
                    .frame(width: HomeHitTarget.minimum, height: HomeHitTarget.minimum)
                    .help("More options")
            }
        }
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(HomeCompactIconButtonStyle())
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityIdentifier(copyAutomationIdentifier)
    }
}

struct HomeRowMoreMenuButton: NSViewRepresentable {
    let items: [HomeRowMenuItem]
    var automationIdentifier = "transcripted.home.row.more"

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = HoverMenuButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "More options"
        )
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.retainedActionTarget = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setButtonType(.momentaryChange)
        button.setAccessibilityLabel("More options")
        button.identifier = NSUserInterfaceItemIdentifier(automationIdentifier)
        button.setAccessibilityIdentifier(automationIdentifier)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        if let hoverButton = button as? HoverMenuButton {
            hoverButton.retainedActionTarget = context.coordinator
        }
        button.target = context.coordinator
        button.isEnabled = !items.isEmpty
        button.identifier = NSUserInterfaceItemIdentifier(automationIdentifier)
        button.setAccessibilityIdentifier(automationIdentifier)
    }

    final class Coordinator: NSObject {
        var items: [HomeRowMenuItem]

        init(items: [HomeRowMenuItem]) {
            self.items = items
        }

        @MainActor @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            // Without this, AppKit auto-enables every item whose target responds
            // to the action, overriding the per-item isEnabled set below.
            menu.autoenablesItems = false
            for item in items {
                let menuItem = ClosureMenuItem(menuItem: item)
                if let image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title) {
                    image.isTemplate = true
                    menuItem.image = image.withSymbolConfiguration(
                        NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                    )
                }
                if item.isDestructive {
                    menuItem.attributedTitle = NSAttributedString(
                        string: item.title,
                        attributes: [.foregroundColor: NSColor.systemRed]
                    )
                }
                if let automationIdentifier = item.automationIdentifier {
                    menuItem.identifier = NSUserInterfaceItemIdentifier(automationIdentifier)
                    menuItem.setAccessibilityIdentifier(automationIdentifier)
                }
                menu.addItem(menuItem)
            }

            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
        }
    }

    /// A menu item that owns its action closure and acts as its own target.
    ///
    /// Two things have to hold for a handler to both fire *and* be able to drive
    /// SwiftUI presentation:
    ///   1. The item owns its handler instead of pointing `NSMenuItem.target` at
    ///      a separately, weakly-retained object. The `NSMenu` retains its items
    ///      for the whole `popUp` tracking loop, so the handler can't be torn
    ///      down with the SwiftUI coordinator while the menu is open. (The old
    ///      design's weak target could deallocate first, so closures silently
    ///      never fired — delete, reveal, and report all no-op'd.)
    ///   2. The handler runs on the next main-runloop turn, *after* `popUp`'s
    ///      modal tracking loop exits. A handler that mutates SwiftUI state to
    ///      present an `.alert(item:)`/`.sheet(item:)` (e.g. the Home delete
    ///      confirmation) won't present if it runs synchronously inside that
    ///      loop. The async block captures `handler` strongly, so deferring is
    ///      safe here — the dealloc trap from (1) does not reappear.
    final class ClosureMenuItem: NSMenuItem {
        private let handler: () -> Void

        init(menuItem: HomeRowMenuItem) {
            self.handler = menuItem.action
            super.init(title: menuItem.title, action: #selector(invoke), keyEquivalent: "")
            target = self
            isEnabled = menuItem.isEnabled
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func invoke() {
            guard isEnabled else { return }
            DispatchQueue.main.async { [handler] in handler() }
        }
    }

    final class HoverMenuButton: NSButton {
        var retainedActionTarget: AnyObject?
        private var trackingAreaRef: NSTrackingArea?
        private var hoverBackgroundLayer: CALayer?
        private var isHovering = false {
            didSet { updateAppearance() }
        }

        override var isHighlighted: Bool {
            didSet { updateAppearance() }
        }

        override var isEnabled: Bool {
            didSet { updateAppearance() }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func layout() {
            super.layout()
            layoutHoverBackgroundLayer()
        }

        override func mouseEntered(with event: NSEvent) {
            guard isEnabled else { return }
            isHovering = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovering = false
        }

        private func updateAppearance() {
            layoutHoverBackgroundLayer()
            guard isEnabled else {
                layer?.backgroundColor = NSColor.clear.cgColor
                hoverBackgroundLayer?.backgroundColor = NSColor.clear.cgColor
                alphaValue = 0.55
                return
            }

            alphaValue = 1
            let color: NSColor
            if isHighlighted {
                color = NSColor.labelColor.withAlphaComponent(0.07)
            } else if isHovering {
                color = NSColor.labelColor.withAlphaComponent(0.04)
            } else {
                color = .clear
            }
            layer?.backgroundColor = NSColor.clear.cgColor
            hoverBackgroundLayer?.backgroundColor = color.cgColor
        }

        private func layoutHoverBackgroundLayer() {
            guard wantsLayer, let layer else { return }
            let backgroundLayer: CALayer
            if let hoverBackgroundLayer {
                backgroundLayer = hoverBackgroundLayer
            } else {
                let createdLayer = CALayer()
                createdLayer.cornerRadius = 7
                layer.insertSublayer(createdLayer, at: 0)
                hoverBackgroundLayer = createdLayer
                backgroundLayer = createdLayer
            }

            let size = HomeHitTarget.compactVisibleSize
            backgroundLayer.frame = CGRect(
                x: floor((bounds.width - size) / 2),
                y: floor((bounds.height - size) / 2),
                width: size,
                height: size
            )
        }
    }
}

// MARK: - Failed meeting row

/// Play/pause for a failed row's kept audio. It alone observes the shared
/// player, which publishes a few times a second while audio plays, so only
/// this button re-renders on those ticks instead of every failed row.
private struct HomeFailedMeetingPlayAudioButton: View {
    let audioAttachment: MeetingAudioAttachment

    @ObservedObject private var playback = MeetingAudioPlayback.shared

    var body: some View {
        Button {
            playback.toggle(audioAttachment)
        } label: {
            Label(
                playback.isActive(audioAttachment) ? "Pause audio" : "Play audio",
                systemImage: playback.isActive(audioAttachment) ? "pause.fill" : "play.fill"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Play this meeting's audio")
        .accessibilityIdentifier("transcripted.home.failed-meeting.play-audio")
    }
}

struct HomeFailedMeetingInlineRow: View {
    let item: MeetingSessionController.FailedMeetingItem
    let canRetry: Bool
    let retryUnavailableReason: String?
    let onRetry: () -> Void
    let onRevealAudio: () -> Void
    let onClear: () -> Void
    /// Kept audio playback for the failed capture (the row is the only
    /// surface for it since the failed-meetings card was retired). `nil`
    /// hides the control.
    var audioAttachment: MeetingAudioAttachment? = nil

    @State private var isHovering = false

    var body: some View {
        let presentation = inlinePresentation
        HStack(alignment: .top, spacing: 14) {
            Text(HomeActivityRowFormatting.timeFormatter.string(from: item.timestamp))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                statusLine(presentation: presentation)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.detail)

            actions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.035) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// Try again stays visible: it is the one thing this row is for. The
    /// rest (play, show audio, delete) reveal on hover like other rows.
    private var actions: some View {
        HStack(spacing: 6) {
            hoverActions
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .animation(.easeOut(duration: 0.12), value: isHovering)

            if inlinePresentation.canShowRetryAction {
                HomeAttentionActionButton(
                    title: item.isRetrying ? "Retrying" : "Try again",
                    isDisabled: rowActions.retryDisabled,
                    automationIdentifier: "transcripted.home.failed-meeting.retry",
                    action: onRetry
                )
                .help(retryHelp)
            }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            if let audioAttachment {
                HomeFailedMeetingPlayAudioButton(audioAttachment: audioAttachment)
            }

            if rowActions.showsRevealAudio {
                Button {
                    onRevealAudio()
                } label: {
                    Label("Show Audio", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show saved audio in Finder")
                .accessibilityIdentifier("transcripted.home.failed-meeting.show-audio")
            }

            HomeRowMoreMenuButton(items: [
                HomeRowMenuItem(
                    title: rowActions.deleteTitle,
                    symbolName: "trash",
                    isDestructive: rowActions.deleteIsDestructive,
                    action: onClear
                )
            ], automationIdentifier: "transcripted.home.failed-meeting.more")
            .frame(width: HomeHitTarget.minimum, height: HomeHitTarget.minimum)
            .help("More options")
        }
    }

    private var inlinePresentation: HomeFailedMeetingInlinePresentation {
        HomeFailedMeetingInlinePresentation.make(
            isRetryable: item.isRetryable,
            isRetrying: item.isRetrying,
            hasAudioFiles: item.hasAudioFiles,
            detail: item.detail,
            usableAudio: item.usableAudio,
            failureKind: item.failureKind
        )
    }

    private func statusLine(presentation: HomeFailedMeetingInlinePresentation) -> some View {
        // Red is for rows that can't be retried; a retry-ready row is
        // recoverable, so its chip stays neutral.
        let chipTint = presentation.canShowRetryAction ? Color.secondary : Color.red
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(presentation.statusText)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(chipTint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(chipTint.opacity(0.12))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(chipTint.opacity(0.18), lineWidth: 1)
                )
                .accessibilityLabel(presentation.statusText)

            if let detail = presentation.inlineDetail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rowActions: HomeFailedMeetingRowActions {
        HomeFailedMeetingRowActions.make(item: item, canRetry: canRetry)
    }

    private var retryHelp: String {
        FailedMeetingRecoveryPresentation.retryHelp(
            canRetry: canRetry,
            retryUnavailableReason: retryUnavailableReason,
            isRetryable: item.isRetryable,
            isRetrying: item.isRetrying,
            hasAudioFiles: item.hasAudioFiles,
            usableAudio: item.usableAudio
        )
    }
}

private struct HomeAttentionActionButton: View {
    let title: String
    let isDisabled: Bool
    var tint: Color = .red
    var automationIdentifier: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: isHovering && !isDisabled ? 5 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .homeAutomationIdentifier(automationIdentifier)
    }

    private var foregroundColor: Color {
        isDisabled ? tint.opacity(0.55) : Color.white
    }

    private var backgroundColor: Color {
        if isDisabled {
            return tint.opacity(0.12)
        }
        return tint.opacity(isHovering ? 0.9 : 0.78)
    }

    private var borderColor: Color {
        isDisabled ? tint.opacity(0.16) : Color.white.opacity(0.14)
    }

    private var shadowColor: Color {
        isDisabled ? Color.clear : tint.opacity(0.16)
    }
}

enum HomeHitTarget {
    static let minimum: CGFloat = 40
    static let compactVisibleSize: CGFloat = 26
}

private struct HomeCompactIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(width: HomeHitTarget.compactVisibleSize, height: HomeHitTarget.compactVisibleSize)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(strokeColor, lineWidth: 1)
                )
                .frame(width: HomeHitTarget.minimum, height: HomeHitTarget.minimum)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.55)
                .onHover { isHovering = $0 }
        }

        private var backgroundColor: Color {
            if configuration.isPressed {
                return Color.primary.opacity(0.10)
            }
            if isHovering {
                return Color.primary.opacity(0.06)
            }
            return Color.clear
        }

        private var strokeColor: Color {
            configuration.isPressed || isHovering ? Color.primary.opacity(0.08) : Color.clear
        }
    }
}

private extension View {
    @ViewBuilder
    func homeAutomationIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

// MARK: - Row feedback

struct HomeFeedbackSheet: View {
    let target: HomeFeedbackTarget
    let onCancel: () -> Void
    let onSubmit: (HomeFeedbackSubmission) -> Void

    @State private var issueKind: HomeFeedbackIssueKind
    @State private var notes = ""
    @State private var includeDiagnostics = true

    init(
        target: HomeFeedbackTarget,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (HomeFeedbackSubmission) -> Void
    ) {
        self.target = target
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _issueKind = State(initialValue: target.suggestedIssue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Report an issue")
                    .font(.system(size: 22, weight: .semibold))
                Text(target.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Issue")
                    .font(.subheadline.weight(.semibold))
                HomeIssueKindSelector(selection: $issueKind)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What happened?")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }

            Toggle("Include safe diagnostics", isOn: $includeDiagnostics)

            Text("Transcripted attaches the capture type, time, app version, a private reference ID, and recent scrubbed logs. It does not attach transcript text, audio, file paths, meeting titles, emails, or raw URLs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                SettingsInlineActionButton(title: "Cancel", action: onCancel)
                Spacer()
                SettingsInlineActionButton(title: "Review report", tone: .accent) {
                    onSubmit(HomeFeedbackSubmission(
                        target: target,
                        issueKind: issueKind,
                        notes: notes,
                        includeDiagnostics: includeDiagnostics
                    ))
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct HomeIssueKindSelector: View {
    @Binding var selection: HomeFeedbackIssueKind

    private let columns = [
        GridItem(.flexible(minimum: 140), spacing: 8),
        GridItem(.flexible(minimum: 140), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(HomeFeedbackIssueKind.allCases) { kind in
                HomeIssueKindButton(
                    kind: kind,
                    isSelected: selection == kind
                ) {
                    selection = kind
                }
            }
        }
    }
}

private struct HomeIssueKindButton: View {
    let kind: HomeFeedbackIssueKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(kind.label)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SettingsHoverButtonStyle(
            tone: isSelected ? .accent : .neutral,
            cornerRadius: 8,
            normalFill: background,
            normalStroke: stroke
        ))
    }

    private var background: Color {
        isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035)
    }

    private var stroke: Color {
        isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)
    }
}

// MARK: - Load more / failed meetings

struct HomeLoadMoreButton: View {
    let title: String
    let isLoading: Bool
    var automationIdentifier = "transcripted.home.load-more"
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack {
            Spacer(minLength: 0)

            Button(action: action) {
                Text(isLoading ? "Loading..." : title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isLoading ? Color.secondary : Color.secondary.opacity(isHovering ? 1 : 0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .accessibilityIdentifier(automationIdentifier)

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}
