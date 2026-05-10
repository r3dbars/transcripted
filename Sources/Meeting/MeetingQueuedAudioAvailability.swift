import Foundation

enum MeetingQueuedAudioAvailability {
    struct MissingFiles: Equatable {
        let micMissing: Bool
        let systemMissing: Bool
    }

    static func missingFiles(
        micURL: URL,
        systemURL: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> MissingFiles? {
        let micMissing = !fileExists(micURL)
        let systemMissing = systemURL.map { !fileExists($0) } ?? false

        guard micMissing || systemMissing else { return nil }
        return MissingFiles(micMissing: micMissing, systemMissing: systemMissing)
    }
}
