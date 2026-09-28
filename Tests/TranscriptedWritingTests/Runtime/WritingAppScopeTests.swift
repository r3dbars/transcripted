import Foundation
import Testing
@testable import TranscriptedKeyboard
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

/// One scope rule (plan decision 4) for capture, the day files, Screen Memory
/// context and suggestions. Password managers are always out.
@Suite("Writing app scope")
struct WritingAppScopeTests {
    private static let slack = "com.tinyspeck.slackmacgap"
    private static let mail = "com.apple.mail"
    private static let onePassword = "com.1password.1password"

    @Test("All apps allows everything except password managers and the user's exclusions")
    func allApps() {
        let scope = WritingAppScope.all
        #expect(scope.allows(Self.slack, excludedApps: []))
        #expect(scope.allows(Self.mail, excludedApps: []))
        #expect(!scope.allows(Self.onePassword, excludedApps: []))
        #expect(!scope.allows("com.apple.Passwords", excludedApps: []))
        #expect(!scope.allows(Self.mail, excludedApps: [Self.mail]))
        // Hosts that don't report a bundle keep Tilde's behavior.
        #expect(scope.allows(nil, excludedApps: []))
        #expect(scope.allows("", excludedApps: []))
    }

    @Test("Only apps I pick allows just the list, and never a password manager")
    func pickedApps() {
        let scope = WritingAppScope.picked([Self.slack, Self.onePassword, "not a bundle id"])
        #expect(scope.mode == .picked)
        #expect(scope.bundleIdentifiers == [Self.onePassword, Self.slack])
        #expect(scope.allows(Self.slack, excludedApps: []))
        #expect(scope.allows("COM.TINYSPECK.SLACKMACGAP", excludedApps: []))
        #expect(!scope.allows(Self.mail, excludedApps: []))
        #expect(!scope.allows(Self.onePassword, excludedApps: []))
        #expect(!scope.allows(Self.slack, excludedApps: [Self.slack]))
        #expect(!scope.allows(nil, excludedApps: []))
        #expect(!WritingAppScope.picked([String]()).allows(Self.slack, excludedApps: []))
    }

    @Test("The stored form defaults to all apps and fails closed on an unknown mode")
    func storedForm() {
        #expect(WritingAppScope(storedMode: nil, storedBundleIdentifiers: [Self.slack]) == .all)
        #expect(WritingAppScope(storedMode: "all", storedBundleIdentifiers: nil) == .all)
        #expect(WritingAppScope(storedMode: "picked", storedBundleIdentifiers: [Self.slack]) == .picked([Self.slack]))
        let future = WritingAppScope(storedMode: "some-future-mode", storedBundleIdentifiers: [Self.slack])
        #expect(!future.allows(Self.slack, excludedApps: []))
    }

    @Test("Preferences round-trip the scope and bump the keyboard's revision")
    func preferencesRoundTrip() throws {
        let suites = try Suites()
        defer { suites.remove() }
        let preferences = WritingPreferences(keyboard: suites.keyboard, app: suites.app)
        #expect(preferences.appScope == .all)
        #expect(!preferences.personalizedSuggestionsEnabled)
        #expect(!preferences.personalSuggestionsAllowed)

        preferences.appScope = .picked([Self.slack])
        #expect(preferences.appScope == .picked([Self.slack]))
        #expect(suites.keyboard.integer(forKey: WritingAppScope.revisionKey) == 1)
        #expect(suites.keyboard.string(forKey: WritingAppScope.modeKey) == "picked")
        preferences.appScope = .all
        #expect(suites.keyboard.integer(forKey: WritingAppScope.revisionKey) == 2)
        #expect(preferences.allows(appBundleIdentifier: Self.mail))
        #expect(!preferences.allows(appBundleIdentifier: Self.onePassword))

        // Personalized suggestions are app-only and need Save my writing.
        preferences.personalizedSuggestionsEnabled = true
        #expect(suites.app.bool(forKey: WritingPreferences.AppKey.personalizedSuggestions.rawValue))
        #expect(suites.keyboard.object(forKey: WritingPreferences.AppKey.personalizedSuggestions.rawValue) == nil)
        #expect(!preferences.personalSuggestionsAllowed)
        preferences.tildeSettings.personalHistoryEnabled = true
        #expect(preferences.saveMyWritingEnabled)
        #expect(preferences.personalSuggestionsAllowed)
    }

    @Test("The keyboard re-reads the scope only when its revision moves")
    func keyboardReaderRevision() throws {
        let suites = try Suites()
        defer { suites.remove() }
        let preferences = WritingPreferences(keyboard: suites.keyboard, app: suites.app)
        let reader = WritingAppScopeReader(defaults: suites.keyboard)
        #expect(reader.current() == .all)

        preferences.appScope = .picked([Self.slack])
        #expect(reader.current() == .picked([Self.slack]))
        #expect(reader.allowsSuggestions(in: Self.slack))
        #expect(!reader.allowsSuggestions(in: Self.mail))

        // A write that skips the revision isn't seen; the next bump is.
        suites.keyboard.set([Self.mail], forKey: WritingAppScope.bundleIdentifiersKey)
        #expect(reader.current() == .picked([Self.slack]))
        preferences.appScope = .picked([Self.mail])
        #expect(reader.current() == .picked([Self.mail]))

        preferences.appScope = .all
        #expect(reader.allowsSuggestions(in: Self.mail))
        #expect(!reader.allowsSuggestions(in: Self.onePassword))
        suites.keyboard.set([Self.mail], forKey: PersonalHistorySettingsContract.excludedAppsKey)
        #expect(!reader.allowsSuggestions(in: Self.mail))
    }

