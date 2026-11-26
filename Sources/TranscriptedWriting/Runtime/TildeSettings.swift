#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Settings shared between Transcripted and its capture keyboard process.
struct TildeSettings {
    enum KeyboardKey: String {
        case pausedUntil = "GhostPausedUntil"
        case personalHistory = "PersonalHistoryEnabled"
        case personalHistoryExcludedApps = "PersonalHistoryExcludedApps"
        case personalHistoryIdentifier = "PersonalHistoryIdentifier"
        case personalHistoryConsentIdentifier = "PersonalHistoryConsentIdentifier"
    }

    static let keyboardSuiteName = PersonalHistorySettingsContract.keyboardSuiteName

    private let keyboard: UserDefaults
    private let app: UserDefaults

    init(
        keyboard: UserDefaults? = UserDefaults(suiteName: TildeSettings.keyboardSuiteName),
        app: UserDefaults = .standard
    ) {
        self.keyboard = keyboard ?? .standard
        self.app = app
    }

    var personalHistoryEnabled: Bool {
        get { keyboard.bool(forKey: KeyboardKey.personalHistory.rawValue) }
        nonmutating set { keyboard.set(newValue, forKey: KeyboardKey.personalHistory.rawValue) }
    }

    var personalHistoryExcludedApps: Set<String> {
        get {
            Set(PersonalHistoryCapturePolicy.normalizedExcludedApps(
                keyboard.stringArray(forKey: KeyboardKey.personalHistoryExcludedApps.rawValue) ?? []
            ))
        }
        nonmutating set {
            keyboard.set(
                PersonalHistoryCapturePolicy.normalizedExcludedApps(newValue),
                forKey: KeyboardKey.personalHistoryExcludedApps.rawValue
            )
        }
    }

    var personalHistoryIdentifier: String? {
        get {
            guard let value = keyboard.string(forKey: KeyboardKey.personalHistoryIdentifier.rawValue),
                  PersonalHistoryEvent.validIdentifier(value) else { return nil }
            return value
        }
        nonmutating set {
            keyboard.set(newValue, forKey: KeyboardKey.personalHistoryIdentifier.rawValue)
        }
    }

    var personalHistoryConsentIdentifier: String? {
        get {
            guard let value = keyboard.string(
                forKey: KeyboardKey.personalHistoryConsentIdentifier.rawValue
            ), PersonalHistoryEvent.validIdentifier(value) else { return nil }
            return value
        }
        nonmutating set {
            keyboard.set(newValue, forKey: KeyboardKey.personalHistoryConsentIdentifier.rawValue)
        }
    }

    var pausedUntil: Date? {
        let stamp = keyboard.double(forKey: KeyboardKey.pausedUntil.rawValue)
        guard stamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: stamp)
        return date > Date() ? date : nil
    }

    func pause(for interval: TimeInterval, now: Date = Date()) {
        keyboard.set(
            now.addingTimeInterval(interval).timeIntervalSince1970,
            forKey: KeyboardKey.pausedUntil.rawValue
        )
    }

    func resume() {
        keyboard.set(0, forKey: KeyboardKey.pausedUntil.rawValue)
    }
}
