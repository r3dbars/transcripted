import SwiftUI
import AppKit

@MainActor
final class TranscriptedOnboardingWindowController: NSWindowController {
    private let makeView: () -> PermissionsOnboardingView
    private let onPresent: (String) -> Void
    private let hostingController: NSHostingController<PermissionsOnboardingView>

    init(
        makeView: @escaping () -> PermissionsOnboardingView,
        onPresent: @escaping (String) -> Void = { _ in }
    ) {
        self.makeView = makeView
        self.onPresent = onPresent
        self.hostingController = NSHostingController(
            rootView: makeView()
        )

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PermissionsOnboardingView.preferredSize.width,
                height: PermissionsOnboardingView.preferredSize.height
            ),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Transcripted"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = PermissionsOnboardingView.preferredSize
        window.contentViewController = hostingController
        window.center()
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func present(entrypoint: String = "unknown") {
        guard let window else { return }
        let wasVisible = window.isVisible
        hostingController.rootView = makeView()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !wasVisible {
            onPresent(entrypoint)
        }
    }

    func dismiss() {
        window?.close()
    }
}
