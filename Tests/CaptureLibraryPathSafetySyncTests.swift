import Foundation

/// Source-text pins: this test reads the literal text of the three
/// CaptureLibraryPathSafety.swift copies rather than calling code, but not for the usual
/// can't-instantiate-it reason — there is no single type here to call. CaptureLibraryPathSafety.swift
/// is a SYNCED COPY that exists byte-identically in three places, one per build unit that cannot
/// share a module boundary with the others (see that file's header comment for why real duplicated
/// files were chosen over a git symlink — a checkout with `core.symlinks=false` materializes a
/// symlink as a text file containing the literal link target, which fails to compile). What is
/// pinned: byte-for-byte equality of all three copies. This test is the enforcement mechanism: if
/// any one copy diverges from the others by even a byte, this fails and names exactly which paths
/// need to be brought back in sync. If you edit the shared safety rule, edit all three files
/// identically rather than adjusting this test.
func testCaptureLibraryPathSafetySync() {
    let relativePaths = [
        "Sources/Support/CaptureLibraryPathSafety.swift",
        "Sources/TranscriptedCore/Services/CaptureLibraryPathSafety.swift",
        "Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureLibraryPathSafety.swift",
    ]

    runSuite("CaptureLibraryPathSafety.swift stays byte-identical across its three synced copies") {
        var contentsByPath: [String: String] = [:]

        for relativePath in relativePaths {
            let url = repoFixtureURL(relativePath)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                assertTrue(false, "could not read synced copy at \(relativePath) — expected a real (non-symlink) file")
                return
            }
            contentsByPath[relativePath] = contents
        }

        guard let referencePath = relativePaths.first, let reference = contentsByPath[referencePath] else {
            assertTrue(false, "expected at least one synced copy to compare")
            return
        }

        for relativePath in relativePaths.dropFirst() {
            assertEqual(
                contentsByPath[relativePath] ?? "",
                reference,
                "\(relativePath) has drifted from \(referencePath) — edit all three CaptureLibraryPathSafety.swift copies together: \(relativePaths.joined(separator: ", "))"
            )
        }
    }
}
