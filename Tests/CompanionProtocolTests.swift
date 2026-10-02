import Foundation

func testCompanionProtocol() {
    let token = "fixture-secret"
    let id = UUID()
    let session = UUID()
    func parse(_ method: String, params: [String: Any] = [:], changes: [String: Any] = [:]) -> Result<CompanionRequest, CompanionFailure> {
        var value: [String: Any] = ["version": 1, "id": id.uuidString, "token": token,
                                   "method": method, "params": params]
        value.merge(changes) { _, replacement in replacement }
        return CompanionProtocol.parse(try! JSONSerialization.data(withJSONObject: value), token: token)
    }

    runSuite("Companion uses explicit actions and never starts live sharing by default") {
        assertEqual(parse("status"), .success(CompanionRequest(id: id, method: .status)))
        assertEqual(parse("start_meeting"), .success(CompanionRequest(id: id, method: .startMeeting(shareLive: false))))
        assertEqual(parse("start_meeting", params: ["share_live": true]), .success(CompanionRequest(id: id, method: .startMeeting(shareLive: true))))
        assertEqual(parse("stop_meeting", params: ["session_id": session.uuidString]), .success(CompanionRequest(id: id, method: .stopMeeting(sessionID: session))))
        assertEqual(parse("set_live_sharing", params: ["session_id": session.uuidString, "enabled": false]),
                    .success(CompanionRequest(id: id, method: .setLiveSharing(sessionID: session, enabled: false))))
    }

    runSuite("Companion refuses unauthenticated and incompatible requests") {
        assertEqual(parse("status", changes: ["token": "wrong-secret"]), .failure(.authentication))
        assertEqual(parse("status", changes: ["token": NSNull()]), .failure(.authentication))
        assertEqual(parse("status", changes: ["version": 2]), .failure(.unsupportedVersion))
        assertEqual(parse("status", changes: ["version": true]), .failure(.unsupportedVersion))
        assertEqual(parse("invented_method"), .failure(.unknownMethod))
        assertEqual(CompanionProtocol.parse(Data("{not json}".utf8), token: token), .failure(.invalidRequest))
        assertEqual(CompanionProtocol.parse(Data(repeating: 32, count: CompanionProtocol.maximumRequestBytes + 1), token: token), .failure(.invalidRequest))
    }

    runSuite("Companion cannot stop or share a meeting without an explicit session id") {
        assertEqual(parse("stop_meeting"), .failure(.invalidRequest))
        assertEqual(parse("stop_meeting", params: ["session_id": "not-a-session"]), .failure(.invalidRequest))
        assertEqual(parse("set_live_sharing", params: ["enabled": true]), .failure(.invalidRequest))
        assertEqual(parse("set_live_sharing", params: ["session_id": session.uuidString]), .failure(.invalidRequest))
        assertEqual(parse("set_live_sharing", params: ["session_id": session.uuidString, "enabled": 1]), .failure(.invalidRequest))
        assertEqual(parse("start_meeting", params: ["share_live": "true"]), .failure(.invalidRequest))
    }

    runSuite("Companion reads bounded live deltas and refuses coerced numbers") {
        assertEqual(parse("read_live_transcript", params: ["session_id": session.uuidString]),
                    .success(CompanionRequest(id: id, method: .readLiveTranscript(sessionID: session, afterSequence: 0, limit: 30))))
        assertEqual(parse("read_live_transcript", params: ["session_id": session.uuidString, "after_sequence": 7, "limit": 100]),
                    .success(CompanionRequest(id: id, method: .readLiveTranscript(sessionID: session, afterSequence: 7, limit: 100))))
        for badLimit: Any in [0, 101, -1, 3.5, true, "30"] {
            assertEqual(parse("read_live_transcript", params: ["session_id": session.uuidString, "limit": badLimit]), .failure(.invalidRequest))
        }
        for badSequence: Any in [-1, 1.5, true, "4"] {
            assertEqual(parse("read_live_transcript", params: ["session_id": session.uuidString, "after_sequence": badSequence]), .failure(.invalidRequest))
        }
    }

    runSuite("Companion permission choices all begin disabled") {
        let suite = "CompanionPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        assertFalse(CompanionPreferences.isEnabled(defaults))
        assertFalse(CompanionPreferences.allowsMeetingControl(defaults))
        assertFalse(CompanionPreferences.allowsLiveSharing(defaults))
        defaults.set(true, forKey: CompanionPreferences.enabledKey)
        assertTrue(CompanionPreferences.isEnabled(defaults))
        assertFalse(CompanionPreferences.allowsLiveSharing(defaults))
    }

    runSuite("A queued companion request stays revoked after reconnecting") {
        var connection = CompanionConnectionEpoch()
        let queuedRequestLease = connection.begin()
        assertTrue(connection.accepts(queuedRequestLease))
        connection.invalidate()
        assertFalse(connection.accepts(queuedRequestLease))
        let newConnectionLease = connection.begin()
        assertFalse(connection.accepts(queuedRequestLease), "reconnecting cannot revive an old authenticated request")
        assertTrue(connection.accepts(newConnectionLease))
        let replacementLease = connection.begin()
        assertFalse(connection.accepts(newConnectionLease), "a replacement listener owns a fresh authority")
        assertTrue(connection.accepts(replacementLease))
        connection.invalidate()
        assertFalse(connection.accepts(replacementLease))
    }

    runSuite("Companion responses are bounded JSON lines with safe failure messages") {
        assertEqual(CompanionProtocol.requestID(in: try! JSONSerialization.data(withJSONObject: ["id": id.uuidString])), id)
        assertNil(CompanionProtocol.requestID(in: try! JSONSerialization.data(withJSONObject: ["id": "private client input"])))
        let response = CompanionProtocol.response(id: id, result: ["sharing_enabled": false])
        assertEqual(response.last, 10)
        let object = try! JSONSerialization.jsonObject(with: response) as! [String: Any]
        assertEqual(object["id"] as? String, id.uuidString)
        assertEqual(object["ok"] as? Bool, true)
        let tooLarge = CompanionProtocol.response(id: id, result: ["segments": String(repeating: "x", count: CompanionProtocol.maximumResponseBytes + 1)])
        let fallback = try! JSONSerialization.jsonObject(with: tooLarge) as! [String: Any]
        assertEqual((fallback["error"] as? [String: String])?["code"], "response_too_large")
        let failure = CompanionProtocol.response(id: nil, failure: .authentication)
        assertFalse(String(decoding: failure, as: UTF8.self).contains(token))
    }
}
