// NotchIslandController+DictationPreview.swift
// The dictation hover's live words: one preview view that lives as long as
// the island and is updated in place, never by re-rendering it, like the
// meeting's live transcript (NotchIslandController+LiveTranscript.swift).

import AppKit
import Combine

extension NotchIslandController {
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
            // Key-up shows Writing before the mic has stopped: stop feeding
            // the preview now so the final pass has the Neural Engine.
            if content.phase != .listening { captions.releaseRequested() }
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
