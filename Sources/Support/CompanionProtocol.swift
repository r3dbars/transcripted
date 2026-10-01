import Foundation
import CoreFoundation

/// The production companion has a deliberately small, explicit control surface.
/// Parsing never echoes request text, credentials, or transcript contents.
enum CompanionMethod: Equatable, Sendable {
    case status
    case startMeeting(shareLive: Bool)
    case stopMeeting(sessionID: UUID)
    case readLiveTranscript(sessionID: UUID, afterSequence: Int, limit: Int)
    case setLiveSharing(sessionID: UUID, enabled: Bool)
}

struct CompanionRequest: Equatable, Sendable {
    let id: UUID
    let method: CompanionMethod
}

struct CompanionFailure: Error, Equatable, Sendable {
    let code: String
    let message: String

    static let invalidRequest = Self(code: "invalid_request", message: "The companion request is invalid.")
    static let authentication = Self(code: "auth_failed", message: "Reconnect the Transcripted companion.")
    static let unsupportedVersion = Self(code: "unsupported_version", message: "Update the Transcripted companion to connect.")
    static let unknownMethod = Self(code: "unknown_method", message: "This companion action is not supported.")
    static let permissionDenied = Self(code: "permission_denied", message: "Allow this action in Transcripted’s Agent settings.")
    static let staleSession = Self(code: "stale_session", message: "The meeting has changed. Refresh meeting status and try again.")
}

enum CompanionProtocol {
    static let version = 1
    static let maximumRequestBytes = 32 * 1024
    static let maximumResponseBytes = 512 * 1024

    /// Only a UUID can be echoed when parsing fails; arbitrary client text and
    /// credentials never enter the response. This lets clients identify an
    /// authentication failure for their request and show reconnect guidance.
    static func requestID(in data: Data) -> UUID? {
        guard data.count <= maximumRequestBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["id"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    static func parse(_ data: Data, token: String) -> Result<CompanionRequest, CompanionFailure> {
        guard !data.isEmpty, data.count <= maximumRequestBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let request = object as? [String: Any] else { return .failure(.invalidRequest) }
        guard let suppliedToken = request["token"] as? String,
              constantTimeEqual(suppliedToken, token) else { return .failure(.authentication) }
        guard let version = integer(request["version"]), version == Self.version else {
            return .failure(.unsupportedVersion)
        }
        guard let rawID = request["id"] as? String, let id = UUID(uuidString: rawID),
              let method = request["method"] as? String,
              let params = request["params"] as? [String: Any] else { return .failure(.invalidRequest) }
        let command: CompanionMethod
        switch method {
        case "status":
            command = .status
        case "start_meeting":
            guard params["share_live"] == nil || boolean(params["share_live"]) != nil else {
                return .failure(.invalidRequest)
            }
            command = .startMeeting(shareLive: boolean(params["share_live"]) ?? false)
        case "stop_meeting":
            guard let sessionID = sessionID(params) else { return .failure(.invalidRequest) }
            command = .stopMeeting(sessionID: sessionID)
        case "read_live_transcript":
            guard let sessionID = sessionID(params),
                  params["after_sequence"] == nil || integer(params["after_sequence"]) != nil,
                  params["limit"] == nil || integer(params["limit"]) != nil else {
                return .failure(.invalidRequest)
            }
            let after = integer(params["after_sequence"]) ?? 0
            let limit = integer(params["limit"]) ?? 30
            guard after >= 0, (1...100).contains(limit) else { return .failure(.invalidRequest) }
            command = .readLiveTranscript(sessionID: sessionID, afterSequence: after, limit: limit)
        case "set_live_sharing":
            guard let sessionID = sessionID(params), let enabled = boolean(params["enabled"]) else {
                return .failure(.invalidRequest)
            }
            command = .setLiveSharing(sessionID: sessionID, enabled: enabled)
        default:
            return .failure(.unknownMethod)
        }
        return .success(CompanionRequest(id: id, method: command))
    }

    static func response(id: UUID?, result: [String: Any]) -> Data {
        encode(["version": version, "id": id?.uuidString as Any? ?? NSNull(), "ok": true, "result": result])
    }

    static func response(id: UUID?, failure: CompanionFailure) -> Data {
        encode(["version": version, "id": id?.uuidString as Any? ?? NSNull(), "ok": false,
                "error": ["code": failure.code, "message": failure.message]])
    }

    private static func encode(_ value: [String: Any]) -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              data.count <= maximumResponseBytes else {
            // A fixed fallback cannot contain any private input.
            return Data("{\"version\":1,\"id\":null,\"ok\":false,\"error\":{\"code\":\"response_too_large\",\"message\":\"Request fewer transcript segments.\"}}\n".utf8)
        }
        return data + Data([10])
    }

    private static func sessionID(_ params: [String: Any]) -> UUID? {
        guard let raw = params["session_id"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in right.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

enum CompanionPreferences {
    static let enabledKey = "companion-connection-enabled"
    static let meetingControlKey = "companion-meeting-control-enabled"
    static let liveSharingKey = "companion-live-sharing-enabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }
    static func allowsMeetingControl(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: meetingControlKey) }
    static func allowsLiveSharing(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: liveSharingKey) }
}

/// Authentication belongs to one listener lifetime. A queued request from a
/// disconnected listener cannot gain authority when a new listener opens.
struct CompanionConnectionEpoch {
    private var active: UUID?

    mutating func begin() -> UUID {
        let lease = UUID()
        active = lease
        return lease
    }

    mutating func invalidate() { active = nil }

    func accepts(_ lease: UUID) -> Bool { active == lease }
}
