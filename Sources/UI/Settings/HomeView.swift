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
    /// A check mark beside the title (Keep audio on).
    let isChecked: Bool
    /// Menu line, Option-alternate of the line above, or not in the menu at
    /// all (the card's issue line shows it). See `HomeRowMenuPlacement`.
    let placement: HomeRowMenuPlacement
    let toolTip: String?
    let action: () -> Void

    init(
        title: String,
        symbolName: String,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        automationIdentifier: String? = nil,
        isChecked: Bool = false,
        placement: HomeRowMenuPlacement = .menu,
        toolTip: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.automationIdentifier = automationIdentifier
        self.isChecked = isChecked
        self.placement = placement
        self.toolTip = toolTip
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
            for item in items where item.placement != .issueLine {
                let menuItem = ClosureMenuItem(menuItem: item)
                // No key equivalents here; an empty mask lets an Option
                // alternate pair with the line above it.
                menuItem.keyEquivalentModifierMask = []
                if item.placement == .optionAlternate {
                    menuItem.isAlternate = true
                    menuItem.keyEquivalentModifierMask = [.option]
                }
                if item.isChecked {
                    menuItem.state = .on
                }
                menuItem.toolTip = item.toolTip
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
            let handler = MainQueueHandler(run: self.handler)
            DispatchQueue.main.async { [handler] in handler() }
        }

        /// Carries the handler across the main-to-main hop above. `invoke` runs
        /// on main (AppKit menu action) and the block runs on `DispatchQueue.main`,
        /// so the non-Sendable closure never leaves the main thread.
        private struct MainQueueHandler: @unchecked Sendable {
            let run: () -> Void

            func callAsFunction() { run() }
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

/// A failed or unfinished meeting, drawn as the same card as a saved one:
/// play (when audio was kept) · title · time, one amber line saying what
/// happened, and an ink Try again. Show in Finder and Delete live in ⋯.
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let audioAttachment {
                    HomeMeetingPlayButton(
                        audio: audioAttachment,
                        automationIdentifier: "transcripted.home.failed-meeting.play-audio"
                    )
                }

                Text(item.title)
                    .font(TextRole.body.font(weight: .semibold))
                    .foregroundStyle(LibraryTokens.ink)
                    .lineLimit(1)
                    .layoutPriority(1)

                Text(HomeActivityRowFormatting.timeFormatter.string(from: item.timestamp))
                    .font(LibraryTokens.meta)
                    .monospacedDigit()
                    .foregroundStyle(LibraryTokens.ink3)
                    .lineLimit(1)

                Spacer(minLength: 8)

                HomeRowMoreMenuButton(items: menuItems, automationIdentifier: "transcripted.home.failed-meeting.more")
                    .frame(width: HomeHitTarget.minimum, height: 22)
                    .help("More options")
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)

                if presentation.canShowRetryAction {
                    HomeAttentionActionButton(
                        title: item.isRetrying ? "Retrying" : "Try again",
                        isDisabled: rowActions.retryDisabled,
                        automationIdentifier: "transcripted.home.failed-meeting.retry",
                        action: onRetry
                    )
                    .help(retryHelp)
                }
            }
            .frame(minHeight: 22)

            issueLine(presentation: presentation)
        }
        .homeMeetingCardSurface(isHovering: isHovering)
        .help(item.detail)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .accessibilityElement(children: .contain)
        .modifier(HomeMeetingMenuAccessibilityActions(items: menuItems))
    }

    /// Show in Finder (the kept audio) and Delete.
    private var menuItems: [HomeRowMenuItem] {
        var items: [HomeRowMenuItem] = []
        if rowActions.showsRevealAudio {
            items.append(HomeRowMenuItem(
                title: "Show in Finder",
                symbolName: "folder",
                automationIdentifier: "transcripted.home.failed-meeting.show-audio",
                toolTip: "Show the saved audio in Finder",
                action: onRevealAudio
            ))
        }
        items.append(HomeRowMenuItem(
            title: rowActions.deleteTitle,
            symbolName: "trash",
            isEnabled: !rowActions.deleteDisabled,
            isDestructive: rowActions.deleteIsDestructive,
            action: onClear
        ))
        return items
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

    /// "Not transcribed · Your audio is saved…" in the attention color. The
    /// status leads; the reason follows in secondary ink.
    private func issueLine(presentation: HomeFailedMeetingInlinePresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if item.isRetrying {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(presentation.statusText)
                .foregroundStyle(item.isRetrying ? LibraryTokens.ink2 : LibraryTokens.attention)
                .accessibilityLabel(presentation.statusText)
            if let detail = presentation.inlineDetail {
                Text("\u{00B7}")
                    .foregroundStyle(LibraryTokens.ink3)
                    .accessibilityHidden(true)
                Text(detail)
                    .foregroundStyle(LibraryTokens.ink2)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(LibraryTokens.meta)
        .padding(.leading, audioAttachment == nil ? 0 : 32)
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

/// "Try again" on a failed meeting: the row's one primary action, so it's
/// the shared ink primary, not red (red is for losing something).
private struct HomeAttentionActionButton: View {
    let title: String
    let isDisabled: Bool
    var automationIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(.transcriptedPrimary)
        .controlSize(.small)
        .disabled(isDisabled)
        .homeAutomationIdentifier(automationIdentifier)
    }
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
                Text(isLoading ? "Loading\u{2026}" : title)
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
