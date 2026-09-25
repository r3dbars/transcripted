import AppKit
#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Carbon
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

    @discardableResult
    func installOrUpdateIfNeeded() -> KeyboardInstallResult {
        let bundled = URL(fileURLWithPath: Bundle.main.bundlePath).appendingPathComponent(Self.bundledPathInApp)
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            return .unavailableInDevelopment
        }
        let installed = URL(fileURLWithPath: Self.installedPath)
        var changed = false

        do {
            guard let ownerTeam = Self.ownerTeamIdentifier else {
                throw CocoaError(.fileReadNoPermission)
            }
            changed = try Self.installIfNeeded(
                bundled: bundled,
                installed: installed,
                expectedTeamIdentifier: ownerTeam,
                trust: { Self.strictSignatureTeamIdentifier(at: $0) }
            )
            if changed {
                DiagnosticsLog.shared.record("ime-installed", metadata: [:])
                // Live IME picks up the new binary on its next relaunch.
                NSWorkspace.shared.runningApplications
                    .filter { $0.bundleIdentifier == Self.bundleIdentifier }
                    .forEach { $0.terminate() }
            }
        } catch {
            DiagnosticsLog.shared.record("ime-install-failed", metadata: [:])
            return .failed
        }

        // Registration is wiped whenever TextInputMenuAgent restarts — re-run
        // every launch; it is idempotent.
        guard TISRegisterInputSource(installed as CFURL) == noErr else {
            DiagnosticsLog.shared.record("ime-register-failed", metadata: [:])
            return .failed
        }
        return changed ? .installed : .alreadyInstalled
    }

    func inputSourceStatus() -> TildeInputSourceStatus {
        guard let source = trustedEnabledInputSource() else {
            return .missing
        }
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              CFEqual(current, source) else {
            return .available
        }
        return .selected
    }

    @discardableResult
    func selectInputSourceIfAvailable() -> Bool {
        guard let source = trustedEnabledInputSource(),
              Self.booleanProperty(kTISPropertyInputSourceIsSelectCapable, of: source) else {
            return false
        }
        return TISSelectInputSource(source) == noErr
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

    private func trustedEnabledInputSource() -> TISInputSource? {
        let installed = URL(fileURLWithPath: Self.installedPath)
        guard let ownerTeam = Self.ownerTeamIdentifier,
              Self.strictSignatureTeamIdentifier(at: installed) == ownerTeam,
              (try? Self.validateInputMethod(at: installed, fileManager: .default)) != nil,
              TISRegisterInputSource(installed as CFURL) == noErr,
              let sources = TISCreateInputSourceList(
                [kTISPropertyInputSourceID: Self.bundleIdentifier] as CFDictionary,
                false
              )?.takeRetainedValue() as? [TISInputSource],
              sources.count == 1,
              let source = sources.first,
              Self.stringProperty(kTISPropertyBundleID, of: source) == Self.bundleIdentifier,
              Self.booleanProperty(kTISPropertyInputSourceIsEnabled, of: source) else {
            return nil
        }
        return source
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

    /// Transcripted deviation from Tilde: this app's own seal is validated once
    /// per launch. The strict nested check over the whole ~550 MB bundle costs
    /// about 0.2 s on the main thread, and the running app's bundle can't
    /// change until it relaunches. The keyboard bundles are still checked
    /// every time.
    private static let ownerTeamIdentifier: String? = strictSignatureTeamIdentifier(at: Bundle.main.bundleURL)

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
