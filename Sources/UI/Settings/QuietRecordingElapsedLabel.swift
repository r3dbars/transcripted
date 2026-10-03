import SwiftUI

/// Home's "Recording · 12:34" line. It reads the shell's
/// `SettingsRecordingClock` from the environment, so the once-a-second tick
/// redraws only this label. `fallback` is the text the row was built with,
/// shown when no clock is in the environment.
struct QuietRecordingElapsedLabel: View {
    let fallback: String
    @Environment(SettingsRecordingClock.self) private var clock: SettingsRecordingClock?

    var body: some View {
        let elapsed = clock?.elapsedText ?? fallback
        HStack(spacing: 8) {
            Circle()
                .fill(LibraryTokens.recording)
                .frame(width: 7, height: 7)
            Text("Recording")
                .font(LibraryTokens.rowTitle)
            Text("·  \(elapsed)")
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording, \(elapsed) elapsed")
    }
}
