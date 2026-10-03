import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// The app's seal check before a helper launch runs in full again whenever
/// the helper or the app's seal file changes, and a failure is never
/// remembered. The owner team is resolved once, and a missing one is asked
/// again.
@Suite("Bundle seal pass memo")
struct BundleSealPassMemoTests {
    private static func fingerprint(_ seed: UInt64) -> BundleSealPassMemo.Fingerprint {
        var info = stat()
        info.st_ino = seed
        info.st_size = 1
        return [SecureLocalStorage.FileContentFingerprint(info)]
    }

    @Test("A pass is reused while the fingerprint holds and rechecked when it changes")
    func passIsReusedUntilFingerprintChanges() {
        let memo = BundleSealPassMemo()
        var current = Self.fingerprint(1)
        var validations = 0

        for _ in 0..<5 {
            #expect(memo.check(fingerprint: { current }, validate: { validations += 1; return true }))
        }
        #expect(validations == 1)

        current = Self.fingerprint(2)
        #expect(memo.check(fingerprint: { current }, validate: { validations += 1; return true }))
        #expect(memo.check(fingerprint: { current }, validate: { validations += 1; return true }))
        #expect(validations == 2)
    }

    @Test("A failed check is never remembered")
    func failureIsNotCached() {
        let memo = BundleSealPassMemo()
        let current = Self.fingerprint(1)
        var validations = 0

        #expect(!memo.check(fingerprint: { current }, validate: { validations += 1; return false }))
        #expect(!memo.check(fingerprint: { current }, validate: { validations += 1; return false }))
        #expect(validations == 2)
        #expect(memo.check(fingerprint: { current }, validate: { validations += 1; return true }))
        #expect(validations == 3)
    }

    @Test("A failure after a pass clears the remembered pass")
    func failureClearsPass() {
        let memo = BundleSealPassMemo()
        var current = Self.fingerprint(1)
        var validations = 0
        #expect(memo.check(fingerprint: { current }, validate: { validations += 1; return true }))

        current = Self.fingerprint(2)
        #expect(!memo.check(fingerprint: { current }, validate: { validations += 1; return false }))
        current = Self.fingerprint(1)
        #expect(memo.check(fingerprint: { current }, validate: { validations += 1; return true }))
        #expect(validations == 3)
    }

    @Test("Without a fingerprint every check validates in full")
    func noFingerprintNoMemo() {
        let memo = BundleSealPassMemo()
        var validations = 0
        for _ in 0..<3 {
            #expect(memo.check(fingerprint: { nil }, validate: { validations += 1; return true }))
        }
        #expect(validations == 3)
    }

    @Test("A pass isn't remembered if the files moved while it validated")
    func movingFilesDuringValidationAreNotRemembered() {
        let memo = BundleSealPassMemo()
        var current = Self.fingerprint(1)
        var validations = 0
        #expect(memo.check(fingerprint: { current }, validate: {
            validations += 1
            current = Self.fingerprint(2)
            return true
        }))
        #expect(memo.check(fingerprint: { current }, validate: { validations += 1; return true }))
        #expect(validations == 2)
    }

    @Test("The fingerprint needs a regular helper and seal file, and a swapped helper changes it")
    func helperSealFingerprintOnDisk() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-memo-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let helpers = bundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let signature = bundle.appendingPathComponent("Contents/_CodeSignature", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let helper = helpers.appendingPathComponent("llama-server")
        try Data("one".utf8).write(to: helper)

        // No seal file yet: nothing to key on.
        #expect(BundleSealPassMemo.helperSealFingerprint(bundlePath: bundle.path) == nil)

        try FileManager.default.createDirectory(at: signature, withIntermediateDirectories: true)
        try Data("seal".utf8).write(to: signature.appendingPathComponent("CodeResources"))
        let first = try #require(BundleSealPassMemo.helperSealFingerprint(bundlePath: bundle.path))
        #expect(BundleSealPassMemo.helperSealFingerprint(bundlePath: bundle.path) == first)

        // Swap in another file at the helper's path.
        let replacement = helpers.appendingPathComponent("replacement")
        try Data("two".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(helper, withItemAt: replacement)
        let swapped = try #require(BundleSealPassMemo.helperSealFingerprint(bundlePath: bundle.path))
        #expect(swapped != first)

        // A symlink at the helper's path is not a regular file.
        try FileManager.default.removeItem(at: helper)
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: replacement)
        try Data("two".utf8).write(to: replacement)
        #expect(BundleSealPassMemo.helperSealFingerprint(bundlePath: bundle.path) == nil)
    }

    @Test("The owner team is resolved once when found, and asked again when missing")
    func nonNilMemoCachesOnlyAnswers() {
        let memo = NonNilMemo<String>()
        var resolutions = 0

        #expect(memo.value { resolutions += 1; return nil } == nil)
        #expect(memo.value { resolutions += 1; return nil } == nil)
        #expect(resolutions == 2)

        #expect(memo.value { resolutions += 1; return "TEAM123456" } == "TEAM123456")
        #expect(memo.value { resolutions += 1; return "OTHER" } == "TEAM123456")
        #expect(resolutions == 3)
    }
}
