import Foundation

/// Programs Write for Me starts from a path in its settings (`NextSentenceClaudePath`,
/// `NextSentenceEmbeddingServer`). What it starts runs with Transcripted's microphone, Screen Recording
/// and Accessibility access, so a path only counts if it names the expected program and nobody but
/// this user (or the system) can change what it points at.
enum NextSentenceExecutable {
    /// `path` if it's absolute, its file name is `name`, and it resolves to a regular executable file that
    /// this user or root owns, which neither the file nor its folder lets anyone else write. Otherwise nil.
    static func trusted(_ path: String, named name: String, userID: uid_t = getuid(),
                        fileManager: FileManager = .default) -> URL? {
        guard path.hasPrefix("/"), (path as NSString).lastPathComponent == name else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let file = try? fileManager.attributesOfItem(atPath: resolved.path),
              file[.type] as? FileAttributeType == .typeRegular,
              fileManager.isExecutableFile(atPath: resolved.path),
              isPrivate(file, userID: userID),
              let folder = try? fileManager.attributesOfItem(atPath: resolved.deletingLastPathComponent().path),
              isPrivate(folder, userID: userID) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func isPrivate(_ attributes: [FileAttributeKey: Any], userID: uid_t) -> Bool {
        guard let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
        return (owner == userID || owner == 0) && permissions & 0o022 == 0
    }
}
