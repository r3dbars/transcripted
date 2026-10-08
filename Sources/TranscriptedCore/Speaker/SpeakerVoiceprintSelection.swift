import Foundation

/// The one rule for which voiceprint model a meeting run uses and which speaker
/// database file holds that model's people. The app (`SpeakerEmbedderFactory`)
/// and the CLI's `import-audio` both resolve through here, so they can't drift
/// apart again: the CLI once read WeSpeaker's `speakers.sqlite` while the app had
/// moved everyone to ReDimNet2, and saved names never reached CLI imports.
///
/// Pure and Foundation-only. Hosts supply what only they can see: the stored
/// preference, the environment, whether a model file exists, and whether that
/// model already failed to load on this build.
public enum SpeakerVoiceprintSelection {
    public enum Model: String, CaseIterable, Sendable {
        case weSpeaker = "wespeaker"
        case eRes2Net = "eres2net"
        case reDimNet2 = "redimnet2"

        /// The injected embedder's identifier, or nil for WeSpeaker (the diarizer's
        /// own voiceprint, no injected embedder). Matches `ReDimNet2Embedder.identifier`
        /// and `ERes2NetEmbedder.identifier`; a Core test pins that.
        public var embedderIdentifier: String? {
            switch self {
            case .weSpeaker: return nil
            case .eRes2Net: return "eres2net"
            case .reDimNet2: return "redimnet2-b4"
            }
        }
    }

    /// The model new installs use (the voiceprint bake-off winner).
    public static let defaultModel: Model = .reDimNet2
    /// The app's defaults domain, which the CLI reads for the stored preference.
    public static let appDefaultsDomain = "com.justinbetker.draft"
    /// Stored preference key in the app's defaults.
    public static let preferenceKey = "speaker-embedder-preference"
    /// Dev/test override. Wins over the stored preference.
    public static let environmentKey = "TRANSCRIPTED_SPEAKER_EMBEDDER"

    /// The stored choice, ignoring the environment. A stored WeSpeaker came from
    /// the old "Better matching on calls" switch being off; that switch is gone, so
    /// it reads as the default. Unknown or missing values read as the default too.
    public static func preferredModel(storedPreference: String?) -> Model {
        guard let storedPreference,
              let model = Model(rawValue: storedPreference),
              model != .weSpeaker else { return defaultModel }
        return model
    }

    /// The choice a run should use: a valid environment override first (any case),
    /// then the stored preference, then the default.
    public static func effectiveModel(storedPreference: String?, environment: [String: String]) -> Model {
        if let raw = environment[environmentKey]?.lowercased(), let model = Model(rawValue: raw) {
            return model
        }
        return preferredModel(storedPreference: storedPreference)
    }

    /// The embedder a run is built around: the chosen model's identifier when its
    /// file is present and it hasn't failed to load on this build, else nil
    /// (WeSpeaker and `speakers.sqlite`).
    public static func embedderIdentifier(
        for model: Model,
        modelFileIsPresent: Bool,
        failedOnThisBuild: Bool
    ) -> String? {
        guard let identifier = model.embedderIdentifier, modelFileIsPresent, !failedOnThisBuild else { return nil }
        return identifier
    }

    /// Speaker-database filename for an embedder identifier. nil (WeSpeaker) is the
    /// legacy `speakers.sqlite`; any other model gets `speakers_<id>.sqlite`, so
    /// vectors of different dimensions never share a database.
    public static func databaseFileName(forEmbedderIdentifier identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return "speakers.sqlite" }
        return "speakers_\(identifier).sqlite"
    }

    /// Why a run ended up on WeSpeaker even though another model was chosen.
    public enum Fallback: String, Sendable, Equatable {
        case modelFileMissing
        case failedToLoadOnThisBuild
    }

    public struct Resolution: Sendable, Equatable {
        /// What the preference/environment chose.
        public let chosen: Model
        /// The embedder the run is built around; nil means WeSpeaker.
        public let embedderIdentifier: String?
        /// Filename inside the app's `state/` folder.
        public let databaseFileName: String
        /// Set when `chosen` couldn't be used and the run fell back to WeSpeaker.
        public let fallback: Fallback?
    }

    /// Full resolution for one run.
    public static func resolve(
        chosen: Model,
        modelFileIsPresent: (Model) -> Bool,
        failedOnThisBuild: (String) -> Bool
    ) -> Resolution {
        let present = modelFileIsPresent(chosen)
        let failed = chosen.embedderIdentifier.map(failedOnThisBuild) ?? false
        let identifier = embedderIdentifier(for: chosen, modelFileIsPresent: present, failedOnThisBuild: failed)
        let fallback: Fallback?
        if chosen.embedderIdentifier == nil || identifier != nil {
            fallback = nil
        } else {
            fallback = present ? .failedToLoadOnThisBuild : .modelFileMissing
        }
        return Resolution(
            chosen: chosen,
            embedderIdentifier: identifier,
            databaseFileName: databaseFileName(forEmbedderIdentifier: identifier),
            fallback: fallback
        )
    }

    /// The app's per-build load-failure memory key and lookup, shared so the CLI
    /// honors a failure the app recorded. The stored value maps an embedder
    /// identifier to the "<CFBundleVersion>|<macOS version>" it failed on.
    public static let loadFailuresKey = "speaker-embedder-load-failures"

    public static func buildKey(bundleVersion: String?, operatingSystemVersion: String) -> String {
        "\(bundleVersion ?? "unknown")|\(operatingSystemVersion)"
    }

    public static func failedOnThisBuild(
        _ identifier: String,
        recordedFailures: [String: String],
        buildKey: String
    ) -> Bool {
        recordedFailures[identifier] == buildKey
    }
}
