import Foundation
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

/// Stands in for Text Input Sources, so no test enables, selects or reads
/// the real Input Sources.
private final class FakeInputSources: WritingInputSourceProviding {
    /// `nil`: no registered source has the keyboard's identifier.
    var registered: Bool? = false
    var enableStatus: OSStatus = OSStatus(noErr)
    /// macOS 26: the enable call returns `noErr` and nothing changes.
    var enableTakesEffect = false
    var trusted: GhostKeyboardInstallerHost.TildeInputSourceStatus = .missing
    var selectWorks = true
    private(set) var enableCalls = 0
    private(set) var selectCalls = 0

    func registeredSourceIsEnabled() -> Bool? { registered }

    func enableRegisteredSource() -> OSStatus {
        enableCalls += 1
        if enableStatus == noErr, enableTakesEffect {
            registered = true
            trusted = .available
        }
        return enableStatus
    }

    func trustedSourceStatus() -> GhostKeyboardInstallerHost.TildeInputSourceStatus { trusted }

    func selectTrustedSource() -> Bool {
        selectCalls += 1
        guard selectWorks, trusted != .missing else { return false }
        trusted = .selected
        return true
    }
}

@Suite("Writing keyboard setup state")
struct WritingKeyboardSetupStateTests {
    // MARK: Honest enable

    @Test("A noErr enable that leaves the keyboard off says the user has to add it")
    func enableThatLiesNeedsUserToAdd() {
        let sources = FakeInputSources()
        sources.enableTakesEffect = false
        #expect(WritingKeyboardInputSource.enable(using: sources) == .needsUserToAdd)
        #expect(sources.enableCalls == 1)
    }

    @Test("A noErr enable that takes effect reports enabled")
    func enableThatWorks() {
        let sources = FakeInputSources()
        sources.enableTakesEffect = true
        let result = WritingKeyboardInputSource.enable(using: sources)
        #expect(result == .enabled)
        #expect(result.isEnabled)
    }

    @Test("Enable skips the call when the keyboard is already on, and reports a missing or failing source")
    func enableOtherResults() {
        let on = FakeInputSources()
        on.registered = true
        #expect(WritingKeyboardInputSource.enable(using: on) == .alreadyEnabled)
        #expect(on.enableCalls == 0)

        let missing = FakeInputSources()
        missing.registered = nil
        #expect(WritingKeyboardInputSource.enable(using: missing) == .notRegistered)
        #expect(missing.enableCalls == 0)

        let failing = FakeInputSources()
        failing.enableStatus = -50
        let result = WritingKeyboardInputSource.enable(using: failing)
        #expect(result == .failed(-50))
        #expect(!result.isEnabled)
        #expect(!WritingKeyboardInputSource.EnableResult.needsUserToAdd.isEnabled)
    }

    // MARK: Resolution

    @Test("The trusted source's status maps to the four states")
    func resolvesFromTrustedStatus() {
        let sources = FakeInputSources()
        sources.trusted = .selected
        #expect(WritingKeyboardInputSource.state(using: sources, firstInstalledThisLoginSession: true) == .selected)
        sources.trusted = .available
        #expect(WritingKeyboardInputSource.state(using: sources, firstInstalledThisLoginSession: true) == .enabledNotSelected)
        sources.trusted = .missing
        #expect(WritingKeyboardInputSource.state(using: sources, firstInstalledThisLoginSession: false) == .needsUserToAdd)
        #expect(WritingKeyboardInputSource.state(using: sources, firstInstalledThisLoginSession: true) == .needsRelogin)
    }

    @Test("Relogin applies only while the keyboard is off")
    func reloginOnlyWhileOff() {
        #expect(WritingKeyboardSetupState.resolve(enabled: true, selected: false, firstInstalledThisLoginSession: true) == .enabledNotSelected)
        #expect(WritingKeyboardSetupState.resolve(enabled: true, selected: true, firstInstalledThisLoginSession: true) == .selected)
        #expect(WritingKeyboardSetupState.resolve(enabled: false, selected: false, firstInstalledThisLoginSession: true) == .needsRelogin)
        #expect(WritingKeyboardSetupState.resolve(enabled: false, selected: false, firstInstalledThisLoginSession: false) == .needsUserToAdd)
    }

    // MARK: Automatic pickup

    @Test("Once the user adds the keyboard, a refresh selects it once")
    func selectsOnceAfterItIsAdded() {
        let sources = FakeInputSources()
        var refresh = WritingKeyboardInputSource.refresh(
            using: sources, previous: nil, firstInstalledThisLoginSession: true, selectedOnce: false
        )
        #expect(refresh == .init(state: .needsRelogin, selectSucceeded: nil))

        // The user logs out and back in, then adds it in Keyboard settings.
        sources.trusted = .available
        refresh = WritingKeyboardInputSource.refresh(
            using: sources, previous: .needsUserToAdd, firstInstalledThisLoginSession: false, selectedOnce: false
        )
        #expect(refresh == .init(state: .selected, selectSucceeded: true))
        #expect(sources.selectCalls == 1)
        #expect(sources.enableCalls == 0, "a refresh never calls the enable macOS ignores")
    }

