import Darwin

/// Process-wide POSIX signal setup. The app calls this once at launch.
public enum ProcessSignals {
    /// Writes to a dead child's stdin raise SIGPIPE; the default action kills
    /// the process. Ignore it so `write` returns EPIPE instead.
    public static func ignoreSIGPIPE() {
        _ = signal(SIGPIPE, SIG_IGN)
    }
}
