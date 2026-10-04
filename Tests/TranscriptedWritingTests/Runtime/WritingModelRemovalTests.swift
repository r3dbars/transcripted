import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// "Delete model" against a fake host (order of steps), and the model store
/// delete against real temporary folders (what goes, what stays).
@MainActor
struct WritingModelRemovalTests {
    @MainActor
    private final class FakeHost: WritingModelRemovalHost {
        var steps: [String] = []
        var autocompleteEnabled: Bool
        var filesRemoved = true

        init(autocompleteEnabled: Bool) {
            self.autocompleteEnabled = autocompleteEnabled
        }

        func turnOffAutocomplete() {
            steps.append("autocomplete-off")
            autocompleteEnabled = false
        }
        func stopModelWork() async { steps.append("stop-model-work") }
        func removeModelFiles() async -> Bool {
            steps.append("remove-files")
            return filesRemoved
        }
    }

    @Test func withAutocompleteOnItTurnsAutocompleteOffAndStopsTheHelperBeforeDeleting() async {
        let host = FakeHost(autocompleteEnabled: true)
        let outcome = await WritingModelRemoval.perform(host: host)
        #expect(outcome == .removed(turnedOffAutocomplete: true))
        #expect(host.steps == ["autocomplete-off", "stop-model-work", "remove-files"])
        #expect(host.autocompleteEnabled == false)
    }

    @Test func withAutocompleteOffItStillStopsModelWorkBeforeDeletingAndLeavesTheSwitchAlone() async {
        let host = FakeHost(autocompleteEnabled: false)
        let outcome = await WritingModelRemoval.perform(host: host)
        #expect(outcome == .removed(turnedOffAutocomplete: false))
        #expect(host.steps == ["stop-model-work", "remove-files"])
    }

    @Test func filesLeftBehindReportIncomplete() async {
        let host = FakeHost(autocompleteEnabled: true)
        host.filesRemoved = false
        let outcome = await WritingModelRemoval.perform(host: host)
        #expect(outcome == .incomplete(turnedOffAutocomplete: true))
    }

    // MARK: - Model store

    private static func makeTemporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WritingModelRemovalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func write(_ url: URL, bytes: Int = 16) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    @Test func deletesEveryModelAndPartialButKeepsTheRootFolder() throws {
        let sandbox = try Self.makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("models/writing", isDirectory: true)
        try Self.write(root.appendingPathComponent("gemma/model.gguf"))
        try Self.write(root.appendingPathComponent("qwen/model.gguf.partial"))
        try Self.write(root.appendingPathComponent("stray.tmp"))

        let removal = WritingModelStore.removeAll(under: root)

        #expect(removal.isComplete)
        #expect(removal.removedCount == 3)
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
    }

    @Test func leavesFilesNextToTheRootAlone() throws {
        let sandbox = try Self.makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("models/writing", isDirectory: true)
        let speechModel = sandbox.appendingPathComponent("models/parakeet/model.bin")
        let neighbor = sandbox.appendingPathComponent("models/writing-notes.txt")
        try Self.write(root.appendingPathComponent("gemma/model.gguf"))
        try Self.write(speechModel)
        try Self.write(neighbor)

        _ = WritingModelStore.removeAll(under: root)

        #expect(FileManager.default.fileExists(atPath: speechModel.path))
        #expect(FileManager.default.fileExists(atPath: neighbor.path))
    }

    @Test func aLinkInsideTheRootGoesButItsTargetStays() throws {
        let sandbox = try Self.makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("writing", isDirectory: true)
        let outside = sandbox.appendingPathComponent("Documents", isDirectory: true)
        let precious = outside.appendingPathComponent("keep.md")
        try Self.write(precious)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("gemma"),
            withDestinationURL: outside
        )

        let removal = WritingModelStore.removeAll(under: root)

        #expect(removal.isComplete)
        #expect(FileManager.default.fileExists(atPath: precious.path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
    }

    @Test func aRootThatIsALinkIsRefusedAndNothingIsDeleted() throws {
        let sandbox = try Self.makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let elsewhere = sandbox.appendingPathComponent("Documents", isDirectory: true)
        let precious = elsewhere.appendingPathComponent("keep.md")
        try Self.write(precious)
        let root = sandbox.appendingPathComponent("writing", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: elsewhere)

        let removal = WritingModelStore.removeAll(under: root)

        #expect(removal.refusedRoot)
        #expect(!removal.isComplete)
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test func aRootThatIsAFileIsRefusedAndKept() throws {
        let sandbox = try Self.makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("writing")
        try Self.write(root)

        let removal = WritingModelStore.removeAll(under: root)

        #expect(removal.refusedRoot)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aMissingRootIsNothingToDelete() throws {
        let sandbox = try Self.makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let removal = WritingModelStore.removeAll(under: sandbox.appendingPathComponent("never-made"))
        #expect(removal.isComplete)
        #expect(removal.removedCount == 0)
    }

    @Test func insideMeansStrictlyBelowTheRoot() {
        let root = URL(fileURLWithPath: "/Users/a/Library/Application Support/Transcripted/models/writing")
        #expect(WritingModelStore.isInside(root.appendingPathComponent("gemma"), root: root))
        #expect(!WritingModelStore.isInside(root, root: root))
        #expect(!WritingModelStore.isInside(root.appendingPathComponent("../parakeet"), root: root))
        #expect(!WritingModelStore.isInside(
            URL(fileURLWithPath: "/Users/a/Library/Application Support/Transcripted/models/writing-old/x"),
            root: root
        ))
        #expect(!WritingModelStore.isInside(URL(fileURLWithPath: "/etc"), root: URL(fileURLWithPath: "/")))
    }
}
