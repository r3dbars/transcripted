import Foundation

public enum PersonalHistorySettingsContract {
    public static var keyboardSuiteName: String {
        TildeProductProfile.current.inputMethodBundleIdentifier
    }
    public static let enabledKey = "PersonalHistoryEnabled"
    public static let excludedAppsKey = "PersonalHistoryExcludedApps"
    public static let historyIdentifierKey = "PersonalHistoryIdentifier"
    public static let consentIdentifierKey = "PersonalHistoryConsentIdentifier"
    /// Bumped by Delete Personalization Data so the IME drops in-flight watches
    /// and will not recreate the count file or diary after a wipe.
    public static let outcomeLedgerGenerationKey = "OutcomeLedgerGeneration"
}

public enum PersonalHistoryEventSource: String, Codable, Equatable, Sendable {
    case typed
    case acceptedSuggestion = "accepted_suggestion"
}

/// One bounded insertion produced while Tilde is the active input method.
/// Events are intentionally storage-format agnostic so a future store can
/// derive vocabulary, phrases, examples, or training rows without changing
/// what the keyboard sends. The stable ID lets future readers deduplicate an
/// at-least-once local socket retry.
public struct PersonalHistoryEvent: Codable, Equatable, Sendable {
    public static let version = 1
    public static let maximumTextCharacters = 512
    public static let maximumTextUTF8Bytes = 2_048
    public static let maximumIdentifierCharacters = 64
    public static let maximumBundleIdentifierCharacters = 200
    /// Keeps worst-case escaped JSON below the socket's 16 KiB request limit.
    public static let maximumBatchEvents = 12
    public static let maximumBatchTextCharacters = 1_024
    public static let maximumBatchTextUTF8Bytes = 4_096

    public let v: Int
    public let id: String
    public let timestampMilliseconds: Int64
    public let historyIdentifier: String
    public let consentIdentifier: String
    public let sessionIdentifier: String
    public let appBundleIdentifier: String
    public let source: PersonalHistoryEventSource
    public let text: String

    public init?(
        id: String,
        timestampMilliseconds: Int64,
        historyIdentifier: String,
        consentIdentifier: String? = nil,
        sessionIdentifier: String,
        appBundleIdentifier: String,
        source: PersonalHistoryEventSource,
        text: String
    ) {
        guard Self.validIdentifier(id),
              timestampMilliseconds > 0,
              Self.validIdentifier(historyIdentifier),
              let consentIdentifier = consentIdentifier ?? Optional(historyIdentifier),
              Self.validIdentifier(consentIdentifier),
              Self.validIdentifier(sessionIdentifier),
              Self.validBundleIdentifier(appBundleIdentifier),
              !text.isEmpty,
              text.count <= Self.maximumTextCharacters,
              text.utf8.count <= Self.maximumTextUTF8Bytes else {
            return nil
        }
        self.v = Self.version
        self.id = id
        self.timestampMilliseconds = timestampMilliseconds
        self.historyIdentifier = historyIdentifier
        self.consentIdentifier = consentIdentifier
        self.sessionIdentifier = sessionIdentifier
        self.appBundleIdentifier = appBundleIdentifier
        self.source = source
        self.text = text
    }

    public static func validBatch(_ events: [Self]) -> Bool {
        !events.isEmpty
            && events.count <= maximumBatchEvents
            && events.reduce(0) { $0 + $1.text.count } <= maximumBatchTextCharacters
            && events.reduce(0) { $0 + $1.text.utf8.count } <= maximumBatchTextUTF8Bytes
            && events.allSatisfy { $0.v == version }
    }

    public static func boundedBatchPrefix(_ events: [Self]) -> [Self] {
        var batch: [Self] = []
        var characters = 0
        var utf8Bytes = 0
        for event in events.prefix(maximumBatchEvents) {
            let nextCharacters = characters + event.text.count
            let nextBytes = utf8Bytes + event.text.utf8.count
            guard nextCharacters <= maximumBatchTextCharacters,
                  nextBytes <= maximumBatchTextUTF8Bytes else { break }
            batch.append(event)
            characters = nextCharacters
            utf8Bytes = nextBytes
        }
        return batch
    }

