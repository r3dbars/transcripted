import AppKit
import SwiftUI

/// Window controller for the onboarding experience
/// Creates a centered, dark-themed window matching the product aesthetic
@available(macOS 26.0, *)
class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    private var onboardingState: OnboardingState
    private var onComplete: (() -> Void)?

    init(onComplete: @escaping () -> Void) {
        self.onboardingState = OnboardingState()
        self.onComplete = onComplete

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.delegate = self
        configureWindow(window)
        setupContentView()
    }

    // MARK: - NSWindowDelegate

    /// Intercept close during model download — show confirmation dialog
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if onboardingState.isLoadingModels {
            let alert = NSAlert()
            alert.messageText = "Download in Progress"
            alert.informativeText = "AI models are still downloading. If you close now, you can retry later from the menu bar settings."
            alert.addButton(withTitle: "Close Anyway")
            alert.addButton(withTitle: "Keep Downloading")
            alert.alertStyle = .warning

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                return false
            }
        }
        return true
    }

    /// Handle close button: persist completion and start the app so it doesn't end up in a dead state.
    func windowWillClose(_ notification: Notification) {
        onboardingState.completeOnboarding()
        onComplete?()
        onComplete = nil
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow(_ window: NSWindow) {
        window.center()
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        // Dark theme matching the product
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Color.panelCharcoal)
        window.isOpaque = true

        window.standardWindowButton(.closeButton)?.isHidden = false
        window.level = .floating

        // Fade in on appear
        window.alphaValue = 0
    }

    private func setupContentView() {
        guard let window = self.window else { return }

        let containerView = OnboardingContainerView(
            state: onboardingState,
            onComplete: { [weak self] in
                self?.handleOnboardingComplete()
            }
        )

        let hostingView = NSHostingView(rootView: containerView)
        window.contentView = hostingView
    }

    func showWithAnimation() {
        guard let window = self.window else { return }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func handleOnboardingComplete() {
        guard let window = self.window else { return }
        guard onComplete != nil else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.onComplete?()
            self?.onComplete = nil
        })
    }
}

// MARK: - Preview Helper

#if DEBUG
@available(macOS 26.0, *)
struct OnboardingWindow_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingContainerView(
            state: OnboardingState(),
            onComplete: {}
        )
        .frame(width: 640, height: 560)
        .background(Color.panelCharcoal)
    }
}
#endif
