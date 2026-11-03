import AppKit
import SwiftUI

@MainActor
func testFileTranscriptionPage() async {
    runSuite("File transcription is a primary sidebar destination without changing existing shortcuts") {
        assertTrue(SettingsSidebarSection.primarySection.pages.contains(.files))
        assertFalse(SettingsSidebarSection.isSettingsPage(.files))
        assertEqual(TranscriptedSettingsPage.files.title, "Transcribe a file")
        assertEqual(TranscriptedSettingsPage.files.automationIdentifier, "transcripted.settings.sidebar.files")
        assertEqual(TranscriptedSettingsPage.files.telemetryDestination, .files)
        assertTrue(NSImage(systemSymbolName: TranscriptedSettingsPage.files.systemImage, accessibilityDescription: nil) != nil,
                   "the sidebar icon must exist on this macOS")
        assertEqual(TranscriptedSettingsPage.files.navigationShortcutKey, nil,
                    "the existing ⌘O import command remains the keyboard entry")
        assertEqual(SettingsRecentCaptureRefreshPolicy.mode(for: .files), .none,
                    "file import does not start another library scan")
        assertEqual(FileTranscriptionSettingsPage<EmptyView>.cliDocumentationURL,
                    URL(string: "https://github.com/r3dbars/transcripted/blob/main/Tools/TranscriptedCLI/README.md")!,
                    "the page links to the existing CLI import instructions")
    }
}
