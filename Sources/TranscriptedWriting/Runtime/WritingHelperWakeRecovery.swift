import Foundation

/// What to do with the `llama-server` helper after the Mac wakes. Tilde had
/// no wake handling; its host only restarts a helper that exits, so a helper
/// that survived sleep but stopped answering stayed wedged until a completion
/// failed.
enum WritingHelperWakePolicy {
    enum Action: Equatable, Sendable {
        case none
        case restart
    }

    /// Probes before concluding a ready helper is wedged, one second apart,
    /// so a slow first answer right after wake doesn't cost a model reload.
    static let healthProbeAttempts = 3

    static func action(
        modelReady: Bool,
        snapshot: LlamaRuntimeSnapshot,
        helperHealthy: Bool
    ) -> Action {
        // No verified model means no helper was started; model preparation
        // starts it once the model is ready.
        guard modelReady else { return .none }
        switch snapshot {
        case .ready:
            return helperHealthy ? .none : .restart
        case .failed:
            return .restart
        case .starting, .retrying:
            // The host's own health loop and restart backoff are in charge.
            return .none
        }
    }
}

/// The same checks the host makes, from outside it: the listener on the
/// port is still the host's own child, and `/health` answers "ok".
enum WritingHelperHealthProbe {
    static func isHealthy(_ host: LlamaServerProcessHost) async -> Bool {
        guard await host.isReadyForCompletion() else { return false }
        var request = URLRequest(url: host.baseURL.appendingPathComponent("health"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 2
        guard let (data, response) = try? await LocalhostURLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return false }
        return String(data: data, encoding: .utf8)?.contains("ok") == true
    }
}
