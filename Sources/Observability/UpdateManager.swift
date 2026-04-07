// UpdateManager.swift
// DMG-based auto-update for beta builds.
// Flow: download DMG → mount → verify codesign → atomic replace → detached relaunch.
// TCC permissions (mic, accessibility, screen recording) survive because
// bundle ID + signing team ID are unchanged.

#if BETA_BUILD

import Foundation
import AppKit

@MainActor
final class UpdateManager: ObservableObject {
    enum UpdateState {
        case idle
        case downloading(Double)  // progress 0.0–1.0
        case installing
        case failed(String)
    }

    @Published var state: UpdateState = .idle

    private let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Draft")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func checkAndUpdate(latestVersion: String, downloadURL: String) async {
        guard case .idle = state else { return }
        guard let url = URL(string: downloadURL) else {
            state = .failed("Invalid download URL")
            return
        }

        // Step 1: Download DMG
        state = .downloading(0)
        let dmgPath = cacheDir.appendingPathComponent("update.dmg")

        do {
            try await downloadDMG(from: url, to: dmgPath)
        } catch {
            state = .failed("Download failed: \(error.localizedDescription)")
            return
        }

        // Step 2: Mount, verify, replace, relaunch
        state = .installing
        do {
            try await installUpdate(dmgPath: dmgPath)
        } catch {
            state = .failed("Install failed: \(error.localizedDescription)")
            // Clean up downloaded DMG
            try? FileManager.default.removeItem(at: dmgPath)
        }
    }

    // MARK: - Download

    private func downloadDMG(from url: URL, to destination: URL) async throws {
        // Remove any previous download
        try? FileManager.default.removeItem(at: destination)

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        state = .downloading(1.0)
    }

    // MARK: - Install

    private func installUpdate(dmgPath: URL) async throws {
        let fm = FileManager.default

        // Mount DMG
        let mountPoint = try await mountDMG(at: dmgPath)
        defer { unmountDMG(mountPoint: mountPoint) }

        // Find Draft.app on mounted volume
        let volumeApp = mountPoint.appendingPathComponent("Draft.app")
        guard fm.fileExists(atPath: volumeApp.path) else {
            throw UpdateError.appNotFoundOnDMG
        }

        // Verify code signature
        try verifyCodeSignature(at: volumeApp)

        // Stage the app
        let stagedApp = cacheDir.appendingPathComponent("Draft-staged.app")
        try? fm.removeItem(at: stagedApp)
        try fm.copyItem(at: volumeApp, to: stagedApp)

        // Determine current app location
        guard let currentApp = Bundle.main.bundlePath as String? else {
            throw UpdateError.cannotLocateCurrentApp
        }
        let currentURL = URL(fileURLWithPath: currentApp)
        let parentDir = currentURL.deletingLastPathComponent()
        let backupURL = parentDir.appendingPathComponent("Draft.app.old")

        // Atomic replace: rename current → .old, move staged → current
        try? fm.removeItem(at: backupURL)
        do {
            try fm.moveItem(at: currentURL, to: backupURL)
        } catch {
            throw UpdateError.replaceFailed("Backup failed: \(error.localizedDescription)")
        }

        do {
            try fm.moveItem(at: stagedApp, to: currentURL)
        } catch {
            // Rollback: move .old back — if this fails too, the user needs to know
            do {
                try fm.moveItem(at: backupURL, to: currentURL)
            } catch let rollbackError {
                throw UpdateError.replaceFailed("Move failed AND rollback failed: \(rollbackError.localizedDescription). Restore from: \(backupURL.path)")
            }
            throw UpdateError.replaceFailed("Move failed: \(error.localizedDescription)")
        }

        // Clean up backup and DMG
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: dmgPath)

        // Spawn detached relaunch and terminate
        do {
            try spawnRelaunch(appPath: currentURL.path)
            NSApp.terminate(nil)
        } catch {
            // App was replaced successfully but relaunch failed — don't terminate
            // or user loses the app entirely. They can restart manually.
            state = .failed("Update installed but relaunch failed — please restart Draft manually")
        }
    }

    // MARK: - DMG operations

    private func mountDMG(at path: URL) async throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", path.path, "-nobrowse", "-noautoopen", "-plist"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.mountFailed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateError.mountFailed
        }

        // Find the mount point from the plist output
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        throw UpdateError.mountFailed
    }

    private func unmountDMG(mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-quiet"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Code signature verification

    private func verifyCodeSignature(at appURL: URL) throws {
        // Step 1: Verify the code signature is valid
        let verifyProcess = Process()
        verifyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verifyProcess.arguments = ["--verify", "--deep", "--strict", appURL.path]
        verifyProcess.standardOutput = Pipe()
        verifyProcess.standardError = Pipe()

        try verifyProcess.run()
        verifyProcess.waitUntilExit()

        guard verifyProcess.terminationStatus == 0 else {
            throw UpdateError.signatureInvalid
        }

        // Step 2: Verify the signing team ID matches ours
        let infoProcess = Process()
        infoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        infoProcess.arguments = ["-d", "--verbose=2", appURL.path]
        let infoPipe = Pipe()
        infoProcess.standardOutput = Pipe()
        infoProcess.standardError = infoPipe  // codesign -d writes to stderr

        try infoProcess.run()
        infoProcess.waitUntilExit()

        let infoData = infoPipe.fileHandleForReading.readDataToEndOfFile()
        let infoText = String(data: infoData, encoding: .utf8) ?? ""
        let expectedTeamID = "XG6WL66WUQ"
        guard infoText.contains("TeamIdentifier=\(expectedTeamID)") else {
            throw UpdateError.signatureInvalid
        }
    }

    // MARK: - Relaunch

    private func spawnRelaunch(appPath: String) throws {
        let script = "sleep 2 && open -a \"\(appPath)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        // Do NOT waitUntilExit — this is a detached fire-and-forget
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case downloadFailed
        case mountFailed
        case appNotFoundOnDMG
        case signatureInvalid
        case cannotLocateCurrentApp
        case replaceFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "Failed to download update"
            case .mountFailed: return "Failed to mount DMG"
            case .appNotFoundOnDMG: return "Draft.app not found on disk image"
            case .signatureInvalid: return "Update failed code signature verification"
            case .cannotLocateCurrentApp: return "Cannot locate current app bundle"
            case .replaceFailed(let detail): return "Replace failed: \(detail)"
            }
        }
    }
}

#endif
