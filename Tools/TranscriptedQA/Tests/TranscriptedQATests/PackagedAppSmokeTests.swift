import XCTest
@testable import transcripted_qa

final class PackagedAppSmokeTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackagedAppSmokeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testPackagedAppSmokePassesStaticFixtureWithOnlyUISmokeWarning() throws {
        let fixture = try makeFixture()
        let report = makeRunner(fixture: fixture).run(generatedAt: Date(timeIntervalSince1970: 1_777_777_777))

        XCTAssertFalse(report.checks.contains { $0.status == .fail })
        XCTAssertTrue(report.checks.contains { $0.id == "bundle-version" && $0.status == .pass })
        XCTAssertTrue(report.checks.contains { $0.id == "sparkle-feed-url" && $0.status == .pass })
        XCTAssertTrue(report.checks.contains { $0.id == "release-dsym-uuid" && $0.status == .pass })
        XCTAssertTrue(report.checks.contains { $0.id == "release-dmg" && $0.status == .pass })
        XCTAssertTrue(report.checks.contains { $0.id == "logs/privacy-scan" && $0.status == .pass })
        XCTAssertEqual(report.status, .warn)
        XCTAssertEqual(report.exitCode, 3)
    }

    func testMissingDSYMFailsByDefault() throws {
        let fixture = try makeFixture()
        try FileManager.default.removeItem(at: fixture.dSYM)

        let report = makeRunner(fixture: fixture).run()

        XCTAssertTrue(report.checks.contains {
            $0.id == "release-dsym" && $0.status == .fail
        })
        XCTAssertEqual(report.exitCode, 1)
    }

    func testMissingDSYMCanBeAllowedForPartialLocalSmoke() throws {
        let fixture = try makeFixture()
        try FileManager.default.removeItem(at: fixture.dSYM)

        let report = makeRunner(fixture: fixture, requireDSYM: false).run()

        XCTAssertTrue(report.checks.contains {
            $0.id == "release-dsym" && $0.status == .warn
        })
        XCTAssertFalse(report.checks.contains {
            $0.id == "release-dsym" && $0.status == .fail
        })
    }

    func testDsymUUIDMismatchFails() throws {
        let fixture = try makeFixture()
        let commandRunner = FakePackagedAppSmokeCommandRunner(dSYMUUID: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")

        let report = makeRunner(fixture: fixture, commandRunner: commandRunner).run()

        XCTAssertTrue(report.checks.contains {
            $0.id == "release-dsym-uuid" && $0.status == .fail
        })
    }

    func testBundleIdentifierMismatchFails() throws {
        let fixture = try makeFixture(bundleIdentifier: "com.example.other")

        let report = makeRunner(fixture: fixture).run()

        XCTAssertTrue(report.checks.contains {
            $0.id == "bundle-identifier" && $0.status == .fail
        })
    }

    func testMissingSparklePublicKeyFails() throws {
        let fixture = try makeFixture(publicKey: "")

        let report = makeRunner(fixture: fixture).run()

        XCTAssertTrue(report.checks.contains {
            $0.id == "sparkle-public-key" && $0.status == .fail
        })
    }

    func testPrivacyLogScannerRejectsSensitiveKeysAndValues() {
        let findings = PrivacyLogScanner.findings(in: """
        {"t":"2026-06-08T12:00:00Z","l":"info","s":"app","m":"saved","transcript_text":"private words"}
        {"t":"2026-06-08T12:00:01Z","l":"info","s":"app","m":"path","context":"/Users/redbars/private.wav"}
        token=super-secret
        """)

        XCTAssertTrue(findings.contains { $0.contains("transcript_text") })
        XCTAssertTrue(findings.contains { $0.contains("absolute local path") || $0.contains("context") })
        XCTAssertTrue(findings.contains { $0.contains("token/secret") })
    }

    func testMissingExecutableFails() throws {
        let fixture = try makeFixture()
        try FileManager.default.removeItem(at: fixture.app.appendingPathComponent("Contents/MacOS/Transcripted"))

        let report = makeRunner(fixture: fixture).run()

        XCTAssertTrue(report.checks.contains {
            $0.id == "app-executable" && $0.status == .fail
        })
    }

    private func makeRunner(
        fixture: Fixture,
        requireDSYM: Bool = true,
        requireDMG: Bool = true,
        commandRunner: PackagedAppSmokeCommandRunning = FakePackagedAppSmokeCommandRunner()
    ) -> PackagedAppSmokeRunner {
        PackagedAppSmokeRunner(
            appBundlePath: fixture.app.path,
            sourceInfoPlistPath: fixture.sourceInfoPlist.path,
            dSYMPath: fixture.dSYM.path,
            dmgPath: fixture.dmg.path,
            appcastPath: fixture.appcast.path,
            logPaths: [fixture.log.path],
            reportPath: nil,
            uiReportPath: nil,
            uiTimeout: 1,
            requireDSYM: requireDSYM,
            requireDMG: requireDMG,
            runUISmoke: false,
            allowExistingInstance: false,
            promptForAccessibility: false,
            verifyCodeSignature: true,
            commandRunner: commandRunner
        )
    }

    private func makeFixture(
        bundleIdentifier: String = "com.justinbetker.draft",
        publicKey: String = "Ib6MHm4eeZYjhsZblNT0DEo3LzK9fYvBLkmqvw/Vo7Q="
    ) throws -> Fixture {
        let app = tempRoot.appendingPathComponent("build/Transcripted.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworks.appendingPathComponent("Sparkle.framework", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)

        let executable = macOS.appendingPathComponent("Transcripted", isDirectory: false)
        try "binary".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let helper = helpers.appendingPathComponent("transcripted-mcp", isDirectory: false)
        try "helper".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let sourceInfoPlist = tempRoot.appendingPathComponent("Info.plist", isDirectory: false)
        let builtInfoPlist = contents.appendingPathComponent("Info.plist", isDirectory: false)
        let plist = infoPlist(bundleIdentifier: bundleIdentifier, publicKey: publicKey)
        try writePlist(plist, to: sourceInfoPlist)
        try writePlist(plist, to: builtInfoPlist)

        let dSYM = tempRoot.appendingPathComponent("build/Transcripted.app.dSYM", isDirectory: true)
        let dwarf = dSYM.appendingPathComponent("Contents/Resources/DWARF", isDirectory: true)
        try FileManager.default.createDirectory(at: dwarf, withIntermediateDirectories: true)
        try "debug".write(to: dwarf.appendingPathComponent("Transcripted", isDirectory: false), atomically: true, encoding: .utf8)

        let dmg = tempRoot.appendingPathComponent("build/Transcripted-1.1.46.dmg", isDirectory: false)
        try Data([0x64, 0x6d, 0x67]).write(to: dmg)

        let appcast = tempRoot.appendingPathComponent("docs/appcast.xml", isDirectory: false)
        try FileManager.default.createDirectory(at: appcast.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item><enclosure sparkle:edSignature="abc" /></item>
          </channel>
        </rss>
        """.write(to: appcast, atomically: true, encoding: .utf8)

        let log = tempRoot.appendingPathComponent("app.jsonl", isDirectory: false)
        try """
        {"t":"2026-06-08T12:00:00Z","l":"info","s":"app","m":"packaged smoke fixture"}
        """.write(to: log, atomically: true, encoding: .utf8)

        return Fixture(app: app, sourceInfoPlist: sourceInfoPlist, dSYM: dSYM, dmg: dmg, appcast: appcast, log: log)
    }

    private func infoPlist(bundleIdentifier: String, publicKey: String) -> [String: Any] {
        [
            "CFBundleName": "Transcripted",
            "CFBundleDisplayName": "Transcripted",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "Transcripted",
            "CFBundleShortVersionString": "1.1.46",
            "CFBundleVersion": "1.1.46",
            "LSMinimumSystemVersion": "26.0",
            "SUFeedURL": "https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/appcast.xml",
            "SUPublicEDKey": publicKey,
            "SUEnableAutomaticChecks": true,
            "SUAllowsAutomaticUpdates": true,
            "SUScheduledCheckInterval": 14_400,
            "TranscriptedSentryDSN": "https://example@sentry.example/1",
            "TranscriptedSentryReleasePrefix": "transcripted",
            "TranscriptedPostHogHost": "https://us.i.posthog.com",
        ]
    }

    private func writePlist(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

private struct Fixture {
    let app: URL
    let sourceInfoPlist: URL
    let dSYM: URL
    let dmg: URL
    let appcast: URL
    let log: URL
}

private struct FakePackagedAppSmokeCommandRunner: PackagedAppSmokeCommandRunning {
    var binaryUUID: String = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    var dSYMUUID: String = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    var codesignExitCode: Int32 = 0
    var hdiutilExitCode: Int32 = 0

    func run(_ executable: String, _ arguments: [String]) -> PackagedAppSmokeCommandResult {
        if executable.contains("codesign") {
            return PackagedAppSmokeCommandResult(exitCode: codesignExitCode, stdout: "", stderr: codesignExitCode == 0 ? "" : "bad signature")
        }
        if executable.contains("dwarfdump") {
            let path = arguments.last ?? ""
            let uuid = path.contains(".dSYM") ? dSYMUUID : binaryUUID
            return PackagedAppSmokeCommandResult(exitCode: 0, stdout: "UUID: \(uuid) (arm64) \(path)\n", stderr: "")
        }
        if executable.contains("hdiutil") {
            return PackagedAppSmokeCommandResult(exitCode: hdiutilExitCode, stdout: hdiutilExitCode == 0 ? "Format Description: UDZO\n" : "", stderr: hdiutilExitCode == 0 ? "" : "bad dmg")
        }
        return PackagedAppSmokeCommandResult(exitCode: 127, stdout: "", stderr: "unexpected command \(executable)")
    }
}
