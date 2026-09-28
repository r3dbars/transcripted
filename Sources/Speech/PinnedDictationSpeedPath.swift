import Foundation

/// Moves one mic back to the engine path after the pinned recorder, used on
/// it only for speed, keeps recording takes that come out empty.
///
/// 1.1.66 put plain built-in and wired mics on the pinned recorder because it
/// delivers the first audio 2-3x sooner (`PinnedDictationInputPolicy
/// .recorderIsFasterPath`). On one M1 MacBook Air every held dictation it
/// recorded came back with no words (six "no speech", one kept for
/// recovery), while the same Mac dictated fine through the engine a few
/// minutes earlier on 1.1.64. The recorder reported no restart, fallback or
/// silent input, so it can't catch this on its own.
///
/// So each take the recorder made only for speed is scored once its
/// transcript is known: words reset the count, an empty take adds one. After
/// `emptyTakesBeforeFallback` in a row, that mic records through the engine
/// (and the start click goes back to playing after recording starts) for the
/// rest of this app version. The next version tries the recorder again.
/// Takes the recorder is needed for (a skipped Bluetooth input, a picked mic)
/// are never scored or moved. Stored locally only; clear with
/// `defaults delete com.justinbetker.draft pinned-dictation-speed-path`.
enum PinnedDictationSpeedPath {
    static let userDefaultsKey = "pinned-dictation-speed-path"
    /// One empty take is common (a press with nothing said), so it takes two
    /// in a row. The cost of a wrong move is the old start speed, not words.
    static let emptyTakesBeforeFallback = 2

    enum TakeOutcome: Equatable {
        case hadWords
        case empty
    }

    struct DeviceState: Equatable {
        var appVersion: String
        var emptyTakesInARow: Int
        var turnedOff: Bool
    }

    static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// Nil when the take says nothing about the mic: too short, a model
    /// failure, or cancelled.
    static func outcome(text: String?, emptyReason: DictationEmptyTranscriptionReason?) -> TakeOutcome? {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .hadWords
        }
        switch emptyReason {
        case .noSpeech?, .audioNeedsRecovery?:
            return .empty
        case .otherLanguage?:
            // Words came back, just in another script, so the mic worked.
            return .hadWords
        case .recordingTooShort?, .modelFailure?, nil:
            return nil
        }
    }

    /// A stored state from another app version counts as a fresh start.
    static func scored(
        _ outcome: TakeOutcome,
        previous: DeviceState?,
        appVersion: String
    ) -> DeviceState {
        var state = previous.flatMap { $0.appVersion == appVersion ? $0 : nil }
            ?? DeviceState(appVersion: appVersion, emptyTakesInARow: 0, turnedOff: false)
        switch outcome {
        case .hadWords:
            state.emptyTakesInARow = 0
        case .empty:
            state.emptyTakesInARow += 1
            if state.emptyTakesInARow >= emptyTakesBeforeFallback {
                state.turnedOff = true
            }
        }
        return state
    }

    static func isTurnedOff(
        for input: DictationAudioDevice,
        userDefaults: UserDefaults = .standard,
        appVersion: String = currentAppVersion
    ) -> Bool {
        guard let state = storedState(for: key(for: input), userDefaults: userDefaults),
              state.appVersion == appVersion else { return false }
        return state.turnedOff
    }

    /// Returns the new state and whether this take is the one that moved the
    /// mic to the engine.
    @discardableResult
    static func record(
        _ outcome: TakeOutcome,
        for input: DictationAudioDevice,
        userDefaults: UserDefaults = .standard,
        appVersion: String = currentAppVersion
    ) -> (state: DeviceState, turnedOffNow: Bool) {
        let deviceKey = key(for: input)
        let previous = storedState(for: deviceKey, userDefaults: userDefaults)
        let wasOff = previous.map { $0.appVersion == appVersion && $0.turnedOff } ?? false
        let state = scored(outcome, previous: previous, appVersion: appVersion)
        var stored = userDefaults.dictionary(forKey: userDefaultsKey) ?? [:]
        stored[deviceKey] = [
            "app_version": state.appVersion,
            "empty_in_a_row": state.emptyTakesInARow,
            "turned_off": state.turnedOff,
        ]
        userDefaults.set(stored, forKey: userDefaultsKey)
        return (state, state.turnedOff && !wasOff)
    }

    /// Core Audio UIDs survive reboots; an input without one falls back to
    /// its per-boot id.
    static func key(for input: DictationAudioDevice) -> String {
        if let uid = input.uid, !uid.isEmpty { return uid }
        return "id:\(input.id)"
    }

    private static func storedState(for deviceKey: String, userDefaults: UserDefaults) -> DeviceState? {
        guard let entry = userDefaults.dictionary(forKey: userDefaultsKey)?[deviceKey] as? [String: Any],
              let appVersion = entry["app_version"] as? String else { return nil }
        return DeviceState(
            appVersion: appVersion,
            emptyTakesInARow: entry["empty_in_a_row"] as? Int ?? 0,
            turnedOff: entry["turned_off"] as? Bool ?? false
        )
    }
}

/// A take the pinned recorder made only for speed, waiting for its
/// transcript. Health counts ride along for the report when the mic moves.
struct PinnedDictationSpeedPathTake: Equatable {
    let input: DictationAudioDevice
    let channelCount: Int
    let sampleRate: Double
    let restarts: Int
    let gaps: Int
    let droppedCallbacks: Int

    /// Local `EventReporter` context; `AnalyticsEventForwardingPolicy`
    /// bounds and buckets it before anything leaves the Mac.
    var reportContext: [String: String] {
        [
            "input_channels": "\(channelCount)",
            "input_rate_hz": "\(Int(sampleRate.rounded()))",
            "restarts": "\(restarts)",
            "gaps": "\(gaps)",
            "dropped_callbacks": "\(droppedCallbacks)",
        ]
    }
}
