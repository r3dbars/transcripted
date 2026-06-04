import Foundation

func testSentryRuntimeConfiguration() {
    runSuite("SentryRuntimeConfiguration lets environment override committed plist config") {
        let info: [String: Any] = [
            SentryRuntimeConfiguration.dsnInfoKey: "https://plist@example.invalid/1",
            SentryRuntimeConfiguration.environmentInfoKey: "production",
        ]
        let environment = [
            SentryRuntimeConfiguration.dsnEnvironmentKey: "https://local@example.invalid/2",
            SentryRuntimeConfiguration.environmentEnvironmentKey: "staging",
        ]

        assertEqual(
            SentryRuntimeConfiguration.dsn(environment: environment, infoDictionary: info),
            "https://local@example.invalid/2",
            "SENTRY_DSN should win so local validation does not accidentally target production"
        )
        assertEqual(
            SentryRuntimeConfiguration.environment(environment: environment, infoDictionary: info),
            "staging",
            "SENTRY_ENVIRONMENT should win over the bundled production value"
        )
    }

    runSuite("SentryRuntimeConfiguration rejects insecure DSNs and falls back to a secure source") {
        let info: [String: Any] = [
            SentryRuntimeConfiguration.dsnInfoKey: "https://plist@example.invalid/1",
        ]
        let environment = [
            SentryRuntimeConfiguration.dsnEnvironmentKey: "http://local@example.invalid/2",
        ]

        assertEqual(
            SentryRuntimeConfiguration.dsn(environment: environment, infoDictionary: info),
            "https://plist@example.invalid/1",
            "non-HTTPS env DSNs should be ignored so crash reports do not downgrade to plaintext transport"
        )
    }

    runSuite("SentryRuntimeConfiguration returns nil when every DSN source is insecure") {
        let info: [String: Any] = [
            SentryRuntimeConfiguration.dsnInfoKey: "ftp://plist@example.invalid/1",
        ]
        let environment = [
            SentryRuntimeConfiguration.dsnEnvironmentKey: "http://local@example.invalid/2",
        ]

        assertNil(
            SentryRuntimeConfiguration.dsn(environment: environment, infoDictionary: info),
            "Sentry should stay disabled when only insecure DSN values are available"
        )
    }

    runSuite("SentryRuntimeConfiguration falls back to plist then production defaults") {
        let info: [String: Any] = [
            SentryRuntimeConfiguration.dsnInfoKey: "https://plist@example.invalid/1",
            SentryRuntimeConfiguration.environmentInfoKey: "local-plist",
            SentryRuntimeConfiguration.releasePrefixInfoKey: "transcripted",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
        ]

        assertEqual(
            SentryRuntimeConfiguration.dsn(environment: [:], infoDictionary: info),
            "https://plist@example.invalid/1",
            "plist DSN should be used when no env override is present"
        )
        assertEqual(
            SentryRuntimeConfiguration.environment(environment: [:], infoDictionary: info),
            "local-plist",
            "plist environment should be used when no env override is present"
        )
        assertEqual(
            SentryRuntimeConfiguration.environment(environment: [:], infoDictionary: [:]),
            "production",
            "production remains the final environment fallback"
        )
        assertEqual(
            SentryRuntimeConfiguration.releaseName(environment: [:], infoDictionary: info),
            "transcripted@1.2.3",
            "release name should stay versioned"
        )
        assertEqual(
            SentryRuntimeConfiguration.dist(environment: [:], infoDictionary: info),
            "456",
            "dist should still mirror CFBundleVersion"
        )
    }

    runSuite("SentryRuntimeConfiguration lets local validation override release metadata") {
        let info: [String: Any] = [
            SentryRuntimeConfiguration.releasePrefixInfoKey: "transcripted",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
        ]
        let environment = [
            SentryRuntimeConfiguration.releaseEnvironmentKey: "transcripted@local-validation",
            SentryRuntimeConfiguration.distEnvironmentKey: "local-build",
        ]

        assertEqual(
            SentryRuntimeConfiguration.releaseName(environment: environment, infoDictionary: info),
            "transcripted@local-validation",
            "SENTRY_RELEASE should win for smoke tests that must not look like a shipped build"
        )
        assertEqual(
            SentryRuntimeConfiguration.dist(environment: environment, infoDictionary: info),
            "local-build",
            "SENTRY_DIST should win for smoke tests that need a synthetic dist"
        )
    }

    runSuite("SentryRuntimeConfiguration rejects sensitive metadata overrides") {
        let info: [String: Any] = [
            SentryRuntimeConfiguration.environmentInfoKey: "production",
            SentryRuntimeConfiguration.releasePrefixInfoKey: "transcripted",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
        ]
        let environment = [
            SentryRuntimeConfiguration.environmentEnvironmentKey: "/Users/jane/private",
            SentryRuntimeConfiguration.releaseEnvironmentKey: "transcripted@person@example.com",
            SentryRuntimeConfiguration.distEnvironmentKey: "sk-private",
        ]

        assertEqual(
            SentryRuntimeConfiguration.environment(environment: environment, infoDictionary: info),
            "production",
            "unsafe SENTRY_ENVIRONMENT values should not become Sentry metadata"
        )
        assertEqual(
            SentryRuntimeConfiguration.releaseName(environment: environment, infoDictionary: info),
            "transcripted@1.2.3",
            "unsafe SENTRY_RELEASE overrides should fall back to bundle metadata"
        )
        assertEqual(
            SentryRuntimeConfiguration.dist(environment: environment, infoDictionary: info),
            "456",
            "unsafe SENTRY_DIST values should fall back to the bundle build"
        )
    }

    runSuite("SentryRuntimeConfiguration drops unsafe bundle metadata when no safe fallback exists") {
        let info: [String: Any] = [
            SentryRuntimeConfiguration.environmentInfoKey: "person@example.com",
            SentryRuntimeConfiguration.releasePrefixInfoKey: "/Users/jane/private",
            "CFBundleShortVersionString": "sk-private",
            "CFBundleVersion": "https://example.com/build",
        ]

        assertEqual(
            SentryRuntimeConfiguration.environment(environment: [:], infoDictionary: info),
            "production",
            "unsafe plist environments should fall back to production"
        )
        assertEqual(
            SentryRuntimeConfiguration.releaseName(environment: [:], infoDictionary: info),
            "transcripted@unknown",
            "unsafe plist release pieces should not become a Sentry release"
        )
        assertNil(
            SentryRuntimeConfiguration.dist(environment: [:], infoDictionary: info),
            "unsafe plist dist values should be omitted"
        )
    }

    runSuite("SentryRuntimeConfiguration defaults to the Transcripted release prefix") {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
        ]

        assertEqual(
            SentryRuntimeConfiguration.releaseName(environment: [:], infoDictionary: info),
            "transcripted@1.2.3",
            "missing bundle prefix should still produce the shipped Transcripted release name"
        )
    }

    runSuite("SentryRuntimeConfiguration ignores invalid release overrides") {
        let info: [String: Any] = [
            SentryRuntimeConfiguration.releasePrefixInfoKey: "transcripted",
            "CFBundleShortVersionString": "1.2.3",
        ]
        let environment = [
            SentryRuntimeConfiguration.releaseEnvironmentKey: "bad/release",
        ]

        assertEqual(
            SentryRuntimeConfiguration.releaseName(environment: environment, infoDictionary: info),
            "transcripted@1.2.3",
            "invalid SENTRY_RELEASE values should not replace the shipped release name"
        )
    }

    runSuite("SentryRuntimeConfiguration disables app hang tracking by default") {
        assertFalse(
            SentryRuntimeConfiguration.appHangTrackingEnabled(environment: [:], infoDictionary: [:]),
            "automatic app hang tracking should default off because modal system alerts can look like hangs"
        )
    }

    runSuite("SentryRuntimeConfiguration allows explicit app hang tracking opt in") {
        assertTrue(
            SentryRuntimeConfiguration.appHangTrackingEnabled(
                environment: [SentryRuntimeConfiguration.appHangTrackingEnvironmentKey: "true"],
                infoDictionary: [:]
            ),
            "local validation can opt into app hang tracking through environment"
        )
        assertTrue(
            SentryRuntimeConfiguration.appHangTrackingEnabled(
                environment: [:],
                infoDictionary: [SentryRuntimeConfiguration.appHangTrackingInfoKey: true]
            ),
            "bundle config can opt into app hang tracking when we intentionally want it"
        )
        assertFalse(
            SentryRuntimeConfiguration.appHangTrackingEnabled(
                environment: [SentryRuntimeConfiguration.appHangTrackingEnvironmentKey: "not-a-bool"],
                infoDictionary: [SentryRuntimeConfiguration.appHangTrackingInfoKey: true]
            ),
            "invalid environment override should fail closed"
        )
    }
}
