import Foundation

struct RuntimeDiagnosticsMarker: Codable, Equatable {
    var launchID: String
    var appVersion: String
    var buildVersion: String
    var osMajor: Int
    var cleanShutdown: Bool
    var startedAt: Date
    var updatedAt: Date
    var lastEvent: String
    var sessionKind: String
    var sessionStage: String
    var sessionActive: Bool
}

enum RuntimeDiagnosticsStore {
    static let markerFileName = "runtime-diagnostics.json"

    static func defaultMarkerURL(fileManager: FileManager = .default) -> URL {
        fileManager.transcriptedStateDir.appendingPathComponent(markerFileName, isDirectory: false)
    }

    static func makeLaunchMarker(
        launchID: String = UUID().uuidString,
        appVersion: String,
        buildVersion: String,
        osMajor: Int,
        now: Date = Date()
    ) -> RuntimeDiagnosticsMarker {
        RuntimeDiagnosticsMarker(
            launchID: launchID,
            appVersion: appVersion,
            buildVersion: buildVersion,
            osMajor: osMajor,
            cleanShutdown: false,
            startedAt: now,
            updatedAt: now,
            lastEvent: "app_launched",
            sessionKind: "none",
            sessionStage: "idle",
            sessionActive: false
        )
    }

    static func load(from url: URL) -> RuntimeDiagnosticsMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RuntimeDiagnosticsMarker.self, from: data)
    }

    static func save(_ marker: RuntimeDiagnosticsMarker, to url: URL) {
        do {
            try FileManager.default.createPrivateDirectory(at: url.deletingLastPathComponent())
            let data = try JSONEncoder().encode(marker)
            try data.write(to: url, options: .atomic)
            FileManager.default.restrictFileToOwnerOnly(at: url)
        } catch {
            fputs("Runtime diagnostics marker write failed: \(error.localizedDescription)\n", stderr)
        }
    }

    static func heartbeatAgeBucket(previousUpdate: Date, now: Date = Date()) -> String {
        let age = max(0, now.timeIntervalSince(previousUpdate))
        switch age {
        case ..<15:
            return "lt_15s"
        case ..<60:
            return "15_59s"
        case ..<300:
            return "1_4m"
        case ..<900:
            return "5_14m"
        case ..<3600:
            return "15_59m"
        default:
            return "1h_plus"
        }
    }

    static func contextForUncleanShutdown(
        previous marker: RuntimeDiagnosticsMarker,
        now: Date = Date()
    ) -> [String: String] {
        [
            "app_version": marker.appVersion,
            "build_version": marker.buildVersion,
            "heartbeat_age_bucket": heartbeatAgeBucket(previousUpdate: marker.updatedAt, now: now),
            "last_event": marker.lastEvent,
            "os_major": "\(marker.osMajor)",
            "session_active": "\(marker.sessionActive)",
            "session_kind": marker.sessionKind,
            "session_stage": marker.sessionStage,
        ]
    }
}
