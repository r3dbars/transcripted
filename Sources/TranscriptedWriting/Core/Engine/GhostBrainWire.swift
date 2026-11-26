import Foundation

/// The messages exchanged between Transcripted and its capture keyboard over
/// the owner-only unix socket. Typing events stay strictly on this Mac and are
/// written only to local Markdown day files after secret scrubbing.
public struct GhostBrainRequest: Codable, Equatable, Sendable {
    public static let version = 1
    public static let maximumWireBytes = 16_384

    public let v: Int
    public let context: String
    public let personalHistoryEvents: [PersonalHistoryEvent]?

    public init(personalHistoryEvents: [PersonalHistoryEvent]) {
        self.v = Self.version
        self.context = ""
        self.personalHistoryEvents = personalHistoryEvents
    }
}

public struct GhostBrainResponse: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case unavailable
        case error
        case timeout
        case invalidRequest = "invalid_request"
        case recorded
        /// A capture batch holds events whose version this app can't read (a
        /// keyboard newer than the app). Terminal: the keyboard drops the
        /// events `rejectedEventIDs` names and resends the rest.
        case unsupported
    }

    public let outcome: Outcome
    /// On an `unsupported` line, the IDs of the events the app couldn't read.
    /// Random identifiers only, never text. Absent otherwise.
    public let rejectedEventIDs: [String]?

    public init(
        outcome: Outcome,
        rejectedEventIDs: [String]? = nil
    ) {
        self.outcome = outcome
        self.rejectedEventIDs = rejectedEventIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.outcome = try container.decode(Outcome.self, forKey: .outcome)
        self.rejectedEventIDs = try? container.decodeIfPresent([String].self, forKey: .rejectedEventIDs)
    }

    public static let unavailable = Self(outcome: .unavailable)
    public static let error = Self(outcome: .error)
    public static let timeout = Self(outcome: .timeout)
    public static let invalidRequest = Self(outcome: .invalidRequest)
    public static let recorded = Self(outcome: .recorded)

    /// The terminal answer to a capture batch with events of a version this
    /// app doesn't know.
    public static func unsupported(rejectedEventIDs: [String]) -> Self {
        Self(outcome: .unsupported, rejectedEventIDs: rejectedEventIDs)
    }

    /// A response from an authenticated peer that does not match this protocol
    /// is a runtime error, not an unavailable app.
    public static func decode(_ data: Data) -> Self {
        (try? JSONDecoder().decode(Self.self, from: data)) ?? .error
    }
}

// An older app must not block a newer keyboard's capture queue. When a
// version-1 capture batch fails to decode only because some events carry a
// version this build doesn't know, the app answers `unsupported` with those
// events' IDs instead of `invalid_request`.
extension GhostBrainRequest {
    private struct HistoryBatchProbe: Decodable {
        struct Event: Decodable {
            let v: Int
            let id: String
        }

        let v: Int
        let personalHistoryEvents: [Event]?
    }

    /// The IDs of the events in the request line `data` whose version this
    /// build can't read. `nil` unless the line is a version-1 capture batch of
    /// valid size and identifiers with at least one such event; anything else
    /// stays an invalid request.
    public static func unsupportedPersonalHistoryEventIDs(in data: Data) -> [String]? {
        guard let probe = try? JSONDecoder().decode(HistoryBatchProbe.self, from: data),
              probe.v == version,
              let events = probe.personalHistoryEvents,
              (1...PersonalHistoryEvent.maximumBatchEvents).contains(events.count),
              events.allSatisfy({ PersonalHistoryEvent.validIdentifier($0.id) }) else { return nil }
        let unsupported = events
            .filter { !PersonalHistoryEvent.supportedVersions.contains($0.v) }
            .map(\.id)
        return unsupported.isEmpty ? nil : unsupported
    }
}
