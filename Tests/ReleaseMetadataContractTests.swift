// ReleaseMetadataContractTests.swift
// Cross-artifact release integrity: Info.plist, docs/appcast.xml, and
// Casks/transcripted.rb must describe the same release. These checks parse
// real values out of each artifact and compare them — they are the surviving
// core of the retired RepoCommandContractTests grep suite.

import Foundation

func testReleaseMetadataContract() {
    runSuite("Release metadata - release resources ship only the active app icon") {
        let infoPlist = releaseContractFile("Info.plist")
        assertTrue(
            infoPlist.contains("<key>CFBundleIconFile</key>\n\t<string>Transcripted</string>"),
            "Info.plist should point at the active Transcripted icon"
        )

        let resourceURL = releaseContractRepoRoot().appendingPathComponent("Resources", isDirectory: true)
        let shippedIcons = ((try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil
        )) ?? [])
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".icns") || $0.hasSuffix(".png") }
            .sorted()

        assertEqual(
            shippedIcons,
            ["Transcripted.icns"],
            "Resources are copied wholesale into the app bundle, so old icon experiments should not ship"
        )
    }

    runSuite("Release metadata - legacy bundle identifier is an explicit compatibility contract") {
        let infoPlist = releaseContractFile("Info.plist")
        assertEqual(
            releasePlistString("CFBundleIdentifier", in: infoPlist),
            "com.justinbetker.draft",
            "bundle id should stay unchanged until there is an explicit TCC/defaults migration"
        )
    }

    runSuite("Release metadata - Info.plist, appcast, and Homebrew cask stay aligned") {
        let infoPlist = releaseContractFile("Info.plist")
        let cask = releaseContractFile("Casks/transcripted.rb")
        let appcast = releaseContractFile("docs/appcast.xml")

        let appVersion = releasePlistString("CFBundleShortVersionString", in: infoPlist)
        let buildVersion = releasePlistString("CFBundleVersion", in: infoPlist)
        let sentryReleasePrefix = releasePlistString("TranscriptedSentryReleasePrefix", in: infoPlist)
        let caskVersion = releaseRubyStringAssignment("version", in: cask)
        let caskSHA = releaseRubyStringAssignment("sha256", in: cask)
        let latestAppcastItem = releaseFirstAppcastItem(in: appcast)
        let minimumSystemVersion = releasePlistString("LSMinimumSystemVersion", in: infoPlist)
        let appcastTitle = releaseXMLText("title", in: latestAppcastItem)
        let appcastVersion = releaseXMLText("sparkle:version", in: latestAppcastItem)
        let appcastShortVersion = releaseXMLText("sparkle:shortVersionString", in: latestAppcastItem)
        let appcastMinimumSystemVersion = releaseXMLText("sparkle:minimumSystemVersion", in: latestAppcastItem)
        let appcastHardwareRequirements = releaseXMLText("sparkle:hardwareRequirements", in: latestAppcastItem)
        let appcastEnclosureURL = releaseXMLAttribute("url", inFirstTagNamed: "enclosure", text: latestAppcastItem)
        let appcastLength = releaseXMLAttribute("length", inFirstTagNamed: "enclosure", text: latestAppcastItem)
        let appcastSignature = releaseXMLAttribute("sparkle:edSignature", inFirstTagNamed: "enclosure", text: latestAppcastItem)
        let appcastLink = releaseXMLText("link", in: latestAppcastItem)
        let appcastReleaseNotesLink = releaseXMLText("sparkle:releaseNotesLink", in: latestAppcastItem)
        let expectedReleaseURL = appVersion.map { "https://github.com/r3dbars/transcripted/releases/tag/v\($0)" }

        assertNotNil(appVersion, "Info.plist should expose CFBundleShortVersionString")
        assertEqual(buildVersion, appVersion, "marketing and build versions should move together for Sparkle")
        assertEqual(sentryReleasePrefix, "transcripted", "Sentry release names should stay on the transcripted@<version> format")
        assertEqual(caskVersion, appVersion, "Homebrew cask version should match the app bundle version")
        assertEqual(appcastTitle, appVersion, "latest appcast title should name the release version")
        assertEqual(appcastVersion, appVersion, "latest appcast item should match the app bundle version")
        assertEqual(appcastShortVersion, appVersion, "Sparkle shortVersionString should match the app bundle version")
        assertEqual(appcastMinimumSystemVersion, minimumSystemVersion, "Sparkle minimum macOS version should match Info.plist")
        assertEqual(appcastHardwareRequirements, "arm64", "Sparkle appcast should keep the release hardware requirement explicit")
        assertEqual(
            appcastEnclosureURL,
            appVersion.map { "https://github.com/r3dbars/transcripted/releases/download/v\($0)/Transcripted-\($0).dmg" },
            "latest appcast enclosure should point at the matching GitHub DMG"
        )
        assertEqual(appcastLink, expectedReleaseURL, "latest appcast link should point at the matching GitHub release")
        assertEqual(appcastReleaseNotesLink, expectedReleaseURL, "latest appcast notes should point at the matching GitHub release")
        assertTrue(
            releaseIsPositiveInteger(appcastLength),
            "latest appcast enclosure should include a positive asset length"
        )
        assertTrue(
            releaseIsNonEmptyBase64Like(appcastSignature),
            "latest appcast enclosure should include a Sparkle EdDSA signature"
        )
        assertTrue(
            releaseIsSHA256Hex(caskSHA),
            "Homebrew cask should include a real 64-character SHA-256 digest"
        )
        assertTrue(
            cask.contains("releases/download/v#{version}/Transcripted-#{version}.dmg"),
            "Homebrew cask URL should keep tracking the matching GitHub release asset"
        )
        assertTrue(cask.contains("depends_on arch: :arm64"), "Homebrew cask should keep the arm64 release contract")
        assertTrue(cask.contains("depends_on macos: \">= :tahoe\""), "Homebrew cask should stay aligned with the macOS 26+ release floor")
    }

    runSuite("Release metadata - Sparkle app settings point at the committed appcast") {
        let infoPlist = releaseContractFile("Info.plist")
        let appcast = releaseContractFile("docs/appcast.xml")
        let sparkleDocs = releaseContractFile("docs/sparkle-updates.md")

        let feedURL = releasePlistString("SUFeedURL", in: infoPlist)
        let appcastSelfURL = releaseXMLAttribute("href", inFirstTagNamed: "atom:link", text: appcast)
        let publicKey = releasePlistString("SUPublicEDKey", in: infoPlist)

        assertEqual(
            feedURL,
            "https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/appcast.xml",
            "Info.plist should use the committed main-branch appcast feed"
        )
        assertEqual(appcastSelfURL, feedURL, "appcast self link should match Info.plist SUFeedURL")
        assertTrue(releasePlistBoolean("SUEnableAutomaticChecks", in: infoPlist) == true, "Sparkle automatic checks should stay enabled")
        assertTrue(releasePlistBoolean("SUAllowsAutomaticUpdates", in: infoPlist) == true, "Sparkle automatic downloads should stay available")
        assertEqual(releasePlistInteger("SUScheduledCheckInterval", in: infoPlist), 14_400, "Sparkle check interval should stay at 4 hours")
        assertNotNil(publicKey, "Info.plist should include the Sparkle EdDSA public key")
        if let publicKey {
            assertTrue(
                sparkleDocs.contains("<string>\(publicKey)</string>"),
                "docs/sparkle-updates.md should document the committed Sparkle public key"
            )
        }
    }
}

