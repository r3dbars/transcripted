import AppKit
import SwiftUI

@MainActor
final class AgentConnectionWindowCoordinator {
    static let shared = AgentConnectionWindowCoordinator()

    private var windowController: AgentConnectionWindowController?

    func show() {
        show(meetingTitle: nil, meetingDate: nil, transcriptURL: nil)
    }

    func show(for meeting: RecentMeetingItem?) {
        show(
            meetingTitle: meeting?.title,
            meetingDate: meeting?.date,
            transcriptURL: meeting?.transcriptURL
        )
    }

    func show(meetingTitle: String?, meetingDate: Date?, transcriptURL: URL?) {
        let context = AgentConnectionContext(
            meetingTitle: meetingTitle,
            meetingDate: meetingDate,
            transcriptURL: transcriptURL
        )

        if let windowController {
            windowController.update(context: context)
            windowController.showConnectionWindow()
            return
        }

        let controller = AgentConnectionWindowController(context: context)
        windowController = controller
        controller.showConnectionWindow()
    }
}

@MainActor
final class AgentConnectionWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: AgentConnectionViewModel

    init(context: AgentConnectionContext) {
        self.viewModel = AgentConnectionViewModel(context: context)

        let frame = NSRect(x: 0, y: 0, width: 680, height: 760)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        configureWindow(window)
        setupContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureWindow(_ window: NSWindow) {
        window.title = "Connect your agent"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = MenuTokens.surfaceBackgroundNS
        window.minSize = NSSize(width: 620, height: 620)
        window.maxSize = NSSize(width: 960, height: 1040)
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.delegate = self
    }

    private func setupContentView() {
        guard let window else { return }

        let hostingView = NSHostingView(
            rootView: AgentConnectionWindowView(viewModel: viewModel)
        )
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
    }

    func update(context: AgentConnectionContext) {
        viewModel.context = context
    }

    func showConnectionWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
