import Foundation

/// A helper process that can't outlive Transcripted. It runs under a small `sh` watchdog that holds the
/// read end of a pipe whose write end only Transcripted has. When that end closes, the watchdog stops the
/// helper and exits. It closes on `stop()`, on quit, and when the app crashes or is killed, since the
/// kernel closes it either way. (Process doesn't let children inherit it, so no other child keeps it open.)
/// If the helper exits on its own, the watchdog exits too, so `isRunning` tells whether the helper is up.
final class NextSentenceTetheredProcess: @unchecked Sendable {
    /// The watchdog: start the helper, and a reader that stops it once the tether closes; when the helper
    /// ends either way, stop the reader and exit. The tether goes to the reader on fd 3, since a background
    /// job's stdin is /dev/null. The reader goes before its `cat`, so it never signals a helper already gone.
    static let watchdog = #"exec 3<&0; "$@" 3<&- & child=$!; { cat <&3 >/dev/null; kill "$child" 2>/dev/null; } & reader=$!; exec 3<&-; wait "$child"; cats=$(pgrep -P "$reader"); kill "$reader" 2>/dev/null; kill $cats 2>/dev/null"#

    private let process = Process()
    private let tether = Pipe()

    init(executable: URL, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.watchdog, "transcripted-helper", executable.path] + arguments
        process.standardInput = tether
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func start() throws {
        try process.run()
        try? tether.fileHandleForReading.close()
    }

    /// The watchdog's own process id. The helper is its only child.
    var processIdentifier: pid_t { process.processIdentifier }

    /// The helper is still up (the watchdog exits as soon as it does).
    var isRunning: Bool { process.isRunning }

    /// Stops the helper: closing the tether makes the watchdog end it, then exit. Safe to call twice.
    func stop() {
        try? tether.fileHandleForWriting.close()
    }
}
