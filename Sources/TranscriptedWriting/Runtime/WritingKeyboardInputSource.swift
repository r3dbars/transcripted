#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Carbon
import Darwin
import Foundation

/// The Text Input Sources calls behind the Writing keyboard step. The app
/// uses `SystemWritingInputSources`; tests pass a fake, so no test ever
/// enables, selects or reads the real Input Sources.
protocol WritingInputSourceProviding {
    /// The keyboard's registered source, enabled or not: whether it's
    /// enabled, or `nil` when no registered source has its identifier.
    func registeredSourceIsEnabled() -> Bool?
    /// `TISEnableInputSource` on that source.
    func enableRegisteredSource() -> OSStatus
    /// The trusted source (signed by this app's team, registered) as Input
    /// Sources lists it right now.
    func trustedSourceStatus() -> GhostKeyboardInstallerHost.TildeInputSourceStatus
    /// `TISSelectInputSource` on the trusted, enabled source. `true` when
    /// the call went through.
    func selectTrustedSource() -> Bool
}

/// Turns the keyboard on in Input Sources where macOS allows it, and reads
/// where it stands. Tilde's installer registers and selects the keyboard but
/// never enables it, so Tilde users added it by hand in System Settings
/// (docs/writing-plan.md, "Permissions").
///
/// macOS 26 ignores the enable: `TISEnableInputSource` returns `noErr` and
/// the source stays off, even in a later process. So `enable(using:)` reads
/// the source again and says so, and the Writing tab tells the user how to
/// add the keyboard (`WritingKeyboardSetupState`).
///
/// Call it on the main thread, right after
/// `GhostKeyboardInstallerHost.installOrUpdateIfNeeded()` succeeded: that
/// call validated the installed bundle's signature and registered it, and
/// this looks the source up by that same identifier.
enum WritingKeyboardInputSource {
    enum EnableResult: Equatable, Sendable {
        /// `TISEnableInputSource` returned `noErr` and the source reads as
        /// enabled afterwards.
        case enabled
        case alreadyEnabled
        /// `TISEnableInputSource` returned `noErr` but the source still
        /// reads as off (macOS 26). The user has to add it in Keyboard
        /// settings.
        case needsUserToAdd
        /// No registered input source has this identifier.
        case notRegistered
        /// `TISEnableInputSource` returned this status.
        case failed(OSStatus)

        /// The source is on, so selecting it can work.
        var isEnabled: Bool { self == .enabled || self == .alreadyEnabled }
    }

    static func enable(using provider: WritingInputSourceProviding) -> EnableResult {
        guard let isEnabled = provider.registeredSourceIsEnabled() else { return .notRegistered }
        if isEnabled { return .alreadyEnabled }
        let status = provider.enableRegisteredSource()
        guard status == noErr else { return .failed(status) }
        // Don't trust the noErr: read the source again.
        return provider.registeredSourceIsEnabled() == true ? .enabled : .needsUserToAdd
    }

    /// Where the keyboard stands now, from the trusted source only.
    static func state(
        using provider: WritingInputSourceProviding,
        firstInstalledThisLoginSession: Bool
    ) -> WritingKeyboardSetupState {
        let status = provider.trustedSourceStatus()
        return WritingKeyboardSetupState.resolve(
            enabled: status != .missing,
            selected: status == .selected,
            firstInstalledThisLoginSession: firstInstalledThisLoginSession
        )
    }

    struct Refresh: Equatable, Sendable {
        let state: WritingKeyboardSetupState
        /// Whether `TISSelectInputSource` was tried, and if so whether it
        /// went through. `nil` when it wasn't tried.
        let selectSucceeded: Bool?
    }

