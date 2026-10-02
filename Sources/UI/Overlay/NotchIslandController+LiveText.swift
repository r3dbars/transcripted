// NotchIslandController+LiveText.swift
// The live text the island shows on hover: the meeting's live transcript
// and the dictation's live words. Both views live as long as the island and
// are updated in place, never by re-rendering it. Split out of
// NotchIslandController.swift.

import AppKit
import Combine

extension NotchIslandController {
    /// The meeting's live transcript changed. The view lives as long as the
    /// island so its scroll position survives the drop-down being rebuilt;
    /// it is updated in place, never by re-rendering the island.
    func updateLiveTranscript(_ log: LiveMeetingCaptionLog, status: LiveMeetingCaptions.Status) {
        // Nothing to show yet: don't build the panel for it.
        if islandView == nil, log.isEmpty, status == .off { return }
        ensureLiveTranscriptView().apply(log, status: status)
        // The setting was flipped mid-meeting: swap lanes and transcript.
        if var meeting, meeting.showsLiveTranscript != Self.showsLiveTranscript(meeting) {
            meeting.showsLiveTranscript = Self.showsLiveTranscript(meeting)
            self.meeting = meeting
            render()
        }
    }

    @discardableResult
    func ensureLiveTranscriptView() -> NotchIslandLiveTranscriptView {
        let (_, islandView) = ensurePanel()
        if let view = islandView.liveTranscriptView { return view }
        let view = NotchIslandLiveTranscriptView(width: NotchIslandDropView.contentWidth)
        islandView.liveTranscriptView = view
        let captions = LiveMeetingCaptions.shared
        view.apply(captions.log, status: captions.status)
        return view
    }

    static func showsLiveTranscript(_ meeting: NotchIslandMeetingContent?) -> Bool {
        meeting?.isRecording == true && NotchIslandPreferences.showsLiveTranscript()
    }

    func watchLiveTranscript() {
        let captions = LiveMeetingCaptions.shared
        liveTranscriptWatch = captions.$log.combineLatest(captions.$status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] log, status in
                MainActor.assumeIsolated { self?.updateLiveTranscript(log, status: status) }
            }
    }

    // MARK: Dictation

    /// Marks a dictation whose words are streaming (or were, for the take
    /// being written) so its hover shows them.
    func withLivePreview(_ content: NotchIslandDictationContent?) -> NotchIslandDictationContent? {
        guard var content else { return nil }
        let captions = LiveDictationCaptions.shared
        switch content.phase {
        case .starting:
            content.showsLivePreview = captions.isStreaming
        // Recording stops a beat before the phase moves on: keep the words.
        case .listening, .writing, .success:
            content.showsLivePreview = captions.isStreaming || !captions.preview.isEmpty
        case .loading, .message:
            content.showsLivePreview = false
        }
        if content.showsLivePreview { ensureDictationPreviewView() }
        return content
    }

    @discardableResult
    func ensureDictationPreviewView() -> NotchIslandDictationPreviewView {
        let (_, islandView) = ensurePanel()
        if let view = islandView.dictationPreviewView { return view }
        let view = NotchIslandDictationPreviewView(width: NotchIslandDropView.contentWidth)
        islandView.dictationPreviewView = view
        let captions = LiveDictationCaptions.shared
        view.apply(captions.preview, settling: captions.isStreaming)
        return view
    }

    func watchDictationPreview() {
        let captions = LiveDictationCaptions.shared
        dictationPreviewWatch = captions.$preview.combineLatest(captions.$isStreaming)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] preview, streaming in
                MainActor.assumeIsolated { self?.updateDictationPreview(preview, streaming: streaming) }
            }
    }

    /// New words update the view in place. Only a change in whether there
    /// are words to show re-renders, so the drop-down can make room.
    private func updateDictationPreview(_ preview: LiveDictationPreview, streaming: Bool) {
        if islandView == nil, preview.isEmpty, !streaming { return }
        ensureDictationPreviewView().apply(preview, settling: streaming)
        let updated = withLivePreview(dictation)
        if updated != dictation {
            dictation = updated
            render()
        }
    }
}
