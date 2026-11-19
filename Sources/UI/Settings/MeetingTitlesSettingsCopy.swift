import Foundation

/// The row's words, kept out of the view so they can be tested.
enum MeetingTitlesSettingsCopy {
    enum State: Equatable {
        case caption(String)
        case progress(Double, String)
        case failed(String)
    }

    static func state(
        isEnabled: Bool,
        status: MeetingTitlesController.ModelStatus,
        activity: MeetingTitlesQueue.Activity
    ) -> State {
        guard isEnabled else {
            return .caption(status == .ready ? "Model downloaded" : MeetingTitlesController.downloadSizeLabel)
        }
        switch status {
        case .notDownloaded:
            return .caption(MeetingTitlesController.downloadSizeLabel)
        case .downloading(let received, let total):
            let fraction = total > 0 ? min(1, max(0, Double(received) / Double(total))) : 0
            let text = "\(ModelCacheInventory.formattedByteCount(received)) of \(ModelCacheInventory.formattedByteCount(total))"
            return .progress(fraction, text)
        case .ready:
            switch activity {
            case .labeling: return .caption("Writing titles…")
            case .waitingForBusy: return .caption("Waiting until you're done")
            case .engineUnavailable: return .failed("Couldn't start the model")
            case .idle: return .caption("On")
            }
        case .failed(let failure):
            return .failed(message(for: failure))
        }
    }

    static func message(for failure: MeetingTitlesModelFailure) -> String {
        switch failure {
        case .offline: return "Download stopped"
        case .insufficientDiskSpace: return "Not enough disk space"
        case .serverRejectedRequest: return "Download failed"
        case .checksumMismatch, .invalidModel: return "Download was damaged"
        case .installationFailed: return "Couldn't save the model"
        }
    }

    static func help(isEnabled: Bool, status: MeetingTitlesController.ModelStatus) -> String {
        guard isEnabled else { return "Meetings keep their usual titles." }
        if case .downloading = status { return "Downloading the titles model." }
        return "New meetings get a title, a one-line takeaway and a short summary."
    }
}
