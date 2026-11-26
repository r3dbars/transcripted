import Foundation
import Security

/// Removes legacy Writing artifacts left behind by older builds that included
/// autocomplete, Personal History encryption, Outcome Ledger, Word Diary, and
/// Write for Me (`next-sentence`). Never touches `<capture-library>/writing/`
/// day files or `writing/Pending Entries/`.
///
/// Every filesystem removal refuses symlinks along the path and verifies the
/// resolved target sits strictly inside `appSupportRoot`.
enum LegacyWritingDataCleanup {
    struct Result: Equatable, Sendable {
        let removedRelativePaths: [String]
        let refusedUnsafePaths: [String]
        let failedRelativePaths: [String]
        let keychainItemsDeleted: Int
        let keychainDeleteFailed: Bool

        var succeeded: Bool {
            refusedUnsafePaths.isEmpty && failedRelativePaths.isEmpty && !keychainDeleteFailed
        }
    }

    static let legacyRelativePaths: [String] = [
        "writing/Personal History",
        "writing/Outcome Ledger",
        "writing/Word Diary",
        "next-sentence",
    ]

    /// Exact Keychain identifiers used by `KeychainPersonalHistoryKeyProvider`
    /// before Personal History encryption was spun out.
    static let legacyKeychainServices: [String] = [
        "com.justinbetker.draft.writing.personal-history",
        "com.justinbetker.draft.preview9b.writing.personal-history",
    ]
    static let legacyKeychainAccount = "aes-gcm-key-v1"
    static let launchCleanupCompletedDefaultsKey = "legacyWritingDataCleanedUp"

    static func keychainQuery(service: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: legacyKeychainAccount,
            kSecAttrSynchronizable: false,
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip as CFString,
        ]
    }

    @discardableResult
    static func runLaunchCleanupIfNeeded(
        appSupportRoot: URL,
        userDefaults: UserDefaults = .standard,
        relativePaths: [String] = legacyRelativePaths,
        fileManager: FileManager = .default,
        deleteKeychainItem: ([CFString: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }
    ) -> Result? {
        if userDefaults.bool(forKey: launchCleanupCompletedDefaultsKey) {
            return nil
        }
        let result = cleanUp(
            appSupportRoot: appSupportRoot,
            relativePaths: relativePaths,
            userDefaults: userDefaults,
            fileManager: fileManager,
            deleteKeychainItem: deleteKeychainItem
        )
        if result.succeeded {
            userDefaults.set(true, forKey: launchCleanupCompletedDefaultsKey)
        }
        return result
    }

    @discardableResult
    static func cleanUp(
        appSupportRoot: URL,
        relativePaths: [String] = legacyRelativePaths,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        deleteKeychainItem: ([CFString: Any]) -> OSStatus = { SecItemDelete($0 as CFDictionary) }
    ) -> Result {
        var removedRelativePaths: [String] = []
        var refusedUnsafePaths: [String] = []
        var failedRelativePaths: [String] = []

        let configuredLibraryPaths = TranscriptedStoragePreferences.configuredCaptureLibraryPaths(
            userDefaults: userDefaults
        )
        let root = appSupportRoot.standardizedFileURL
        let rootIsLink = isSymbolicLink(at: root, fileManager: fileManager)
        var rootIsDirectory: ObjCBool = false
        let rootExists = fileManager.fileExists(atPath: root.path, isDirectory: &rootIsDirectory)

        if rootIsLink {
            for relativePath in relativePaths {
                guard let components = safeRelativeComponents(relativePath) else {
                    refusedUnsafePaths.append(relativePath)
                    continue
                }
                if targetExistsBehindSymlink(
                    from: root,
                    remainingComponents: components[...],
                    fileManager: fileManager
                ) {
                    refusedUnsafePaths.append(relativePath)
                }
            }
        } else if rootExists && !rootIsDirectory.boolValue {
            refusedUnsafePaths.append(contentsOf: relativePaths)
        } else if rootExists {
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            for relativePath in relativePaths {
                guard let components = safeRelativeComponents(relativePath) else {
                    refusedUnsafePaths.append(relativePath)
                    continue
                }

                var current = root
                var refusedSymlink = false
                var skippedAbsentBehindSymlink = false
                for (index, component) in components.enumerated() {
                    current = current.appendingPathComponent(component)
                    if isSymbolicLink(at: current, fileManager: fileManager) {
                        let isLeaf = index == components.count - 1
                        if isLeaf || targetExistsBehindSymlink(
                            from: current,
                            remainingComponents: components[(index + 1)...],
                            fileManager: fileManager
                        ) {
                            refusedSymlink = true
                        } else {
                            skippedAbsentBehindSymlink = true
                        }
                        break
                    }
                }
                if refusedSymlink {
                    refusedUnsafePaths.append(relativePath)
                    continue
                }
                if skippedAbsentBehindSymlink {
                    continue
                }

                let candidate = current.standardizedFileURL
                guard fileManager.fileExists(atPath: candidate.path) else {
                    continue
                }

                let expectedResolved = components
                    .reduce(resolvedRoot) { $0.appendingPathComponent($1) }
                    .standardizedFileURL
                let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
                guard resolvedCandidate.path == expectedResolved.path,
                      resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/")
                else {
                    refusedUnsafePaths.append(relativePath)
                    continue
                }

                if TranscriptedStoragePreferences.targetOverlapsConfiguredCaptureLibrary(
                    candidate,
                    configuredPaths: configuredLibraryPaths,
                    fileManager: fileManager
                ) || TranscriptedStoragePreferences.targetOverlapsConfiguredCaptureLibrary(
                    resolvedCandidate,
                    configuredPaths: configuredLibraryPaths,
                    fileManager: fileManager
                ) {
                    refusedUnsafePaths.append(relativePath)
                    continue
                }

                do {
                    try fileManager.removeItem(at: candidate)
                    removedRelativePaths.append(relativePath)
                } catch {
                    failedRelativePaths.append(relativePath)
                }
            }
        }

        var keychainItemsDeleted = 0
        var keychainDeleteFailed = false
        for service in legacyKeychainServices {
            let status = deleteKeychainItem(keychainQuery(service: service))
            if status == errSecSuccess {
                keychainItemsDeleted += 1
            } else if status != errSecItemNotFound {
                keychainDeleteFailed = true
            }
        }

        return Result(
            removedRelativePaths: removedRelativePaths,
            refusedUnsafePaths: refusedUnsafePaths,
            failedRelativePaths: failedRelativePaths,
            keychainItemsDeleted: keychainItemsDeleted,
            keychainDeleteFailed: keychainDeleteFailed
        )
    }

    private static func targetExistsBehindSymlink(
        from base: URL,
        remainingComponents: ArraySlice<String>,
        fileManager: FileManager
    ) -> Bool {
        var current = base.resolvingSymlinksInPath().standardizedFileURL
        for (offset, component) in remainingComponents.enumerated() {
            current = current.appendingPathComponent(component)
            let isLast = offset == remainingComponents.count - 1
            if isLast {
                return fileManager.fileExists(atPath: current.path)
                    || isSymbolicLink(at: current, fileManager: fileManager)
            }
            if isSymbolicLink(at: current, fileManager: fileManager) {
                current = current.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        return false
    }

    private static func safeRelativeComponents(_ relativePath: String) -> [String]? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            return nil
        }
        return components
    }

    private static func isSymbolicLink(at url: URL, fileManager: FileManager) -> Bool {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return true
        }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }
}