private func releaseContractRepoRoot() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

private func releaseContractFile(_ relativePath: String) -> String {
    let url = releaseContractRepoRoot().appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func releasePlistString(_ key: String, in contents: String) -> String? {
    guard let keyRange = contents.range(of: "<key>\(key)</key>"),
          let stringStart = contents.range(of: "<string>", range: keyRange.upperBound..<contents.endIndex),
          let stringEnd = contents.range(of: "</string>", range: stringStart.upperBound..<contents.endIndex)
    else {
        return nil
    }

    return String(contents[stringStart.upperBound..<stringEnd.lowerBound])
}

private func releasePlistBoolean(_ key: String, in contents: String) -> Bool? {
    guard let keyRange = contents.range(of: "<key>\(key)</key>"),
          let valueStart = contents.range(of: "<", range: keyRange.upperBound..<contents.endIndex),
          let valueEnd = contents.range(of: ">", range: valueStart.upperBound..<contents.endIndex)
    else {
        return nil
    }

    let tag = String(contents[valueStart.lowerBound...valueEnd.lowerBound])
    if tag == "<true/>" { return true }
    if tag == "<false/>" { return false }
    return nil
}

private func releasePlistInteger(_ key: String, in contents: String) -> Int? {
    guard let keyRange = contents.range(of: "<key>\(key)</key>"),
          let integerStart = contents.range(of: "<integer>", range: keyRange.upperBound..<contents.endIndex),
          let integerEnd = contents.range(of: "</integer>", range: integerStart.upperBound..<contents.endIndex)
    else {
        return nil
    }

    return Int(contents[integerStart.upperBound..<integerEnd.lowerBound])
}

private func releaseRubyStringAssignment(_ key: String, in contents: String) -> String? {
    for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\(key) \""),
              let start = trimmed.firstIndex(of: "\""),
              let end = trimmed[trimmed.index(after: start)...].firstIndex(of: "\"")
        else {
            continue
        }

        return String(trimmed[trimmed.index(after: start)..<end])
    }

    return nil
}

private func releaseFirstAppcastItem(in contents: String) -> String {
    guard let start = contents.range(of: "<item>"),
          let end = contents.range(of: "</item>", range: start.upperBound..<contents.endIndex)
    else {
        return ""
    }

    return String(contents[start.lowerBound..<end.upperBound])
}

private func releaseXMLText(_ elementName: String, in contents: String) -> String? {
    guard let start = contents.range(of: "<\(elementName)>"),
          let end = contents.range(of: "</\(elementName)>", range: start.upperBound..<contents.endIndex)
    else {
        return nil
    }

    return String(contents[start.upperBound..<end.lowerBound])
}

private func releaseXMLAttribute(_ name: String, inFirstTagNamed tagName: String, text: String) -> String? {
    guard let tagStart = text.range(of: "<\(tagName) "),
          let tagEnd = text.range(of: ">", range: tagStart.upperBound..<text.endIndex)
    else {
        return nil
    }

    let tag = String(text[tagStart.lowerBound..<tagEnd.upperBound])
    guard let attributeStart = tag.range(of: "\(name)=\""),
          let valueEnd = tag.range(of: "\"", range: attributeStart.upperBound..<tag.endIndex)
    else {
        return nil
    }

    return String(tag[attributeStart.upperBound..<valueEnd.lowerBound])
}

private func releaseIsPositiveInteger(_ value: String?) -> Bool {
    guard let value, let integer = Int(value) else { return false }
    return integer > 0
}

private func releaseIsNonEmptyBase64Like(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return false }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
}

private func releaseIsSHA256Hex(_ value: String?) -> Bool {
    guard let value, value.count == 64 else { return false }
    let allowed = CharacterSet(charactersIn: "0123456789abcdef")
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
}
