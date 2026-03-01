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
            // Rollback: move .old back
            try? fm.moveItem(at: backupURL, to: currentURL)
            throw UpdateError.replaceFailed("Move failed: \(error.localizedDescription)")
        }

        // Clean up backup and DMG
        try? fm.removeItem(at: backupURL)
        try? fm.removeItem(at: dmgPath)

        // Spawn detached relaunch and terminate
        spawnRelaunch(appPath: currentURL.path)
        NSApp.terminate(nil)
    }

    // MARK: - DMG operations

    private func mountDMG(at path: URL) async throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", path.path, "-nobrowse", "-noverify", "-noautoopen", "-plist"]

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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", appURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.signatureInvalid
        }
    }

    // MARK: - Relaunch

    private func spawnRelaunch(appPath: String) {
        let script = "sleep 2 && open -a \"\(appPath)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
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
