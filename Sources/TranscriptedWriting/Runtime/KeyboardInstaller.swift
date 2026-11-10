import AppKit
#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Carbon
import Darwin
import Foundation
import Security

/// Installs the bundled TranscriptedKeyboard input method on launch: copies it from
/// Contents/Library/Input Methods into ~/Library/Input Methods when missing or outdated,
/// registers it with Text Input Services, and reports live input-source state.
/// Setup UI belongs to `TildeSetupWindowController`, not this installer.
final class GhostKeyboardInstallerHost {

    enum KeyboardInstallResult: Equatable {
        case installed
        case alreadyInstalled
        case unavailableInDevelopment
        case failed
    }

    enum TildeInputSourceStatus: Equatable {
        case missing
        case available
        case selected
    }

    typealias TrustDecision = (URL) -> String?

    private static var bundledPathInApp: String {
        "Contents/Library/Input Methods/\(TildeProductProfile.current.inputMethodInstalledBundleName)"
    }
    private static var bundleIdentifier: String {
        TildeProductProfile.current.inputMethodBundleIdentifier
    }
    private static let executableName = "TranscriptedKeyboard"
    private static var installedPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods")
            .appendingPathComponent(TildeProductProfile.current.inputMethodInstalledBundleName)
            .path
    }

    /// The file and signature half of an install.
    enum InstallPreparation: Equatable, Sendable {
        case unavailableInDevelopment
        case failed
        /// The installed keyboard checks out; `changed` when this copied a
        /// fresh one in.
        case ready(changed: Bool)
    }

    /// What `installOrUpdate(using:)` runs. `prepare` reads, signature-checks
    /// and copies bundles, so it runs off the main thread. The rest are Text
    /// Input Sources and NSWorkspace calls, which a UI app must make on the
    /// main thread (TextInputSources.h, "Mac OS X threading").
    struct InstallSteps {
        var prepare: @Sendable () -> InstallPreparation
        /// Whether Input Sources lists the keyboard now, enabled or not.
        var isRegistered: @MainActor () -> Bool
        /// `TISRegisterInputSource` on the installed bundle.
        var register: @MainActor () -> Bool
        /// Quits the running keyboard so it relaunches on the new binary.
        var restartRunningKeyboard: @MainActor () -> Void
    }

    /// Installs or updates the keyboard and makes sure Input Sources lists it.
    @MainActor
    func installOrUpdateIfNeeded() async -> KeyboardInstallResult {
        await Self.installOrUpdate(using: Self.systemSteps)
    }

    /// The file work runs detached; only the Text Input Sources calls come
    /// back to the main thread. `TISRegisterInputSource` forces a rebuild of
    /// the shared input-source cache under a file lock other processes also
    /// take, and once blocked the main thread past 5 s at launch. So an
    /// unchanged keyboard that Input Sources still lists isn't registered
    /// again; one it lost (TextInputMenuAgent restarted) or a fresh copy is.
    @MainActor
    static func installOrUpdate(using steps: InstallSteps) async -> KeyboardInstallResult {
        let prepare = steps.prepare
        let preparation = await Task.detached(priority: .userInitiated) { prepare() }.value
        let changed: Bool
        switch preparation {
        case .unavailableInDevelopment:
            return .unavailableInDevelopment
        case .failed:
            return .failed
        case let .ready(didChange):
            changed = didChange
        }
        if changed {
            steps.restartRunningKeyboard()
        }
        if changed || !steps.isRegistered() {
            guard steps.register() else { return .failed }
        }
        return changed ? .installed : .alreadyInstalled
    }

    @MainActor
    private static var systemSteps: InstallSteps {
        InstallSteps(
            prepare: { prepareSystemInstall() },
            isRegistered: { registeredSourceIsListed() },
            register: {
                let installed = URL(fileURLWithPath: installedPath)
                guard TISRegisterInputSource(installed as CFURL) == noErr else {
                    DiagnosticsLog.shared.record("ime-register-failed", metadata: [:])
                    return false
                }
                return true
            },
            restartRunningKeyboard: {
                NSWorkspace.shared.runningApplications
                    .filter { $0.bundleIdentifier == bundleIdentifier }
                    .forEach { $0.terminate() }
            }
        )
    }

    /// Copies the bundled keyboard into ~/Library/Input Methods when it's
    /// missing or outdated. Disk and code-signature work: never on main.
    private static func prepareSystemInstall() -> InstallPreparation {
        let bundled = URL(fileURLWithPath: Bundle.main.bundlePath).appendingPathComponent(bundledPathInApp)
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            return .unavailableInDevelopment
        }
        do {
            guard let ownerTeam = ownerTeamIdentifier else {
                throw CocoaError(.fileReadNoPermission)
            }
            let changed = try installIfNeeded(
                bundled: bundled,
                installed: URL(fileURLWithPath: installedPath),
                expectedTeamIdentifier: ownerTeam,
                trust: { strictSignatureTeamIdentifier(at: $0) }
            )
            if changed {
                DiagnosticsLog.shared.record("ime-installed", metadata: [:])
            }
            return .ready(changed: changed)
        } catch {
            DiagnosticsLog.shared.record("ime-install-failed", metadata: [:])
            return .failed
        }
    }

    /// A list read by identifier, not the cache rebuild a register forces.
    @MainActor
    private static func registeredSourceIsListed() -> Bool {
        guard let sources = TISCreateInputSourceList(
            [kTISPropertyInputSourceID: bundleIdentifier] as CFDictionary,
            true
        )?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        return sources.contains { stringProperty(kTISPropertyBundleID, of: $0) == bundleIdentifier }
    }

    /// Invocation-local validation crosses the await; native source objects do not.
    struct LookupSteps<Validation: Sendable, Source> {
        var prepare: @Sendable () -> Validation?
        var identityIsCurrent: @MainActor (Validation) -> Bool
        var isRegistered: @MainActor (Validation) -> Bool
        var register: @MainActor (Validation) -> Bool
        var source: @MainActor (Validation) -> Source?
    }

    @MainActor
    static func prepareTrustedSource<Validation: Sendable, Source>(
        using steps: LookupSteps<Validation, Source>,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> Source? {
        guard !Task.isCancelled, isCurrent() else { return nil }
        let prepare = steps.prepare
        let validation = await Task.detached(priority: .userInitiated) { prepare() }.value
        guard !Task.isCancelled, isCurrent(), let validation,
              steps.identityIsCurrent(validation) else { return nil }
        if !steps.isRegistered(validation) {
            guard !Task.isCancelled, isCurrent(), steps.register(validation) else { return nil }
        }
        guard !Task.isCancelled, isCurrent() else { return nil }
        return steps.source(validation)
    }

    @MainActor
    func prepareInputSource(
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> PreparedWritingInputSources? {
        let steps = Self.lookupSteps(isCurrent: isCurrent)
        return await Self.prepareTrustedSource(using: steps, isCurrent: isCurrent)
    }

    /// A short-lived proof for this lookup, never a process-wide trust cache.
    private struct ValidatedInstallation: Sendable {
        let configuredURL: URL
        let identity: InstallationIdentity

        func isCurrent() -> Bool { InstallationIdentity.capture(at: configuredURL) == identity }
    }

    private struct InstallationIdentity: Equatable, Sendable {
        struct Node: Equatable, Sendable {
            let mode: mode_t
            let fingerprint: SecureLocalStorage.FileContentFingerprint
        }
        let installedURL: URL
        let directory: Node
        let executable: Node
        let infoPlist: Node
        let codeResources: Node

        static func capture(at configuredURL: URL) -> InstallationIdentity? {
            let url = configuredURL.resolvingSymlinksInPath().standardizedFileURL
            guard let directory = node(at: url, kind: S_IFDIR),
                  let executable = node(at: url.appendingPathComponent("Contents/MacOS/\(GhostKeyboardInstallerHost.executableName)"), kind: S_IFREG),
                  let info = node(at: url.appendingPathComponent("Contents/Info.plist"), kind: S_IFREG),
                  let resources = node(at: url.appendingPathComponent("Contents/_CodeSignature/CodeResources"), kind: S_IFREG) else {
                return nil
            }
            return InstallationIdentity(installedURL: url, directory: directory,
                executable: executable, infoPlist: info, codeResources: resources)
        }

        private static func node(at url: URL, kind: mode_t) -> Node? {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == kind else { return nil }
            return Node(mode: info.st_mode, fingerprint: .init(info))
        }
    }

    private static func prepareLookup() -> ValidatedInstallation? {
        let configured = URL(fileURLWithPath: installedPath)
        guard let before = InstallationIdentity.capture(at: configured),
              let ownerTeam = ownerTeamIdentifier,
              strictSignatureTeamIdentifier(at: before.installedURL) == ownerTeam,
              (try? validateInputMethod(at: before.installedURL, fileManager: .default)) != nil,
              InstallationIdentity.capture(at: configured) == before else { return nil }
        return ValidatedInstallation(configuredURL: configured, identity: before)
    }

    @MainActor
    private static func lookupSteps(
        isCurrent: @escaping @MainActor () -> Bool
    ) -> LookupSteps<ValidatedInstallation, PreparedWritingInputSources> {
        LookupSteps(
            prepare: { prepareLookup() },
            identityIsCurrent: { $0.isCurrent() },
            isRegistered: { proof in proof.isCurrent() && registeredSourceIsListed() },
            register: { proof in
                guard proof.isCurrent() else { return false }
                return TISRegisterInputSource(proof.identity.installedURL as CFURL) == noErr
            },
            source: { proof in preparedSource(proof: proof, isCurrent: isCurrent) }
        )
    }

    @MainActor
    private static func preparedSource(
        proof: ValidatedInstallation, isCurrent: @escaping @MainActor () -> Bool
    ) -> PreparedWritingInputSources? {
        // Metadata rechecks reject obvious replacement across validation and before
        // native calls. They do not make whole-bundle validation and use atomic.
        let authorized: @MainActor () -> Bool = {
            !Task.isCancelled && isCurrent() && proof.isCurrent()
        }
        // Input-source lists are snapshots. Requery after enable/select instead
        // of assuming a retained source's properties changed with the system.
        let lookup: @MainActor () -> TISInputSource? = {
            guard authorized(),
                  let sources = TISCreateInputSourceList(
                    [kTISPropertyInputSourceID: bundleIdentifier] as CFDictionary, true
                  )?.takeRetainedValue() as? [TISInputSource],
                  sources.count == 1, let source = sources.first,
                  stringProperty(kTISPropertyBundleID, of: source) == bundleIdentifier else { return nil }
            return source
        }
        guard lookup() != nil else { return nil }
        return PreparedWritingInputSources(
            registered: {
                guard let source = lookup() else { return nil }
                return booleanProperty(kTISPropertyInputSourceIsEnabled, of: source)
            },
            enable: {
                guard let source = lookup() else { return OSStatus(paramErr) }
                return TISEnableInputSource(source)
            },
            status: {
                guard let source = lookup(), booleanProperty(kTISPropertyInputSourceIsEnabled, of: source) else { return .missing }
                guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), CFEqual(current, source) else {
                    return .available
                }
                return .selected
            },
            select: {
                guard let source = lookup(), booleanProperty(kTISPropertyInputSourceIsEnabled, of: source),
                      booleanProperty(kTISPropertyInputSourceIsSelectCapable, of: source) else { return false }
                return TISSelectInputSource(source) == noErr
            }
        )
    }

    func openKeyboardSettings() {
        NSWorkspace.shared.open(Self.keyboardSettingsURL)
    }

    private static let keyboardSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    )!

    private static func stringProperty(_ key: CFString, of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func booleanProperty(_ key: CFString, of source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue() == kCFBooleanTrue
    }

    /// Builds the replacement completely before swapping it into the live path.
    /// `replaceItemAt` keeps the old bundle in place if replacement fails.
    @discardableResult
    static func installIfNeeded(
        bundled: URL,
        installed: URL,
        expectedTeamIdentifier: String,
        trust: TrustDecision,
        fileManager: FileManager = .default
    ) throws -> Bool {
        try validateInputMethod(at: bundled, fileManager: fileManager)
        guard !expectedTeamIdentifier.isEmpty,
              trust(bundled) == expectedTeamIdentifier else {
            throw CocoaError(.fileReadNoPermission)
        }

        let installedExists = fileManager.fileExists(atPath: installed.path)
        if installedExists,
           (try? validateInputMethod(at: installed, fileManager: fileManager)) != nil,
           trust(installed) == expectedTeamIdentifier,
           !bundledShouldReplace(bundled: bundled, installed: installed) {
            return false
        }

        let parent = installed.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(TildeProductProfile.current.inputMethodInstalledBundleName).install-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.copyItem(at: bundled, to: staging)
        try validateInputMethod(at: staging, fileManager: fileManager)
        guard trust(staging) == expectedTeamIdentifier else {
            throw CocoaError(.fileReadNoPermission)
        }

        if installedExists {
            _ = try fileManager.replaceItemAt(installed, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: installed)
        }
        return true
    }

    /// Transcripted deviation from Tilde: the owner Team ID comes from the
    /// running app's own code signature (`OwnSigningTeam`), resolved once per
    /// process. The strict static check over the whole ~770 MB bundle it
    /// replaced cost about 0.2 s on the main thread before hotkeys
    /// registered. Ad-hoc and unsigned builds still have no team and fail
    /// closed. The keyboard bundles are still checked strictly every time.
    private static var ownerTeamIdentifier: String? { OwnSigningTeam.current }

    /// Returns a non-empty Team ID only for a bundle whose complete code seal
    /// passes strict validation. Ad-hoc and unsigned bundles fail closed.
    private static func strictSignatureTeamIdentifier(at bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [CFString: Any],
              let team = values[kSecCodeInfoTeamIdentifier] as? String,
              !team.isEmpty else { return nil }
        return team
    }

    private static func validateInputMethod(at app: URL, fileManager: FileManager) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundleExecutable"] as? String == executableName,
              let build = info["CFBundleVersion"] as? String,
              Int(build) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let executable = app.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
    }

    /// Release builds move forward by CFBundleVersion. Equal-build binaries
    /// are compared directly so an uncommitted developer rebuild still updates,
    /// while an older packaged keyboard can never overwrite a newer install.
    private static func bundledShouldReplace(
        bundled: URL,
        installed: URL
    ) -> Bool {
        func buildNumber(_ app: URL) -> Int? {
            let infoURL = app.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: infoURL),
                  let info = try? PropertyListSerialization.propertyList(
                    from: data,
                    format: nil
                  ) as? [String: Any],
                  let value = info["CFBundleVersion"] as? String else {
                return nil
            }
            return Int(value)
        }

        guard let bundledBuild = buildNumber(bundled),
              let installedBuild = buildNumber(installed) else {
            return true
        }
        if bundledBuild != installedBuild {
            return bundledBuild > installedBuild
        }

        let bundledBinary = bundled.appendingPathComponent("Contents/MacOS/\(executableName)")
        let installedBinary = installed.appendingPathComponent("Contents/MacOS/\(executableName)")
        return (try? Data(contentsOf: bundledBinary)) != (try? Data(contentsOf: installedBinary))
    }

}
