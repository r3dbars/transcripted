import Foundation
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

@Suite("Keyboard installer")
struct GhostKeyboardInstallerHostTests {
    private let fileManager = FileManager.default
    private static let teamIdentifier = "TESTTEAM123"

    private func makeBundle(
        at url: URL,
        identifier: String = "com.justinbetker.draft.inputmethod.Transcripted",
        contents: String,
        build: Int,
        teamIdentifier: String = Self.teamIdentifier
    ) throws {
        let executable = url.appendingPathComponent("Contents/MacOS/TranscriptedKeyboard")
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "TranscriptedKeyboard",
            "CFBundleVersion": String(build),
            "TestTeamIdentifier": teamIdentifier,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(contents.utf8).write(to: executable)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    }

    private static func testTrust(at app: URL) -> String? {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: Any] else { return nil }
        return info["TestTeamIdentifier"] as? String
    }

    private func install(_ bundled: URL, over installed: URL) throws -> Bool {
        try GhostKeyboardInstallerHost.installIfNeeded(
            bundled: bundled,
            installed: installed,
            expectedTeamIdentifier: Self.teamIdentifier,
            trust: { Self.testTrust(at: $0) },
            fileManager: fileManager
        )
    }

    @Test("A ready replacement swaps in without leaving staging files")
    func replacesInstalledBundle() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = root.appendingPathComponent("Bundled.app")
        let installed = root.appendingPathComponent("Input Methods/Transcripted Keyboard.app")
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(at: bundled, contents: "new", build: 2)
        try makeBundle(at: installed, contents: "old", build: 1)

        #expect(try install(bundled, over: installed))
        let binary = installed.appendingPathComponent("Contents/MacOS/TranscriptedKeyboard")
        #expect(try String(contentsOf: binary, encoding: .utf8) == "new")
        let siblings = try fileManager.contentsOfDirectory(
            at: installed.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(siblings.map(\.lastPathComponent) == ["Transcripted Keyboard.app"])
    }

    @Test("An invalid packaged keyboard cannot disturb the installed keyboard")
    func rejectsInvalidSourceBeforeMutation() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = root.appendingPathComponent("Bundled.app")
        let installed = root.appendingPathComponent("Input Methods/Transcripted Keyboard.app")
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(at: bundled, identifier: "example.invalid", contents: "bad", build: 2)
        try makeBundle(at: installed, contents: "working", build: 1)

        #expect(throws: (any Error).self) {
            try install(bundled, over: installed)
        }
        let binary = installed.appendingPathComponent("Contents/MacOS/TranscriptedKeyboard")
        #expect(try String(contentsOf: binary, encoding: .utf8) == "working")
    }

    @Test("An older packaged keyboard cannot downgrade the installed keyboard")
    func doesNotDowngrade() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = root.appendingPathComponent("Bundled.app")
        let installed = root.appendingPathComponent("Input Methods/Transcripted Keyboard.app")
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(at: bundled, contents: "old", build: 4)
        try makeBundle(at: installed, contents: "new", build: 5)

        #expect(try !install(bundled, over: installed))
        let binary = installed.appendingPathComponent("Contents/MacOS/TranscriptedKeyboard")
        #expect(try String(contentsOf: binary, encoding: .utf8) == "new")
    }

    @Test("An identical packaged keyboard is a no-op")
    func skipsIdenticalBundle() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = root.appendingPathComponent("Bundled.app")
        let installed = root.appendingPathComponent("Input Methods/Transcripted Keyboard.app")
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(at: bundled, contents: "same", build: 5)
        try makeBundle(at: installed, contents: "same", build: 5)

        #expect(try !install(bundled, over: installed))
    }

    @Test("A same-build developer rebuild updates the keyboard")
    func replacesSameBuildWhenBinaryChanged() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = root.appendingPathComponent("Bundled.app")
        let installed = root.appendingPathComponent("Input Methods/Transcripted Keyboard.app")
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(at: bundled, contents: "changed", build: 5)
        try makeBundle(at: installed, contents: "old", build: 5)

        #expect(try install(bundled, over: installed))
    }

    @Test("A higher-build keyboard from another team is replaced")
    func replacesUntrustedHigherBuild() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = root.appendingPathComponent("Bundled.app")
        let installed = root.appendingPathComponent("Input Methods/Transcripted Keyboard.app")
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(at: bundled, contents: "trusted", build: 5)
        try makeBundle(
            at: installed,
            contents: "untrusted",
            build: 500,
            teamIdentifier: "OTHERTEAM"
        )

        #expect(try install(bundled, over: installed))
        let binary = installed.appendingPathComponent("Contents/MacOS/TranscriptedKeyboard")
        #expect(try String(contentsOf: binary, encoding: .utf8) == "trusted")
    }

    @Test("A corrupt higher-build keyboard is replaced")
    func replacesCorruptHigherBuild() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = root.appendingPathComponent("Bundled.app")
        let installed = root.appendingPathComponent("Input Methods/Transcripted Keyboard.app")
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(at: bundled, contents: "trusted", build: 5)
        try makeBundle(
            at: installed,
            identifier: "example.corrupt",
            contents: "corrupt",
            build: 500
        )

        #expect(try install(bundled, over: installed))
        let binary = installed.appendingPathComponent("Contents/MacOS/TranscriptedKeyboard")
        #expect(try String(contentsOf: binary, encoding: .utf8) == "trusted")
    }

    @Test("A bundled keyboard from another team cannot replace the install")
    func rejectsUntrustedBundledKeyboard() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundled = root.appendingPathComponent("Bundled.app")
        let installed = root.appendingPathComponent("Input Methods/Transcripted Keyboard.app")
        defer { try? fileManager.removeItem(at: root) }

        try makeBundle(
            at: bundled,
            contents: "untrusted",
            build: 6,
            teamIdentifier: "OTHERTEAM"
        )
        try makeBundle(at: installed, contents: "working", build: 5)

        #expect(throws: (any Error).self) {
            try install(bundled, over: installed)
        }
        let binary = installed.appendingPathComponent("Contents/MacOS/TranscriptedKeyboard")
        #expect(try String(contentsOf: binary, encoding: .utf8) == "working")
    }
}
