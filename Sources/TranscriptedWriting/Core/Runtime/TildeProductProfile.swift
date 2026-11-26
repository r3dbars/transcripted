import Foundation

/// Bundle identifiers, IMKit connection name, and support folder for
/// Transcripted's opt-in writing capture keyboard.
public enum TildeProductProfile: String, Equatable, Sendable {
    case production

    public static let infoDictionaryKey = "TildeProductProfile"

    public static var current: Self {
        resolve(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            declaredProfile: Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String
        )
    }

    public static func resolve(bundleIdentifier: String?, declaredProfile: String?) -> Self {
        if let declaredProfile, let profile = Self(rawValue: declaredProfile) {
            return profile
        }
        return .production
    }

    public var appBundleIdentifier: String {
        switch self {
        case .production: "com.justinbetker.draft"
        }
    }

    public var inputMethodBundleIdentifier: String {
        switch self {
        case .production: "com.justinbetker.draft.inputmethod.Transcripted"
        }
    }

    public var inputMethodConnectionName: String {
        switch self {
        case .production: "TranscriptedKeyboard_1_Connection"
        }
    }

    public var supportDirectoryName: String {
        switch self {
        case .production: "Transcripted/writing"
        }
    }

    public var inputMethodInstalledBundleName: String {
        switch self {
        case .production: "Transcripted Keyboard.app"
        }
    }

    public var displayName: String {
        switch self {
        case .production: "Transcripted"
        }
    }
}
