// HomeMeetingPreview.swift
// The open Meetings card's read transcript, and how it follows a rename or
// a re-read. Plain data, so the fast tests can check it.

import Foundation

struct HomeMeetingPreview: Identifiable {
    let id: String
    let title: String
    let date: Date
    let transcriptURL: URL
    let audio: MeetingAudioAttachment?
    let markdown: String
    let content: HomeMeetingPreviewContent
    let readError: String?

    /// Pass `content` when it was already parsed off main (see
    /// `readMeetingMarkdown`); otherwise it's parsed here from `markdown`.
    init(
        item: RecentMeetingItem,
        markdown: String,
        content: HomeMeetingPreviewContent? = nil,
        readError: String? = nil
    ) {
        id = item.id
        title = item.displayTitle
        date = item.date
        transcriptURL = item.transcriptURL
        audio = item.audio
        self.markdown = markdown
        self.content = content ?? HomeMeetingPreviewContent.make(from: markdown)
        self.readError = readError
    }

    private init(
        id: String,
        title: String,
        date: Date,
        transcriptURL: URL,
        audio: MeetingAudioAttachment?,
        markdown: String,
        content: HomeMeetingPreviewContent,
        readError: String?
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.transcriptURL = transcriptURL
        self.audio = audio
        self.markdown = markdown
        self.content = content
        self.readError = readError
    }

    /// Returns a copy for a renamed transcript. The id follows the new path,
    /// because the open card is keyed by the row id (the transcript path) and
    /// the rename moves the open id to the new path too; keeping the old id
    /// would leave the open card waiting on a preview that never matches. The
    /// transcript body already read is kept, so the card doesn't reload.
    func updatingAfterRename(
        transcriptURL: URL,
        title: String,
        audio: MeetingAudioAttachment?
    ) -> HomeMeetingPreview {
        HomeMeetingPreview(
            id: transcriptURL.path,
            title: title,
            date: date,
            transcriptURL: transcriptURL,
            audio: audio,
            markdown: markdown,
            content: content,
            readError: readError
        )
    }

    /// Returns a copy with freshly-read transcript text after an inline speaker edit.
    func updatingMarkdown(
        _ markdown: String,
        content: HomeMeetingPreviewContent? = nil,
        readError: String? = nil
    ) -> HomeMeetingPreview {
        HomeMeetingPreview(
            id: id,
            title: title,
            date: date,
            transcriptURL: transcriptURL,
            audio: audio,
            markdown: markdown,
            content: content ?? HomeMeetingPreviewContent.make(from: markdown),
            readError: readError
        )
    }
}

enum HomeMeetingMarkdownReadResult {
    /// The preview content is parsed on the same background read, so the
    /// main actor only assigns it.
    case success(String, HomeMeetingPreviewContent)
    case failure(String)
}
