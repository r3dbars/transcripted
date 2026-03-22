import AppKit
import SwiftUI

// MARK: - Window Lifecycle Management

@available(macOS 26.0, *)
extension AppDelegate {

    @objc func statusBarClicked() {
        // Menu shows automatically
    }

    @objc func toggleWindow() {
        if let window = floatingPanel?.window {
            window.isVisible ? window.orderOut(nil) : window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func openTranscriptsFolder() {
        NSWorkspace.shared.open(TranscriptSaver.defaultSaveDirectory)
    }

    @objc func openFailedTranscriptions() {
        guard let ftm = failedTranscriptionManager, let tm = taskManager else {
            AppLogger.app.error("Cannot open failed transcriptions — managers not initialized")
            let alert = NSAlert()
            alert.messageText = "Unable to Open"
            alert.informativeText = "The app has not finished initializing. Please try again in a moment."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        if failedTranscriptionsWindow == nil {
            let view = FailedTranscriptionsView(
                failedManager: ftm,
                taskManager: tm
            )
            let controller = NSHostingController(rootView: view)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.title = "Failed Transcriptions"
            window.center()
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 600, height: 400)

            failedTranscriptionsWindow = window
        }

        failedTranscriptionsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                failedTranscriptionManager: failedTranscriptionManager,
                taskManager: taskManager
            )
        }

        settingsWindowController?.showWindow()
    }

    #if canImport(Sparkle)
    @objc func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
    #endif

    @objc func exportDiagnostics() {
        DiagnosticExporter.exportDiagnostics()
    }

    @objc func reportIssue() {
        DiagnosticExporter.reportIssue()
    }
}
