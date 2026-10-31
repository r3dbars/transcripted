import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Keeps a report alive when the popover closes or a delivery fails. It never
/// reads a capture: the person chooses every screenshot and diagnostic field.
@MainActor
final class FeedbackComposerModel: ObservableObject {
    enum Step { case compose, review, sent }

    @Published var message = ""
    @Published var replyEmail = ""
    @Published var includeDiagnostics = false {
        didSet {
            if includeDiagnostics && !oldValue {
                includedLogs = Array(logsProvider().filter(\.isValid).prefix(3))
            } else if !includeDiagnostics {
                includedLogs = []
            }
        }
    }
    @Published private(set) var attachments: [FeedbackAttachment] = []
    @Published private(set) var step: Step = .compose
    @Published private(set) var isSending = false
    @Published private(set) var isLoadingAttachments = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var receiptID: String?
    @Published private(set) var area = "general"
    @Published private(set) var copiedReport = false

    private var reportID = UUID()
    private var lastReviewedDraft: FeedbackDraft?
    private let sender: @MainActor (FeedbackDraft) async throws -> FeedbackReceipt
    private let diagnostics: FeedbackDiagnostics
    private let appVersion: String
    private let logsProvider: @MainActor () -> [FeedbackLogEntry]
    private var includedLogs: [FeedbackLogEntry] = []

    init(
        appVersion: String = TranscriptedAppVersion.description,
        diagnostics: FeedbackDiagnostics = FeedbackDiagnostics(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            buildRevision: AnalyticsRuntimeConfiguration.buildRevision()
        ),
        logsProvider: @escaping @MainActor () -> [FeedbackLogEntry] = { [] },
        sender: @escaping @MainActor (FeedbackDraft) async throws -> FeedbackReceipt = {
            try await FeedbackSubmissionClient().send($0)
        }
    ) {
        self.appVersion = appVersion
        self.diagnostics = diagnostics
        self.sender = sender
        self.logsProvider = logsProvider
    }

    var canReview: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && message.utf16.count <= 4_000 && !isLoadingAttachments && !isSending
    }

    var reportContextSummary: String { "Area: \(area.capitalized) · App: \(appVersion)" }

    var diagnosticPreview: String {
        "macOS: \(diagnostics.osVersion)\nBuild: \(diagnostics.buildRevision)\n\nRecent failure log (up to 3):\n"
            + (includedLogs.isEmpty ? "No recent failures recorded." : includedLogs.map(\.preview).joined(separator: "\n"))
    }

    func open(area: String) {
        // A report that was already sent is finished: the next open starts a
        // fresh one rather than showing the old success screen.
        if step == .sent { reset() }
        // Reopening a draft must not change what the person already reviewed.
        guard message.isEmpty, attachments.isEmpty, step == .compose else { return }
        self.area = area
    }

    func review() {
        guard canReview else { return }
        do { try draft.validate() }
        catch {
            errorMessage = error.localizedDescription
            return
        }
        errorMessage = nil
        if let lastReviewedDraft, draft != lastReviewedDraft {
            reportID = UUID()
        }
        lastReviewedDraft = draft
        step = .review
    }

    func edit() {
        guard !isSending else { return }
        errorMessage = nil
        step = .compose
    }

    func addScreenshots(_ urls: [URL]) {
        guard !isLoadingAttachments, !isSending, step == .compose else { return }
        guard urls.allSatisfy(\.isFileURL) else {
            errorMessage = "Choose screenshots saved on this Mac."
            return
        }
        guard urls.count + attachments.count <= 3 else {
            errorMessage = "You can attach up to 3 screenshots."
            return
        }
        isLoadingAttachments = true
        errorMessage = nil
        Task {
            defer { isLoadingAttachments = false }
            do {
                var loaded: [FeedbackAttachment] = []
                for url in urls {
                    loaded.append(try await FeedbackAttachment.load(from: url))
                }
                attachments.append(contentsOf: loaded)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Finder provides file URLs; Photos and screenshot thumbnails can provide
    /// image bytes instead. Neither route reads a network URL or sends a report.
    func addScreenshotProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty, !isLoadingAttachments, !isSending, step == .compose else { return false }
        guard providers.count + attachments.count <= 3 else {
            errorMessage = "You can attach up to 3 images. Remove one before adding another."
            return false
        }
        isLoadingAttachments = true
        errorMessage = nil
        Task {
            defer { isLoadingAttachments = false }
            do {
                var loaded: [FeedbackAttachment] = []
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let data = try await Self.dropData(provider, type: UTType.fileURL.identifier)
                        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                            throw FeedbackSubmissionError.unsupportedImage
                        }
                        loaded.append(try await FeedbackAttachment.load(from: url))
                    } else if let type = FeedbackAttachment.imageTypes.first(where: provider.hasItemConformingToTypeIdentifier) {
                        let data = try await Self.dropData(provider, type: type)
                        loaded.append(try await FeedbackAttachment.load(data: data))
                    } else {
                        throw FeedbackSubmissionError.unsupportedImage
                    }
                }
                attachments.append(contentsOf: loaded)
            } catch {
                errorMessage = "Couldn’t attach those images. Try PNG, JPEG, HEIC, or TIFF files, up to 20 MB each. Your existing attachments are still here."
            }
        }
        return true
    }

    private static func dropData(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let transfer = FeedbackDropTransfer(continuation)
            // A different app owns the provider. It may disappear or never
            // invoke its completion; that must not strand this draft forever.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15) {
                transfer.finish(.failure(FeedbackSubmissionError.unsupportedImage))
            }
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data, !data.isEmpty, data.count <= FeedbackAttachment.inputLimit else {
                    transfer.finish(.failure(FeedbackSubmissionError.unsupportedImage))
                    return
                }
                transfer.finish(.success(data))
            }
        }
    }

    func removeScreenshot(_ id: UUID) {
        guard !isSending, step == .compose else { return }
        attachments.removeAll { $0.id == id }
    }

    func send() async {
        guard step == .review, !isSending else { return }
        let report = draft
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            let receipt = try await sender(report)
            receiptID = receipt.id
            step = .sent
        } catch {
            // The same report ID is kept for a safe retry after a timeout.
            errorMessage = error.localizedDescription
        }
    }

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft.copyText, forType: .string)
        copiedReport = true
    }

    func reset() {
        guard !isSending, !isLoadingAttachments else { return }
        message = ""
        replyEmail = ""
        includeDiagnostics = false
        attachments = []
        step = .compose
        errorMessage = nil
        receiptID = nil
        copiedReport = false
        reportID = UUID()
        lastReviewedDraft = nil
        area = "general"
    }

    private var draft: FeedbackDraft {
        FeedbackDraft(
            id: reportID,
            message: message,
            replyEmail: replyEmail,
            area: area,
            appVersion: appVersion,
            diagnostics: includeDiagnostics ? FeedbackDiagnostics(
                osVersion: diagnostics.osVersion, buildRevision: diagnostics.buildRevision,
                logs: includedLogs.isEmpty ? nil : includedLogs
            ) : nil,
            attachments: attachments
        )
    }
}

/// Provider callbacks race the timeout. Resume exactly once and release the
/// continuation before calling back into the main-actor composer.
final class FeedbackDropTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
