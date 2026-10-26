import Foundation

struct FeedbackLogEntry: Codable, Equatable, Sendable {
    let kind: String
    let stage: String
    let version: String

    var isValid: Bool {
        [kind, stage, version].allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 80
                && $0.range(of: #"[^A-Za-z0-9_.-]"#, options: .regularExpression) == nil
        }
    }

    var preview: String { "\(kind) · \(stage) · v\(version)" }
}

struct FeedbackDiagnostics: Codable, Equatable, Sendable {
    let osVersion: String
    let buildRevision: String
    var logs: [FeedbackLogEntry]? = nil
}

struct FeedbackDraft: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var message: String
    var replyEmail: String
    var area: String = "general"
    var appVersion: String
    var diagnostics: FeedbackDiagnostics?
    var attachments: [FeedbackAttachment] = []

    func validate() throws {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 4_000 else { throw FeedbackSubmissionError.invalidMessage }
        let email = replyEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty {
            let parts = email.split(separator: "@", omittingEmptySubsequences: false)
            let labels = parts.last?.split(separator: ".", omittingEmptySubsequences: false) ?? []
            guard email.utf8.count <= 254, !email.contains(where: { $0.isWhitespace || $0.isNewline }),
                  email.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil,
                  parts.count == 2, !parts[0].isEmpty, labels.count >= 2,
                  labels.allSatisfy({ !$0.isEmpty && $0.first != "-" && $0.last != "-" }),
                  !email.contains("<"), !email.contains(">"),
                  !email.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw FeedbackSubmissionError.invalidEmail }
        }
        guard ["general", "meetings", "dictations", "writing", "speakers", "other"].contains(area),
              !appVersion.isEmpty, appVersion.utf8.count <= 80,
              (diagnostics?.osVersion.utf8.count ?? 0) <= 200,
              (diagnostics?.buildRevision.utf8.count ?? 0) <= 80 else {
            throw FeedbackSubmissionError.invalidReport
        }
        guard attachments.count <= 3,
              attachments.reduce(0, { $0 + $1.data.count }) <= 3 * FeedbackAttachment.maximumBytes else {
            throw FeedbackSubmissionError.tooManyAttachments
        }
        guard (diagnostics?.logs?.count ?? 0) <= 3,
              diagnostics?.logs?.allSatisfy(\.isValid) ?? true else {
            throw FeedbackSubmissionError.invalidReport
        }
        for attachment in attachments { try attachment.validate() }
    }

    var copyText: String {
        var lines = ["Transcripted feedback", "Report: \(id.uuidString)", "Area: \(area)",
                     "App: \(appVersion)", "", message]
        if !replyEmail.isEmpty { lines.append("\nReply to: \(replyEmail)") }
        if let diagnostics {
            lines.append("\nDiagnostics:\nmacOS: \(diagnostics.osVersion)\nBuild: \(diagnostics.buildRevision)")
            lines.append("\nRecent failure log:\n" + (diagnostics.logs?.map(\.preview).joined(separator: "\n") ?? "No recent failures recorded."))
        }
        if !attachments.isEmpty {
            lines.append("\nScreenshots: \(attachments.count) (attach these separately when emailing)")
        }
        return lines.joined(separator: "\n")
    }
}

struct FeedbackReceipt: Codable, Equatable, Sendable {
    let id: String
    let status: String
}

enum FeedbackSubmissionError: LocalizedError, Equatable {
    case invalidMessage, invalidEmail, invalidReport, tooManyAttachments
    case unsupportedImage, imageTooLarge, rateLimited, unavailable, uncertain, rejected

    var errorDescription: String? {
        switch self {
        case .invalidMessage: return "Write a message of up to 4,000 characters."
        case .invalidEmail: return "Check your reply email, or leave it blank."
        case .invalidReport: return "This report couldn't be prepared. Your message is still here."
        case .tooManyAttachments: return "Attach up to three screenshots."
        case .unsupportedImage: return "Choose a PNG, JPEG, HEIC, or TIFF image saved on this Mac."
        case .imageTooLarge: return "That image is too large. Choose a smaller screenshot."
        case .rateLimited: return "Too many reports were sent recently. Keep this draft and try later."
        case .unavailable: return "Support couldn't be reached. Your draft is still here. Try again or copy the report."
        case .uncertain: return "We couldn't confirm receipt. Keep this report ID and email support before sending again."
        case .rejected: return "The report wasn't accepted. Your draft is still here. Try copying it into an email."
        }
    }
}

struct FeedbackSubmissionClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport

    init(transport: @escaping Transport = { request in try await Self.deliver(request) }) {
        self.transport = transport
    }

    static func request(for draft: FeedbackDraft) throws -> URLRequest {
        try draft.validate()
        // Fixed destination; no user-supplied URL or automatic cross-host redirect.
        let endpoint = URL(string: "https://transcripted.app/api/feedback")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(draft.id.uuidString, forHTTPHeaderField: "Idempotency-Key")
        var payload = draft
        payload.message = draft.message.trimmingCharacters(in: .whitespacesAndNewlines)
        payload.replyEmail = draft.replyEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    func send(_ draft: FeedbackDraft) async throws -> FeedbackReceipt {
        let request = try Self.request(for: draft)
        let result: (Data, HTTPURLResponse)
        do { result = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw FeedbackSubmissionError.unavailable }
        let (data, response) = result
        guard data.count <= 16_384 else { throw FeedbackSubmissionError.rejected }
        switch response.statusCode {
        case 200:
            guard let receipt = try? JSONDecoder().decode(FeedbackReceipt.self, from: data),
                  receipt.status == "accepted",
                  receipt.id.lowercased() == draft.id.uuidString.lowercased() else {
                throw FeedbackSubmissionError.rejected
            }
            return receipt
        case 409: throw FeedbackSubmissionError.uncertain
        case 429: throw FeedbackSubmissionError.rateLimited
        case 500...599: throw FeedbackSubmissionError.unavailable
        default: throw FeedbackSubmissionError.rejected
        }
    }

    private static func deliver(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: FeedbackNoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw FeedbackSubmissionError.rejected }
        return (data, response)
    }
}

private final class FeedbackNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
