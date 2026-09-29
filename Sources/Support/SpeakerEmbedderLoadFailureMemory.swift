// SpeakerEmbedderLoadFailureMemory.swift
// Remembers a voiceprint model that failed to load on this app build and macOS
// version, so the next launch builds the meeting stack on WeSpeaker and
// `speakers.sqlite` instead.
//
// The launch picks the voiceprint model, and with it the speaker database, from
// model-file presence alone, because loading the model on the main actor froze the
// menubar (SpeakerEmbedderFactory). The model then loads in the background. If that
// load fails, the running launch keeps the database it picked and just gets no
// voiceprints (nothing of the wrong size ever reaches that file). This memory makes
// the following launches fall back fully, the way a failed load used to fall back
// on the spot. A new app build or macOS update tries the model again.
//
// Foundation-only so the fast-test runner can compile it.

import Foundation

// `@unchecked`: UserDefaults is thread-safe but not marked Sendable; the background
// load records its outcome from the load queue.
struct SpeakerEmbedderLoadFailureMemory: @unchecked Sendable {
    static let defaultsKey = "speaker-embedder-load-failures"

    private let userDefaults: UserDefaults
    /// App build plus macOS version. A failure only counts on the same key.
    let buildKey: String

    init(userDefaults: UserDefaults = .standard, buildKey: String = Self.currentBuildKey()) {
        self.userDefaults = userDefaults
        self.buildKey = buildKey
    }

    static func currentBuildKey(
        bundle: Bundle = .main,
        operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> String {
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(build)|\(operatingSystemVersion)"
    }

    /// Whether the model with `identifier` failed to load on this build.
    func failedOnThisBuild(_ identifier: String) -> Bool {
        failures[identifier] == buildKey
    }

    func recordLoadEnded(_ identifier: String, loaded: Bool) {
        var updated = failures
        updated[identifier] = loaded ? nil : buildKey
        if updated.isEmpty {
            userDefaults.removeObject(forKey: Self.defaultsKey)
        } else {
            userDefaults.set(updated, forKey: Self.defaultsKey)
        }
    }

    /// The voiceprint model id the meeting stack is built around this launch, nil
    /// for WeSpeaker: the chosen model's id when its file is present and it hasn't
    /// failed to load on this build. The speaker database follows from it
    /// (`SpeakerEmbedderPreferences.speakerDBFileName(forEmbedderIdentifier:)`).
    func launchModelIdentifier(chosen identifier: String?, modelFileIsPresent: Bool) -> String? {
        guard let identifier, modelFileIsPresent, !failedOnThisBuild(identifier) else { return nil }
        return identifier
    }

    private var failures: [String: String] {
        userDefaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }
}
