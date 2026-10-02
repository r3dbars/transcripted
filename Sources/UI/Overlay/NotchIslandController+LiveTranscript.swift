// NotchIslandController+LiveTranscript.swift
// The recording drop-down's live transcript: keeps one
// NotchIslandLiveTranscriptView alive for the island, feeds it from
// LiveMeetingCaptions, and copies the whole transcript on Copy all.

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

    /// Copy all: the whole transcript so far, words still being heard included.
    func copyLiveTranscript() {
        let text = LiveMeetingCaptions.shared.log.plainText()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
