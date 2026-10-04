import Foundation

/// The steps "Delete model" drives. The Writing bridge implements them
/// against the real helper and model store; tests use fakes.
@MainActor
protocol WritingModelRemovalHost: AnyObject {
    /// The Autocomplete switch as saved right now.
    var autocompleteEnabled: Bool { get }
    /// Saves Autocomplete off, so nothing prepares or downloads the model
    /// again behind the delete.
    func turnOffAutocomplete()
    /// Cancels a model preparation, switch or download, and stops the
    /// `llama-server` helper, waiting for both to finish.
    func stopModelWork() async
    /// Deletes everything under the Writing model root. `true` when it all
    /// went.
    func removeModelFiles() async -> Bool
}

/// Deleting the downloaded autocomplete models (3.4 or 5.6 GB each) from
/// the Writing tab. Autocomplete can't run without one, so a delete turns
/// it off first; the tab says so, and that turning it back on downloads the
/// model again.
enum WritingModelRemoval {
    enum Outcome: Equatable, Sendable {
        /// Every model file is gone. `turnedOffAutocomplete` is `true` when
        /// Autocomplete was on and the delete switched it off.
        case removed(turnedOffAutocomplete: Bool)
        /// Some files couldn't be deleted.
        case incomplete(turnedOffAutocomplete: Bool)
    }

    @MainActor
    static func perform(host: some WritingModelRemovalHost) async -> Outcome {
        let turnOff = host.autocompleteEnabled
        if turnOff { host.turnOffAutocomplete() }
        await host.stopModelWork()
        return await host.removeModelFiles()
            ? .removed(turnedOffAutocomplete: turnOff)
            : .incomplete(turnedOffAutocomplete: turnOff)
    }
}

/// Deletes what's inside the Writing model root and nothing else.
enum WritingModelStore {
    struct Removal: Equatable, Sendable {
        /// Entries deleted directly under the root (model folders, stray
        /// files, links).
        var removedCount = 0
        /// Entries that couldn't be deleted, or that weren't under the root.
        var failedCount = 0
        /// The root itself was refused (a symlink, or not a folder).
        var refusedRoot = false

        var isComplete: Bool { failedCount == 0 && !refusedRoot }
    }

    /// Deletes every entry directly inside `root`, leaving `root` itself.
    /// A missing root is nothing to delete. A root that is a symlink, or
    /// isn't a folder, is refused outright, so a planted link can't point
    /// the delete at another folder. Entries are removed without following
    /// links: a link inside the root goes, its target stays. Each entry is
    /// checked to be inside the root before it's deleted.
    static func removeAll(under root: URL, fileManager: FileManager = .default) -> Removal {
        var removal = Removal()
        let rootPath = root.standardizedFileURL.path
        var info = stat()
        guard lstat(rootPath, &info) == 0 else {
            if errno != ENOENT { removal.refusedRoot = true }
            return removal
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, rootPath != "/" else {
            removal.refusedRoot = true
            return removal
        }
        guard let names = try? fileManager.contentsOfDirectory(atPath: rootPath) else {
            removal.refusedRoot = true
            return removal
        }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        for name in names {
            let entry = rootURL.appendingPathComponent(name, isDirectory: false)
            guard isInside(entry, root: rootURL) else {
                removal.failedCount += 1
                continue
            }
            do {
                try fileManager.removeItem(at: entry)
                removal.removedCount += 1
            } catch {
                removal.failedCount += 1
            }
        }
        return removal
    }

    /// `url` is strictly below `root`, by standardized path. `..` segments
    /// are resolved first, so they can't climb out.
    static func isInside(_ url: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard rootComponents.count > 1, components.count > rootComponents.count else { return false }
        return Array(components.prefix(rootComponents.count)) == rootComponents
    }
}
