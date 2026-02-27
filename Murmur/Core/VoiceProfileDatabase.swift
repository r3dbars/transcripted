import Foundation
import SQLite3

// MARK: - VoiceProfile

struct VoiceProfile: Identifiable {
    let id: String           // Speaker ID from diarization (e.g. "SPEAKER_01")
    var name: String?        // Resolved human name
    var callCount: Int       // Times seen across sessions
    var lastSeen: Date?
    var confidence: Double   // 0.0–1.0 — how confident we are this is a real person
    var autoLabeled: Bool    // true = name came from name inference, false = manual
}

// MARK: - VoiceProfileDatabase

/// Persistent local store for speaker voice profiles.
/// Backed by SQLite in ~/Library/Application Support/Transcripted/voices.db
///
/// The server (Sortformer) tracks voice *embeddings*.
/// This database tracks the human-readable *names* and metadata.
/// The two are linked by speaker_id.
final class VoiceProfileDatabase: ObservableObject {

    static let shared = VoiceProfileDatabase()

    @Published private(set) var profiles: [VoiceProfile] = []

    private var db: OpaquePointer?
    private let dbURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appending(path: "Transcripted")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appending(path: "voices.db")
        openDatabase()
        createTable()
        loadProfiles()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Public API

    /// Resolve a speaker_id to a display name, or nil if unknown.
    func name(for speakerId: String) -> String? {
        profiles.first(where: { $0.id == speakerId })?.name
    }

    /// Upsert a profile — called after each transcription session.
    func upsert(speakerId: String, name: String? = nil, autoLabeled: Bool = false) {
        let existing = profiles.first(where: { $0.id == speakerId })
        let callCount = (existing?.callCount ?? 0) + 1
        let resolvedName = name ?? existing?.name
        let confidence = min(1.0, Double(callCount) / 5.0) // Full confidence after 5 calls

        let profile = VoiceProfile(
            id: speakerId,
            name: resolvedName,
            callCount: callCount,
            lastSeen: Date(),
            confidence: confidence,
            autoLabeled: autoLabeled
        )
        persist(profile)
        loadProfiles()
    }

    /// Manually assign a name to a speaker (user-initiated correction).
    func setName(_ name: String, for speakerId: String) {
        upsert(speakerId: speakerId, name: name, autoLabeled: false)

        // Also push to inference server so it persists there too
        Task {
            try? await LocalTranscriptionService.labelSpeaker(speakerId: speakerId, name: name)
        }
    }

    /// Remove a profile (e.g. user clears history).
    func delete(speakerId: String) {
        let sql = "DELETE FROM voice_profiles WHERE speaker_id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, speakerId, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        loadProfiles()
    }

    // MARK: - SQLite internals

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            print("❌ VoiceProfileDatabase: failed to open \(dbURL.path)")
        }
    }

    private func createTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS voice_profiles (
            speaker_id   TEXT PRIMARY KEY,
            name         TEXT,
            call_count   INTEGER DEFAULT 0,
            last_seen    REAL,
            confidence   REAL DEFAULT 0.0,
            auto_labeled INTEGER DEFAULT 0
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func persist(_ profile: VoiceProfile) {
        let sql = """
        INSERT INTO voice_profiles (speaker_id, name, call_count, last_seen, confidence, auto_labeled)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(speaker_id) DO UPDATE SET
            name         = excluded.name,
            call_count   = excluded.call_count,
            last_seen    = excluded.last_seen,
            confidence   = excluded.confidence,
            auto_labeled = excluded.auto_labeled;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let nameStr = profile.name as NSString?
        sqlite3_bind_text(stmt, 1, profile.id, -1, nil)
        if let n = nameStr {
            sqlite3_bind_text(stmt, 2, n.utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_int(stmt, 3, Int32(profile.callCount))
        sqlite3_bind_double(stmt, 4, profile.lastSeen?.timeIntervalSince1970 ?? 0)
        sqlite3_bind_double(stmt, 5, profile.confidence)
        sqlite3_bind_int(stmt, 6, profile.autoLabeled ? 1 : 0)

        sqlite3_step(stmt)
    }

    private func loadProfiles() {
        var loaded: [VoiceProfile] = []
        let sql = "SELECT speaker_id, name, call_count, last_seen, confidence, auto_labeled FROM voice_profiles ORDER BY call_count DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let sid = String(cString: sqlite3_column_text(stmt, 0))
            let name = sqlite3_column_type(stmt, 1) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 1))
                : nil
            let callCount = Int(sqlite3_column_int(stmt, 2))
            let ts = sqlite3_column_double(stmt, 3)
            let lastSeen = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
            let confidence = sqlite3_column_double(stmt, 4)
            let autoLabeled = sqlite3_column_int(stmt, 5) == 1

            loaded.append(VoiceProfile(
                id: sid,
                name: name,
                callCount: callCount,
                lastSeen: lastSeen,
                confidence: confidence,
                autoLabeled: autoLabeled
            ))
        }

        DispatchQueue.main.async {
            self.profiles = loaded
        }
    }
}