    @Test("A refresh never takes the keyboard back after the user picked another input source")
    func respectsTheUsersChoice() {
        let sources = FakeInputSources()
        sources.trusted = .available
        let fromSelected = WritingKeyboardInputSource.refresh(
            using: sources, previous: .selected, firstInstalledThisLoginSession: false, selectedOnce: true
        )
        #expect(fromSelected == .init(state: .enabledNotSelected, selectSucceeded: nil))
        let steady = WritingKeyboardInputSource.refresh(
            using: sources, previous: .enabledNotSelected, firstInstalledThisLoginSession: false, selectedOnce: false
        )
        #expect(steady == .init(state: .enabledNotSelected, selectSucceeded: nil))
        let firstReadAfterSelectedOnce = WritingKeyboardInputSource.refresh(
            using: sources, previous: nil, firstInstalledThisLoginSession: false, selectedOnce: true
        )
        #expect(firstReadAfterSelectedOnce == .init(state: .enabledNotSelected, selectSucceeded: nil))
        #expect(sources.selectCalls == 0)
    }

    @Test("The first read selects a keyboard that was never selected")
    func firstReadSelectsWhenNeverSelected() {
        let sources = FakeInputSources()
        sources.trusted = .available
        let refresh = WritingKeyboardInputSource.refresh(
            using: sources, previous: nil, firstInstalledThisLoginSession: false, selectedOnce: false
        )
        #expect(refresh == .init(state: .selected, selectSucceeded: true))
    }

    @Test("A select that fails leaves the input-menu step up")
    func failedSelectKeepsGuidance() {
        let sources = FakeInputSources()
        sources.trusted = .available
        sources.selectWorks = false
        let refresh = WritingKeyboardInputSource.refresh(
            using: sources, previous: .needsRelogin, firstInstalledThisLoginSession: false, selectedOnce: false
        )
        #expect(refresh == .init(state: .enabledNotSelected, selectSucceeded: false))
        #expect(sources.selectCalls == 1)
    }

    @Test("Only a keyboard that just became enabled is selected")
    func shouldSelectTable() {
        let states: [WritingKeyboardSetupState?] = [nil, .selected, .enabledNotSelected, .needsUserToAdd, .needsRelogin]
        for previous in states {
            for current in [WritingKeyboardSetupState.selected, .needsUserToAdd, .needsRelogin] {
                #expect(!WritingKeyboardSetupState.shouldSelect(previous: previous, current: current, selectedOnce: false))
            }
        }
        #expect(WritingKeyboardSetupState.shouldSelect(previous: .needsUserToAdd, current: .enabledNotSelected, selectedOnce: true))
        #expect(WritingKeyboardSetupState.shouldSelect(previous: .needsRelogin, current: .enabledNotSelected, selectedOnce: true))
        #expect(WritingKeyboardSetupState.shouldSelect(previous: nil, current: .enabledNotSelected, selectedOnce: false))
        #expect(!WritingKeyboardSetupState.shouldSelect(previous: nil, current: .enabledNotSelected, selectedOnce: true))
        #expect(!WritingKeyboardSetupState.shouldSelect(previous: .selected, current: .enabledNotSelected, selectedOnce: false))
        #expect(!WritingKeyboardSetupState.shouldSelect(previous: .enabledNotSelected, current: .enabledNotSelected, selectedOnce: false))
    }

    // MARK: First install this login session

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "WritingKeyboardSetupStateTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("A keyboard first installed this login session needs a relogin until the session changes")
    func firstInstallMarkerFollowsTheSession() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!WritingKeyboardFirstInstall.happenedThisLoginSession(currentSession: "boot-1-asid-100", defaults: defaults))
        WritingKeyboardFirstInstall.record(currentSession: "boot-1-asid-100", defaults: defaults)
        #expect(WritingKeyboardFirstInstall.happenedThisLoginSession(currentSession: "boot-1-asid-100", defaults: defaults))
        // Logged out and back in: a new audit session.
        #expect(!WritingKeyboardFirstInstall.happenedThisLoginSession(currentSession: "boot-1-asid-101", defaults: defaults))
        // Restarted, and the audit session ID came around again.
        #expect(!WritingKeyboardFirstInstall.happenedThisLoginSession(currentSession: "boot-2-asid-100", defaults: defaults))
        // An unknown session never claims a relogin is needed.
        #expect(!WritingKeyboardFirstInstall.happenedThisLoginSession(currentSession: nil, defaults: defaults))
    }

    @Test("An unknown session records nothing")
    func unknownSessionRecordsNothing() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        WritingKeyboardFirstInstall.record(currentSession: nil, defaults: defaults)
        WritingKeyboardFirstInstall.record(currentSession: "", defaults: defaults)
        #expect(defaults.string(forKey: WritingKeyboardFirstInstall.sessionDefaultsKey) == nil)
        #expect(!WritingKeyboardSetupState.firstInstalledThisLoginSession(recordedSession: "", currentSession: ""))
    }

    @Test("The login session identifier names the boot and the audit session")
    func loginSessionIdentifierShape() throws {
        // Reads getaudit_addr and kern.boottime only; no Input Sources call.
        let identifier = try #require(WritingLoginSession.currentIdentifier())
        #expect(identifier.hasPrefix("boot-"))
        #expect(identifier.contains("-asid-"))
        #expect(WritingLoginSession.currentIdentifier() == identifier)
    }
}