    public func coalescing(with next: Self) -> Self? {
        guard source == .typed,
              next.source == .typed,
              historyIdentifier == next.historyIdentifier,
              consentIdentifier == next.consentIdentifier,
              sessionIdentifier == next.sessionIdentifier,
              appBundleIdentifier == next.appBundleIdentifier else { return nil }
        return Self(
            id: id,
            timestampMilliseconds: timestampMilliseconds,
            historyIdentifier: historyIdentifier,
            consentIdentifier: consentIdentifier,
            sessionIdentifier: sessionIdentifier,
            appBundleIdentifier: appBundleIdentifier,
            source: source,
            text: text + next.text
        )
    }

    public static func validBundleIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maximumBundleIdentifierCharacters
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 65 && $0 <= 90)
                    || ($0 >= 97 && $0 <= 122)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }
    }

    public static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maximumIdentifierCharacters
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 65 && $0 <= 90)
                    || ($0 >= 97 && $0 <= 122)
                    || $0 == 45 || $0 == 95
            }
    }

    private enum CodingKeys: String, CodingKey {
        case v, id, timestampMilliseconds, historyIdentifier, consentIdentifier, sessionIdentifier
        case appBundleIdentifier, source, text
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .v)
        guard version == Self.version,
              let event = Self(
                id: try values.decode(String.self, forKey: .id),
                timestampMilliseconds: try values.decode(Int64.self, forKey: .timestampMilliseconds),
                historyIdentifier: try values.decode(String.self, forKey: .historyIdentifier),
                consentIdentifier: try values.decodeIfPresent(
                    String.self,
                    forKey: .consentIdentifier
                ),
                sessionIdentifier: try values.decode(String.self, forKey: .sessionIdentifier),
                appBundleIdentifier: try values.decode(String.self, forKey: .appBundleIdentifier),
                source: try values.decode(PersonalHistoryEventSource.self, forKey: .source),
                text: try values.decode(String.self, forKey: .text)
              ) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid Personal History event")
            )
        }
        self = event
    }
}

public struct PersonalHistoryCapturePolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case allowed(appBundleIdentifier: String)
        case blocked(BlockReason)
    }

    public enum BlockReason: Equatable, Sendable {
        case disabled
        case secureInput
        case missingOrInvalidApp
        case excludedApp
    }

    public init() {}

    public func decision(
        enabled: Bool,
        secureInput: Bool,
        appBundleIdentifier: String?,
        excludedApps: Set<String>
    ) -> Decision {
        guard enabled else { return .blocked(.disabled) }
        guard !secureInput else { return .blocked(.secureInput) }
        guard let appBundleIdentifier,
              PersonalHistoryEvent.validBundleIdentifier(appBundleIdentifier) else {
            return .blocked(.missingOrInvalidApp)
        }
        // Same always-excluded check as Screen Memory's CaptureTriggerPolicy
        // — password managers and Keychain Access are blocked regardless of
        // what the caller passed in. Routed through the one shared helper
        // (`DefaultExcludedApps.isExcluded`) so every other Personal
        // History call site (`PersonalHistoryController.ingestSerially`,
        // `finishReplay`) that needs the same check cannot silently drift
        // to checking `excludedApps` alone.
        guard !DefaultExcludedApps.isExcluded(appBundleIdentifier, configuredExcludedApps: excludedApps) else {
            return .blocked(.excludedApp)
        }
        return .allowed(appBundleIdentifier: appBundleIdentifier)
    }

    public static func normalizedExcludedApps(_ values: some Sequence<String>) -> [String] {
        Array(Set(values.filter(PersonalHistoryEvent.validBundleIdentifier))).sorted().prefix(128).map { $0 }
    }
}
