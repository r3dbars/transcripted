// SpeakerNamingSheet.swift
// Presents TranscriptionTaskManager.$speakerNamingRequest in the Notch
// island ("Who was on this call?", `NotchIslandSpeakerReviewView`). The
// island calls `request.onComplete(updates.map(SpeakerReviewBridge.coreUpdate))` so Core's
// SpeakerNamingCoordinator can write the names back into the transcript.
// An empty array (Later) keeps the transcript generic and preserves local
// review state for the Speakers page.
// A review that arrives while a meeting records waits until that recording
// stops (`SpeakerReviewPresentationGate`), so it never lands mid-call.
// When the meeting started with a calendar event, its invitees show up as
// name suggestions. They never name anyone on their own.

import AppKit
import Combine
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class SpeakerNamingSheet {

    /// One-shot presenter that watches the task manager's `speakerNamingRequest`
    /// and shows a sheet whenever a new request arrives. Created once at app
    /// launch by `TranscriptedApp` and kept alive for the app lifetime.
    static let shared = SpeakerNamingSheet()

    private var subscription: AnyCancellable?
    private var captureSubscription: AnyCancellable?
    private var latestRequest: SpeakerNamingRequest?
    private var gate = SpeakerReviewPresentationGate()

    /// The review asks "Who was on this call?" in the Notch island.
    weak var island: NotchIslandController?
    /// Open transcript on the island's "Everyone's named".
    var onOpenTranscript: ((URL) -> Void)?
    private var islandReviewView: NotchIslandSpeakerReviewView?
    private var islandReviewContent: NotchIslandSpeakerReviewContent?

    /// Wire the presenter to a task manager and to whether a meeting is being
    /// captured. Idempotent — later calls replace the subscriptions.
    func observe(
        taskManager: TranscriptionTaskManager,
        meetingCaptureActive: AnyPublisher<Bool, Never> = Just(false).eraseToAnyPublisher()
    ) {
        subscription = taskManager.$speakerNamingRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                guard let self else { return }
                self.latestRequest = request
                self.apply(self.gate.requestChanged(to: request?.id))
            }
        captureSubscription = meetingCaptureActive
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isActive in
                guard let self else { return }
                self.apply(self.gate.meetingCaptureChanged(isActive: isActive))
            }
    }

    private func apply(_ action: SpeakerReviewPresentationGate.Action) {
        switch action {
        case .keep:
            break
        case .present(let requestID):
            guard let request = latestRequest, request.id == requestID else { return }
            present(request: request)
        case .dismiss:
            dismissCurrentWindowBecauseRequestCleared()
        }
    }

    private func present(request: SpeakerNamingRequest) {
        guard let island else {
            // No island to ask in (never, in the app): leave it for later,
            // like Later. Core keeps the review for the Speakers page.
            gate.windowClosed(requestID: request.id)
            request.onComplete([])
            return
        }
        presentInIsland(request: request, island: island)
    }

    /// Reads the meeting's name off the main thread. The background restyle
    /// renames the file, so a missing file is found again by its
    /// transcript id.
    static func meetingTitle(for request: SpeakerNamingRequest) async -> String? {
        let url = request.transcriptURL
        let transcriptID = request.transcriptId
        return await Task.detached(priority: .utility) { () -> String? in
            var transcriptURL: URL? = url
            if !FileManager.default.fileExists(atPath: url.path) {
                transcriptURL = TranscriptSaver.existingTranscriptURL(
                    in: url.deletingLastPathComponent(),
                    transcriptId: transcriptID
                )
            }
            return transcriptURL.flatMap { MeetingTranscriptStyler.displayTranscriptPreview(at: $0)?.title }
        }.value
    }

    /// Who was invited to the calendar event this meeting started with.
    /// Imported recordings are skipped: their saved time is when the file
    /// was made, not a calendar slot.
    static func invitees(for request: SpeakerNamingRequest) async -> (names: [String], remoteVoices: Int?)? {
        let url = request.transcriptURL
        let transcriptID = request.transcriptId
        let recording = await Task.detached(priority: .utility) { () -> (start: Date, remoteVoices: Int?)? in
            var transcriptURL: URL? = url
            if !FileManager.default.fileExists(atPath: url.path) {
                transcriptURL = TranscriptSaver.existingTranscriptURL(
                    in: url.deletingLastPathComponent(),
                    transcriptId: transcriptID
                )
            }
            guard let transcriptURL,
                  let values = try? TranscriptFrontmatter.readValues(from: transcriptURL),
                  values["imported_at"] == nil,
                  let start = TranscriptFrontmatter.recordedAt(values: values) else { return nil }
            return (start, values["system_speakers"].flatMap { Int($0) })
        }.value
        guard let recording else { return nil }
        let names = await MeetingInviteeCalendarReader.shared.inviteeNames(recordingStart: recording.start)
        guard !names.isEmpty else { return nil }
        return (names, recording.remoteVoices)
    }

    private func dismissCurrentWindowBecauseRequestCleared() {
        // Core clears the request once the island's answers are saved; the
        // island keeps showing "Everyone's named" until it closes itself.
        if let islandReviewView, !islandReviewView.isFinished {
            finishIslandReview(requestID: islandReviewView.requestID)
        }
    }

    // MARK: - In the notch island

    private func presentInIsland(request: SpeakerNamingRequest, island: NotchIslandController) {
        if let previous = islandReviewView {
            // A newer review replaces one still on screen; its request is gone.
            finishIslandReview(requestID: previous.requestID)
        }
        let requestID = request.id
        let view = NotchIslandSpeakerReviewView(request: request)
        let content = NotchIslandSpeakerReviewContent(reviewID: requestID, meetingTitle: nil, stage: .naming)
        view.onLayoutChange = { [weak island] in island?.speakerReviewLayoutChanged() }
        view.onWantsKeyboard = { [weak island] in island?.makeKeyForTyping() }
        view.onLater = { [weak self] updates in
            request.onComplete(updates.map(SpeakerReviewBridge.coreUpdate))
            self?.finishIslandReview(requestID: requestID)
        }
        view.onDone = { [weak self, weak island, weak view] updates, leftForLater in
            request.onComplete(updates.map(SpeakerReviewBridge.coreUpdate))
            guard let self, var content = self.islandReviewContent, content.reviewID == requestID else { return }
            self.gate.windowClosed(requestID: requestID)
            content.stage = .done(leftForLater: leftForLater)
            self.islandReviewContent = content
            island?.showSpeakerReview(content, view: view)
        }
        view.onDoneLingerEnded = { [weak self] in self?.finishIslandReview(requestID: requestID) }
        view.onOpenTranscript = { [weak self] in
            self?.onOpenTranscript?(request.transcriptURL)
            self?.finishIslandReview(requestID: requestID)
        }
        island.speakerReviewHoverHandler = { [weak view] hovered in view?.setHovered(hovered) }
        island.speakerReviewVisibilityHandler = { [weak view] onScreen in view?.setOnScreen(onScreen) }
        islandReviewView = view
        islandReviewContent = content
        island.showSpeakerReview(content, view: view)

        Task { @MainActor [weak self, weak island, weak view] in
            let title = await Self.meetingTitle(for: request)
            guard let self, let view, self.islandReviewView === view,
                  var content = self.islandReviewContent else { return }
            view.setMeetingTitle(title)
            content.meetingTitle = title
            self.islandReviewContent = content
            island?.showSpeakerReview(content, view: view)
        }
        Task { @MainActor [weak self, weak view] in
            guard let invitees = await Self.invitees(for: request),
                  let self, let view, self.islandReviewView === view else { return }
            view.setInvitees(invitees.names, remoteVoicesInMeeting: invitees.remoteVoices)
        }
    }

    private func finishIslandReview(requestID: UUID) {
        gate.windowClosed(requestID: requestID)
        guard islandReviewView?.requestID == requestID else { return }
        islandReviewView = nil
        islandReviewContent = nil
        island?.speakerReviewHoverHandler = nil
        island?.speakerReviewVisibilityHandler = nil
        island?.showSpeakerReview(nil, view: nil)
    }
}

