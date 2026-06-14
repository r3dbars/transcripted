import Foundation

enum HomeMeetingRowActionTargets {
    static func transcriptRevealURLs(for item: RecentMeetingItem) -> [URL] {
        [item.transcriptURL]
    }

    static func audioRevealURLs(for item: RecentMeetingItem) -> [URL] {
        audioRevealURLs(audioURLs: item.audio?.urls ?? [])
    }

    static func audioRevealURLs(audioURLs: [URL]) -> [URL] {
        guard let firstAudioURL = audioURLs.first else { return [] }
        return [firstAudioURL]
    }
}
