import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// The Writing diagnostics log stays bounded: once it reaches its cap it rolls
/// to `<name>.1` and starts fresh, keeping one old generation.
@Suite("Writing diagnostics log rolls at its size cap")
struct DiagnosticsLogRollTests {
    /// The log refuses symlinked path components, and the temp directory
    /// lives under `/var`, which is one; hand it the real path.
    private func makeDirectory() -> URL {
        let temporary = FileManager.default.temporaryDirectory.path
        let real = realpath(temporary, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? temporary
        return URL(fileURLWithPath: real, isDirectory: true)
            .appendingPathComponent("writing-diagnostics-roll-\(UUID().uuidString)", isDirectory: true)
    }

    private func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
    }

    @Test("Many events never grow the log far past its cap")
    func logStaysBounded() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("writing-diagnostics.log")
        let cap: UInt64 = 1_024
        let log = DiagnosticsLog(logURL: logURL, maxBytes: cap)

        for index in 0..<400 {
            log.record("roll-probe-\(index)")
        }
        log.flush()

        // One line can land after the size check, so allow one line of slack.
        let oneLine: UInt64 = 128
        #expect(size(logURL) < cap + oneLine)
        #expect(size(log.rolledLogURL) < cap + oneLine)
        #expect(size(log.rolledLogURL) >= cap)

        let current = try String(contentsOf: logURL, encoding: .utf8)
        #expect(current.contains("roll-probe-399\n"))
        let rolled = try String(contentsOf: log.rolledLogURL, encoding: .utf8)
        #expect(!rolled.contains("roll-probe-399\n"))
        // Only one old generation is kept.
        #expect(!FileManager.default.fileExists(atPath: log.rolledLogURL.appendingPathExtension("1").path))
    }

    @Test("A log under its cap is left alone")
    func smallLogDoesNotRoll() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("writing-diagnostics.log")
        let log = DiagnosticsLog(logURL: logURL, maxBytes: 1_024 * 1_024)

        log.record("first")
        log.record("second")
        log.flush()

        let current = try String(contentsOf: logURL, encoding: .utf8)
        #expect(current.contains("first"))
        #expect(current.contains("second"))
        #expect(!FileManager.default.fileExists(atPath: log.rolledLogURL.path))
    }
}
