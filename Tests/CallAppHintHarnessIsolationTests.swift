import Foundation

@MainActor
func testCallAppHintHarnessIsolation() {
    runSuite("The page hint harness admits only owned paths and restores process-only defaults even on failure") {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("run.\(UUID().uuidString)", isDirectory: true)
        let container = root.appendingPathComponent("fixture/container", isDirectory: true)
        try! FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("output"), withIntermediateDirectories: false)
        try! "owned-nonce".write(to: root.appendingPathComponent("owned-run"), atomically: true, encoding: .utf8)
        defer {
            if root.lastPathComponent.hasPrefix("run."),
               root.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let environment = ["TRANSCRIPTED_AUTOMATED_HARNESS": "1", "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1",
                           "CALL_APP_HINT_RUN_ROOT": root.path, "CALL_APP_HINT_RUN_ID": "owned-nonce",
                           "TRANSCRIPTED_CONTAINER_DIR": container.path]
        let isolation = try! CallAppHintHarnessIsolation(environment: environment)
        let suite = "com.transcripted.test.hint-isolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain(["owned-sentinel": "before"], forName: UserDefaults.argumentDomain)
        let persistent = defaults.persistentDomain(forName: suite) ?? [:]
        enum Expected: Error { case stop }
        do {
            try isolation.withPreferences(defaults) {
                assertEqual(defaults.string(forKey: "owned-sentinel"), "before")
                assertEqual(defaults.string(forKey: "transcriptSaveLocation"), root.appendingPathComponent("fixture/library").path)
                assertEqual(AnalyticsPreferences.isEnabled(userDefaults: defaults), false)
                assertEqual(CrashReportingPreferences.isEnabled(userDefaults: defaults), false)
                throw Expected.stop
            }
            assertTrue(false, "the deliberate body error must escape")
        } catch {}
        assertTrue(NSDictionary(dictionary: defaults.volatileDomain(forName: UserDefaults.argumentDomain))
            .isEqual(to: ["owned-sentinel": "before"]), "the whole argument domain is restored")
        assertTrue(NSDictionary(dictionary: persistent).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]),
                   "no persistent preference is written")
        for (key, value) in [("TRANSCRIPTED_AUTOMATED_HARNESS", "0"), ("TRANSCRIPTED_DISABLE_FILE_LOGGER", "0"),
                             ("CALL_APP_HINT_RUN_ID", "wrong"), ("TRANSCRIPTED_CONTAINER_DIR", root.path)] {
            var invalid = environment
            invalid[key] = value
            do {
                _ = try CallAppHintHarnessIsolation(environment: invalid)
                assertTrue(false, "unowned or disabled admission must fail")
            } catch { assertTrue(true) }
        }
    }
}
