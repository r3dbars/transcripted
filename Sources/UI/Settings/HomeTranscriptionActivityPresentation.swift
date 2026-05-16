import Foundation
import TranscriptedCore

struct HomeTranscriptionActivityPresentation: Equatable {
    enum Tone: Equatable {
        case working
        case success
        case caution
    }

    let symbolName: String
    let title: String
    let status: String
    let detail: String
    let tone: Tone
    let progress: Double?
    let transcriptURL: URL?

    static func make(
        sessionState: MeetingSessionController.State,
        displayStatus: DisplayStatus,
        warmupStatus: MeetingSessionController.ModelWarmupStatus,
        lastSavedTitle: String?,
        lastSavedTranscriptURL: URL?
    ) -> HomeTranscriptionActivityPresentation? {
        switch displayStatus {
        case .gettingReady:
            return HomeTranscriptionActivityPresentation(
                symbolName: "tray.and.arrow.down.fill",
                title: "Preparing local transcription",
                status: "Preparing...",
                detail: "Transcripted is loading the saved audio and getting the local model ready to transcribe.",
                tone: .working,
                progress: displayStatus.progress,
                transcriptURL: nil
            )
        case .transcribing:
            return HomeTranscriptionActivityPresentation(
                symbolName: "waveform.badge.magnifyingglass",
                title: "Local model transcribing",
                status: displayStatus.statusText,
                detail: "Transcripted is running the local model on this audio. Longer files can take a bit.",
                tone: .working,
                progress: displayStatus.progress,
                transcriptURL: nil
            )
        case .finishing:
            return HomeTranscriptionActivityPresentation(
                symbolName: "square.and.arrow.down.fill",
                title: "Saving transcript",
                status: displayStatus.statusText,
                detail: "Transcripted is writing the transcript now. If speaker review appears next, you can save names or choose Review Later.",
                tone: .working,
                progress: displayStatus.progress,
                transcriptURL: nil
            )
        case .transcriptSaved:
            let transcriptURL = lastSavedTranscriptURL
            let transcriptName = resolvedTranscriptName(
                lastSavedTitle: lastSavedTitle,
                transcriptURL: transcriptURL
            )
            let detail: String
            if let transcriptName {
                detail = "\"\(transcriptName)\" is ready. Open it now, or finish any deferred speaker names later in People."
            } else {
                detail = "Your transcript is ready. Open it now, or finish any deferred speaker names later in People."
            }

            return HomeTranscriptionActivityPresentation(
                symbolName: "checkmark.circle.fill",
                title: "Transcript saved",
                status: "Ready to review",
                detail: detail,
                tone: .success,
                progress: 1.0,
                transcriptURL: transcriptURL
            )
        case .failed(let message):
            let copy = MeetingFailureCopy.make(
                forMessage: message,
                shortErrorMessage: message,
                isRetryable: true
            )
            return HomeTranscriptionActivityPresentation(
                symbolName: "exclamationmark.triangle.fill",
                title: copy.title,
                status: "Needs attention",
                detail: copy.detail,
                tone: .caution,
                progress: nil,
                transcriptURL: nil
            )
        case .idle:
            break
        }

        switch sessionState {
        case .loadingModels:
            let detail = warmupStatus.detail.isEmpty
                ? "Transcripted is loading the local models it needs before transcription can start."
                : warmupStatus.detail
            return HomeTranscriptionActivityPresentation(
                symbolName: "gearshape.2.fill",
                title: warmupStatus.subtitle,
                status: "Preparing...",
                detail: detail,
                tone: .working,
                progress: max(0.05, min(warmupStatus.progress, 0.92)),
                transcriptURL: nil
            )
        case .error(let message):
            return HomeTranscriptionActivityPresentation(
                symbolName: "exclamationmark.circle.fill",
                title: "Couldn't start that action",
                status: "Needs attention",
                detail: message,
                tone: .caution,
                progress: nil,
                transcriptURL: nil
            )
        case .idle, .ready, .recording, .transcribing:
            return nil
        }
    }

    private static func resolvedTranscriptName(lastSavedTitle: String?, transcriptURL: URL?) -> String? {
        if let lastSavedTitle, !lastSavedTitle.isEmpty {
            return lastSavedTitle
        }

        guard let transcriptURL else { return nil }
        return transcriptURL.deletingPathExtension().lastPathComponent
    }
}
