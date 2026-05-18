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
                title: "Preparing transcript",
                status: "Preparing",
                detail: "Your meeting audio is saved. Transcripted is loading it and starting the local model.",
                tone: .working,
                progress: displayStatus.progress,
                transcriptURL: nil
            )
        case .transcribing:
            return HomeTranscriptionActivityPresentation(
                symbolName: "waveform.badge.magnifyingglass",
                title: "Transcribing with local model",
                status: "Transcribing",
                detail: "Transcripted is turning the saved audio into a Markdown transcript. Other retries pause until this finishes.",
                tone: .working,
                progress: displayStatus.progress,
                transcriptURL: nil
            )
        case .finishing:
            return HomeTranscriptionActivityPresentation(
                symbolName: "square.and.arrow.down.fill",
                title: "Saving Markdown transcript",
                status: "Saving",
                detail: "Transcripted is writing the Markdown file. When this finishes, the meeting returns to the normal list.",
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
                detail = "\"\(transcriptName)\" is ready. This meeting is back in your list like normal; speaker names can be reviewed later if needed."
            } else {
                detail = "Your Markdown transcript is ready. This meeting is back in your list like normal; speaker names can be reviewed later if needed."
            }

            return HomeTranscriptionActivityPresentation(
                symbolName: "checkmark.circle.fill",
                title: "Markdown transcript saved",
                status: "Ready",
                detail: detail,
                tone: .success,
                progress: 1.0,
                transcriptURL: transcriptURL
            )
        case .failed(let message):
            return HomeTranscriptionActivityPresentation(
                symbolName: "exclamationmark.circle.fill",
                title: "Couldn't finish transcript",
                status: "Needs attention",
                detail: failedTranscriptionDetail(for: message),
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
        case .recording:
            return HomeTranscriptionActivityPresentation(
                symbolName: "record.circle.fill",
                title: "Recording meeting audio",
                status: "Recording",
                detail: "Audio is being saved locally. When you stop, Transcripted will create the Markdown transcript with the local model.",
                tone: .working,
                progress: nil,
                transcriptURL: nil
            )
        case .idle, .ready, .transcribing:
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

    private static func failedTranscriptionDetail(for message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("audio file")
            || normalized.contains("convert")
            || normalized.contains("choose audio") {
            if normalized.contains("choose")
                || normalized.contains("try ") {
                return message
            }
            return "\(message) Choose another file, or convert it to WAV or M4A and import it again."
        }

        return "\(message) If audio was saved, the meeting row below will show Try again."
    }
}
