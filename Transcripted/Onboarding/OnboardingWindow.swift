import AppKit
import SwiftUI

/// Window controller for the onboarding experience
/// Creates a centered, borderless window with the onboarding flow
@available(macOS 26.0, *)
class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    private var onboardingState: OnboardingState
    private var onComplete: (() -> Void)?

    init(onComplete: @escaping () -> Void) {
        self.onboardingState = OnboardingState()
        self.onComplete = onComplete

        // Create the window
        // Size: 720x680 to comfortably fit all onboarding content
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
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
                return false  // User chose to keep downloading
            }
        }
        return true
    }

    /// Handle close button: treat as "skip onboarding" so the app doesn't end up in a dead state.
    /// Without this, closing the window leaves no menu bar, no floating panel — just an invisible process.
    func windowWillClose(_ notification: Notification) {
        onComplete?()
        onComplete = nil  // Prevent double-fire from handleOnboardingComplete
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow(_ window: NSWindow) {
        // Window appearance
        window.center()
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        // Frosted glass background (matching pill aesthetic)
        window.isOpaque = false
        window.backgroundColor = .clear

        // Allow closing onboarding (UX: Zeigarnik Effect - don't trap users)
        // Users can access settings later from the menu bar
        window.standardWindowButton(.closeButton)?.isHidden = false

        // Window level - appears above other windows
        window.level = .floating

        // Animation on appear
        window.alphaValue = 0
    }

    private func addFrostedGlassBackground(to window: NSWindow) {
        guard let contentView = window.contentView else { return }

        // Create visual effect view for frosted glass
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.translatesAutoresizingMaskIntoConstraints = false

        // Insert behind content
        contentView.addSubview(visualEffect, positioned: .below, relativeTo: nil)

        // Fill the content view
        NSLayoutConstraint.activate([
            visualEffect.topAnchor.constraint(equalTo: contentView.topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            visualEffect.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
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

        // Add frosted glass background behind SwiftUI content
        addFrostedGlassBackground(to: window)
    }

    func showWithAnimation() {
        guard let window = self.window else { return }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        // Fade in animation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func handleOnboardingComplete() {
        guard let window = self.window else { return }
        guard onComplete != nil else { return }  // Already handled (e.g., via windowWillClose)

        // Fade out animation
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
        .frame(width: 720, height: 680)
    }
}
#endif
