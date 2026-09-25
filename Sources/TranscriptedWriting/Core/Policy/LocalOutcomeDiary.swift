import Foundation

/// Local-only word diary. This is not the F03 event and Lab must never ingest it.
///
/// The accepted span stays on this Mac so the owner can see keep versus edit.
/// Delete Personalization Data must wipe it. It must never be committed, logged,
/// printed, or sent on the network.
public struct LocalOutcomeDiaryEntry: Codable, Equatable, Sendable {
    public static let schema = "tilde.local-outcome-diary.v1"

    public let schema: String
    public let id: UUID
    public let recordedAt: Date
    public let outcome: String
    public let acceptedText: String
    public let keptAt5Seconds: Int?
    public let missingAt5Seconds: String?
    public let keptAt30Seconds: Int?
    public let missingAt30Seconds: String?
    public let keptAtSegmentClose: Int?
    public let missingAtSegmentClose: String?
    public let fate: LocalOutcomeFate

    public init(
        id: UUID,
        recordedAt: Date = Date(),
        outcome: String,
        acceptedText: String,
        five: RetainedCharacterObservation,
        thirty: RetainedCharacterObservation,
        segment: RetainedCharacterObservation
    ) {
        self.schema = Self.schema
        self.id = id
        self.recordedAt = recordedAt
        self.outcome = outcome
        self.acceptedText = acceptedText
        keptAt5Seconds = five.retainedCharacters
        missingAt5Seconds = five.missingness?.rawValue
        keptAt30Seconds = thirty.retainedCharacters
        missingAt30Seconds = thirty.missingness?.rawValue
        keptAtSegmentClose = segment.retainedCharacters
        missingAtSegmentClose = segment.missingness?.rawValue
        fate = LocalOutcomeFate.resolve(
            acceptedCount: acceptedText.count,
            five: five,
            thirty: thirty,
            segment: segment
        )
    }

    public static func encodeJSONL(_ entry: LocalOutcomeDiaryEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(entry)
        data.append(0x0A)
        return data
    }
}

public enum LocalOutcomeFate: String, Codable, Sendable {
    case kept
    case edited
    case missing
    case noneAccepted = "none-accepted"

    public static func resolve(
        acceptedCount: Int,
        five: RetainedCharacterObservation,
        thirty: RetainedCharacterObservation,
        segment: RetainedCharacterObservation
    ) -> LocalOutcomeFate {
        guard acceptedCount > 0 else { return .noneAccepted }
        let observed = [five, thirty, segment].compactMap(\.retainedCharacters)
        if observed.isEmpty { return .missing }
        if observed.contains(where: { $0 < acceptedCount }) { return .edited }
        return .kept
    }
}

/// Path computation only. Callers own create/append/delete.
public enum LocalOutcomeDiaryFile {
    public static let directoryName = "Word Diary"
    public static let fileName = "diary.v1.jsonl"

    public static func url(homeDirectory: URL, supportDirectoryName: String) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