    @Test("Capture checks the scope in the keyboard's policy")
    func capturePolicy() {
        let policy = PersonalHistoryCapturePolicy()
        let picked = WritingAppScope.picked([Self.slack])
        #expect(policy.decision(
            enabled: true, secureInput: false, appBundleIdentifier: Self.slack, excludedApps: [], appScope: picked
        ) == .allowed(appBundleIdentifier: Self.slack))
        #expect(policy.decision(
            enabled: true, secureInput: false, appBundleIdentifier: Self.mail, excludedApps: [], appScope: picked
        ) == .blocked(.outsideAppScope))
        #expect(policy.decision(
            enabled: true,
            secureInput: false,
            appBundleIdentifier: Self.onePassword,
            excludedApps: [],
            appScope: .picked([Self.onePassword])
        ) == .blocked(.excludedApp))
        #expect(policy.decision(
            enabled: true, secureInput: false, appBundleIdentifier: Self.mail, excludedApps: []
        ) == .allowed(appBundleIdentifier: Self.mail))
    }

    @Test("The keyboard never captures outside the scope, even text queued before a change")
    func keyboardCapture() async throws {
        let suites = try Suites()
        defer { suites.remove() }
        let defaults = suites.keyboard
        defaults.set(true, forKey: PersonalHistorySettingsContract.enabledKey)
        defaults.set("history", forKey: PersonalHistorySettingsContract.historyIdentifierKey)
        defaults.set("consent", forKey: PersonalHistorySettingsContract.consentIdentifierKey)
        let preferences = WritingPreferences(keyboard: defaults, app: suites.app)
        let sink = Sink()
        let capture = PersonalHistoryCapture(
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_786_600_000) },
            sender: { await sink.record($0) }
        )

        preferences.appScope = .picked([Self.slack])
        #expect(capture.permit(appBundleIdentifier: Self.mail, secureInput: false) == nil)
        let slackPermit = try #require(capture.permit(appBundleIdentifier: Self.slack, secureInput: false))
        capture.record(text: "queued", source: .typed, sessionIdentifier: "chain", permit: slackPermit)
        preferences.appScope = .picked([Self.mail])
        await capture.flushAndWait()
        #expect(await sink.events.isEmpty)
    }

    @Test("Suggestions check the same scope as capture")
    func suggestionsGate() {
        func allows(_ app: String?, scope: WritingAppScope, excluded: Set<String> = []) -> Bool {
            WritingSuggestionsGate.allows(WritingSuggestionsGate.Inputs(
                suggestionsEnabled: true,
                pausedUntil: nil,
                screenMemoryEnabled: true,
                screenRecordingGranted: true,
                now: Date(timeIntervalSince1970: 1_800_000_000),
                appBundleIdentifier: app,
                appScope: scope,
                excludedApps: excluded
            ))
        }
        #expect(allows(Self.mail, scope: .all))
        // The Tilde bug: an ignored app still got ghosts.
        #expect(!allows(Self.mail, scope: .all, excluded: [Self.mail]))
        #expect(!allows(Self.onePassword, scope: .all))
        #expect(allows(Self.slack, scope: .picked([Self.slack])))
        #expect(!allows(Self.mail, scope: .picked([Self.slack])))
        #expect(!allows(nil, scope: .picked([Self.slack])))
    }

    @Test("The app re-checks the scope before a batch reaches the log or the day files")
    func ingestRechecksScope() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripted-scope-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("writing", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let recorder = WritingDayFileRecorder(
            directory: { directory },
            gate: { .init(enabled: true, historyIdentifier: "history", consentIdentifier: "consent") },
            appName: { _ in "App" }
        )
        let controller = Controller()
        let ingest = WritingHistoryIngest(
            personalHistory: controller,
            dayFiles: recorder,
            appScope: { .picked([Self.slack]) }
        )
        let mailEvent = PersonalHistoryEvent(
            id: "mail",
            timestampMilliseconds: 1_786_600_000_000,
            historyIdentifier: "history",
            consentIdentifier: "consent",
            sessionIdentifier: "chain",
            appBundleIdentifier: Self.mail,
            source: .typed,
            text: "outside the scope"
        )!
        #expect(await ingest.ingest([mailEvent]))
        #expect(await controller.batches.isEmpty)
        recorder.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Helpers

    private actor Sink {
        private(set) var events: [PersonalHistoryEvent] = []

        func record(_ batch: [PersonalHistoryEvent]) -> GhostBrainResponse {
            events.append(contentsOf: batch)
            return .recorded
        }
    }

    private actor Controller: PersonalHistoryIngesting {
        private(set) var batches: [[PersonalHistoryEvent]] = []

        func ingest(_ events: [PersonalHistoryEvent]) async -> Bool {
            batches.append(events)
            return true
        }
    }

    private struct Suites {
        let name = "transcripted.tests.app-scope.\(UUID().uuidString)"
        let keyboard: UserDefaults
        let app: UserDefaults

        init() throws {
            keyboard = try #require(UserDefaults(suiteName: name + ".keyboard"))
            app = try #require(UserDefaults(suiteName: name + ".app"))
        }

        func remove() {
            keyboard.removePersistentDomain(forName: name + ".keyboard")
            app.removePersistentDomain(forName: name + ".app")
        }
    }
}