    /// Reads the state and, when it just became enabled
    /// (`WritingKeyboardSetupState.shouldSelect`), selects the keyboard once
    /// and reads again. Never enables: macOS 26 ignores that, and the user
    /// adds the keyboard themselves.
    static func refresh(
        using provider: WritingInputSourceProviding,
        previous: WritingKeyboardSetupState?,
        firstInstalledThisLoginSession: Bool,
        selectedOnce: Bool
    ) -> Refresh {
        let current = state(using: provider, firstInstalledThisLoginSession: firstInstalledThisLoginSession)
        guard WritingKeyboardSetupState.shouldSelect(
            previous: previous,
            current: current,
            selectedOnce: selectedOnce
        ) else {
            return Refresh(state: current, selectSucceeded: nil)
        }
        let selected = provider.selectTrustedSource()
        return Refresh(
            state: state(using: provider, firstInstalledThisLoginSession: firstInstalledThisLoginSession),
            selectSucceeded: selected
        )
    }
}

/// The real Text Input Sources. Enabling looks the source up by identifier
/// and bundle ID, as before; the state read and selecting go through the
/// installer's trusted lookup (signature, Team ID, enabled).
struct SystemWritingInputSources: WritingInputSourceProviding {
    let installer: GhostKeyboardInstallerHost
    var inputSourceID: String = TildeProductProfile.current.inputMethodBundleIdentifier

    func registeredSourceIsEnabled() -> Bool? {
        registeredSource().map { Self.booleanProperty(kTISPropertyInputSourceIsEnabled, of: $0) }
    }

    func enableRegisteredSource() -> OSStatus {
        guard let source = registeredSource() else { return OSStatus(paramErr) }
        return TISEnableInputSource(source)
    }

    func trustedSourceStatus() -> GhostKeyboardInstallerHost.TildeInputSourceStatus {
        installer.inputSourceStatus()
    }

    func selectTrustedSource() -> Bool {
        installer.selectInputSourceIfAvailable()
    }

    private func registeredSource() -> TISInputSource? {
        guard let sources = TISCreateInputSourceList(
            [kTISPropertyInputSourceID: inputSourceID] as CFDictionary,
            true
        )?.takeRetainedValue() as? [TISInputSource],
              sources.count == 1,
              let source = sources.first,
              Self.stringProperty(kTISPropertyBundleID, of: source) == inputSourceID else {
            return nil
        }
        return source
    }

    private static func stringProperty(_ key: CFString, of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func booleanProperty(_ key: CFString, of source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue() == kCFBooleanTrue
    }
}

/// Remembers when the app first copied the keyboard into
/// `~/Library/Input Methods`, as the login session it happened in. Keyboard
/// settings lists new keyboards only after a logout and login, so while the
/// session is the same the Writing tab says to log out first.
enum WritingKeyboardFirstInstall {
    /// App-suite key (`WritingController.appSuiteName`).
    static let sessionDefaultsKey = "KeyboardFirstInstalledLoginSession"

    /// Call after an install that copied the keyboard in where none was
    /// before. An update over an existing copy doesn't count: the old copy
    /// was already there at login, so Keyboard settings lists it.
    static func record(currentSession: String?, defaults: UserDefaults) {
        guard let currentSession, !currentSession.isEmpty else { return }
        defaults.set(currentSession, forKey: sessionDefaultsKey)
    }

    static func happenedThisLoginSession(currentSession: String?, defaults: UserDefaults) -> Bool {
        WritingKeyboardSetupState.firstInstalledThisLoginSession(
            recordedSession: defaults.string(forKey: sessionDefaultsKey),
            currentSession: currentSession
        )
    }
}

/// Names the current login session: the boot time plus the audit session
/// ID. A logout and login starts a new audit session; a restart changes the
/// boot time, so an ID reused after a reboot never matches an old one.
enum WritingLoginSession {
    static func currentIdentifier() -> String? {
        var info = auditinfo_addr()
        guard getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 else { return nil }
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0, bootTime.tv_sec > 0 else { return nil }
        return "boot-\(bootTime.tv_sec)-asid-\(info.ai_asid)"
    }
}
